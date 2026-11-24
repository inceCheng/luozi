import AppKit
import AVFoundation
import Carbon
import IOKit.hidsystem

// This test only types into its own scratch window. It never opens a microphone.
@main struct InputCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--fixture") {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 115),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "落字 · 输入框验收"
            let first = NSTextField(frame: .init(x: 20, y: 65, width: 340, height: 25))
            let second = NSTextField(frame: .init(x: 20, y: 25, width: 340, height: 25))
            let readOnly = NSTextField(frame: .init(x: 240, y: 4, width: 110, height: 19))
            readOnly.isEditable = false
            readOnly.setAccessibilityIdentifier("readOnlyFixtureField")
            readOnly.isSelectable = true
            readOnly.stringValue = "只读文字"
            window.contentView?.addSubview(readOnly)
            first.stringValue = "原文"; second.stringValue = "第二栏"
            window.contentView?.addSubview(first); window.contentView?.addSubview(second)
            first.nextKeyView = second; second.nextKeyView = first
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            window.makeFirstResponder(first)
            first.currentEditor()?.selectedRange = NSRange(location: 2, length: 0)
            signal(SIGUSR1, SIG_IGN)
            let focusSwitch = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            focusSwitch.setEventHandler { window.makeFirstResponder(second) }
            focusSwitch.resume()
            signal(SIGUSR2, SIG_IGN)
            let leaveField = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
            var visitReadOnly = true
            leaveField.setEventHandler {
                window.makeFirstResponder(visitReadOnly ? readOnly : nil)
                visitReadOnly = false
            }
            leaveField.resume()
            withExtendedLifetime((window, focusSwitch, leaveField)) { app.run() }
            return
        }
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func check() async throws {
        guard AXIsProcessTrusted() else { throw VoiceError("验收进程缺少辅助功能权限。") }
        let original = NSWorkspace.shared.frontmostApplication
        let fixture = Process()
        fixture.executableURL = Bundle.main.executableURL
        fixture.arguments = ["--fixture"]
        try fixture.run()
        defer {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier {
                original?.activate(options: [])
            }
            fixture.terminate()
        }
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
               InputTarget.current()?.pid == fixture.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target = InputTarget.current(), target.pid == fixture.processIdentifier else {
            throw VoiceError("测试窗口未获得焦点，已停止。")
        }
        func value(_ element: AXUIElement) -> String? {
            var output: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &output)
            return output as? String
        }
        func center(_ element: AXUIElement) throws -> CGPoint {
            var origin: CFTypeRef?, size: CFTypeRef?
            var p = CGPoint.zero, s = CGSize.zero
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &origin) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  AXValueGetValue(origin as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s)
            else { throw VoiceError("测试控件缺少坐标。") }
            return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        }
        let firstCenter = try center(target.element)
        let keys = Hotkeys()
        precondition(!StopKey.modifierPressed(code: CGKeyCode(kVK_Shift), previous: [.maskShift,.maskControl], current: .maskControl))
        precondition(StopKey.modifierPressed(code: CGKeyCode(kVK_Option), previous: [], current: .maskAlternate))
        let limiter = RecordingLimit.standard
        precondition(limiter.seconds == 1800)
        precondition(RecordingLimit(hours: "12", minutes: "0", seconds: "0")?.seconds == 43200)
        for (h,m,s) in [("12","0","1"),("13","0","0"),("0","60","0"),("0","0","0"),("-1","0","2")] {
            precondition(RecordingLimit(hours: h, minutes: m, seconds: s) == nil)
        }
        var expirations = 0
        let upper = RecordingLimit(seconds: 43200)!
        let nearlyExpired = ContinuousClock.now.advanced(by: .milliseconds(-43_199_880))
        await upper.schedule(from: nearlyExpired) { expirations += 1 }.value
        let cancelled = limiter.schedule(from: .now) { expirations += 1 }
        cancelled.cancel(); await cancelled.value
        precondition(expirations == 1)
        let suite = "PressSpeak.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "shortcut")
        var settings = Bindings(defaults: defaults)
        precondition(settings.hold == .controlShiftSpace && settings.continuous != settings.hold)
        settings.continuous = Shortcut(key: UInt32(kVK_F16), modifiers: 0)
        settings.save(defaults)
        precondition(Bindings(defaults: defaults) == settings)
        print("Limit bounds, scheduled expiry, cancellation, and shortcut migration: passed")

        let stopKey = StopKey()
        var events = [String]()
        var endings = 0
        var hookError: Error?
        keys.onTrigger = { mode, pressed in
            events.append("\(mode.rawValue)-\(pressed)")
            if mode == .continuous {
                if pressed {
                    do { try stopKey.start(trigger: .controlShiftSpace) { endings += 1; stopKey.endRecording() } }
                    catch { hookError = error }
                } else { stopKey.triggerReleased() }
            }
        }
        try keys.configure([.hold: .controlOptionSpace, .continuous: .controlShiftSpace])
        do {
            try keys.configure([.hold: .controlOptionSpace, .continuous: .controlOptionSpace])
            throw VoiceError("重复快捷键未被拒绝。")
        } catch let error as VoiceError where error.message.contains("不同") { }
        // Exchange existing chords without losing the old registrations.
        try keys.configure([.hold: .controlShiftSpace, .continuous: .controlOptionSpace])
        try keys.configure([.hold: .controlOptionSpace, .continuous: .controlShiftSpace])
        func send(_ key: Int, down: Bool, flags: CGEventFlags = [], repeated: Bool = false) async throws {
            guard target.stillFocused() else { throw VoiceError("测试窗口焦点已变。") }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
            event.flags = flags
            if repeated { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(75))
        }
        for down in [true,false] { try await send(kVK_Space, down: down, flags: [.maskControl, .maskAlternate]) }
        for ending in [kVK_ANSI_R,kVK_Return,kVK_Escape] {
            let before = endings
            for down in [true,false] { try await send(kVK_Space, down: down, flags: [.maskControl, .maskShift]) }
            if let hookError { throw hookError }
            guard endings == before else { throw VoiceError("启动按键松开时误提交。") }
            try await send(ending, down: true)
            try await send(ending, down: true, repeated: true)
            try await send(ending, down: false)
            guard endings == before + 1, value(target.element) == "原文" else {
                throw VoiceError("结束键未正确吞掉或重复提交。")
            }
        }
        guard events == ["1-true","1-false","3-true","3-false","3-true","3-false","3-true","3-false"] else {
            throw VoiceError("热键事件序列异常 \(events)")
        }
        print("Press/release, independent shortcuts, continuous start and any-key consumption: passed")
        func modifier(_ code: Int, _ flags: CGEventFlags) async throws {
            guard target.stillFocused() else { throw VoiceError("修饰键测试窗口焦点已变。") }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)!
            event.type = .flagsChanged
            event.flags = flags
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(70))
        }
        let right = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICERCTLKEYMASK))
        let left = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK))
        events = []
        try keys.configure([.hold: .rightControl, .continuous: .controlShiftSpace])
        try await modifier(kVK_Control, left)
        try await modifier(kVK_RightControl, right.union(left))
        try await modifier(kVK_RightControl, left)
        try await modifier(kVK_Control, [])
        try await modifier(kVK_RightControl, right)
        try await modifier(kVK_Control, right.union(left))
        try await modifier(kVK_RightControl, left)
        try await modifier(kVK_Control, [])
        guard events == ["1-true","1-false"] else { throw VoiceError("右 Ctrl 按住模式按下或松开事件异常：\(events)") }
        try keys.configure([.hold: .controlOptionSpace, .continuous: .rightControl])
        let beforeRight = endings
        keys.onTrigger = { mode, down in
            events.append("\(mode.rawValue)-\(down)")
            if down {
                do { try stopKey.start(trigger: .rightControl) { endings += 1; stopKey.endRecording() } }
                catch { hookError = error }
            } else { stopKey.triggerReleased() }
        }
        try await modifier(kVK_RightControl, right)
        try await modifier(kVK_RightControl, [])
        guard endings == beforeRight, events.suffix(2) == ["3-true","3-false"] else { throw VoiceError("松开右 Ctrl 误结束持续听写。") }
        try await send(kVK_ANSI_R, down: true)
        try await send(kVK_ANSI_R, down: false)
        if let hookError { throw hookError }
        guard endings == beforeRight + 1, value(target.element) == "原文" else { throw VoiceError("右 Ctrl 持续听写结束键异常。") }
        try keys.configure([:])
        let beforeRemoval = events.count
        try await modifier(kVK_RightControl, right)
        try await modifier(kVK_RightControl, [])
        guard events.count == beforeRemoval else { throw VoiceError("取消绑定后右 Ctrl 仍在触发。") }
        print("Right Control: left/right distinction, overlapping release, hold, continuous stop and removal passed")
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("原剪贴内容", forType: .string)
        let originalChange = clipboard.changeCount
        guard await TranscriptDelivery.send("，Kafka", fallbackClipboard: clipboard),
              value(target.element) == "原文，Kafka", clipboard.changeCount == originalChange else {
            throw VoiceError("终稿没有正确插入光标位置。")
        }
        kill(fixture.processIdentifier, SIGUSR1)
        for _ in 0..<20 {
            if !target.stillFocused() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let focusInfo = InputTarget.current()
        guard focusInfo?.pid == fixture.processIdentifier, !target.stillFocused(), !(await target.insert("错误投递")) else {
            throw VoiceError("焦点保护未生效。")
        }
        guard let second = focusInfo, await TranscriptDelivery.send("焦点在这里", fallbackClipboard: clipboard, pointer: { firstCenter }),
              value(second.element)?.contains("焦点在这里") == true, value(target.element) == "原文，Kafka",
              clipboard.changeCount == originalChange else { throw VoiceError("终稿未送入完成时的输入框。") }
        var readOnlyCenter: CGPoint?
        for label in ["只读控件", "无输入框"] {
            kill(fixture.processIdentifier, SIGUSR2)
            try await Task.sleep(for: .milliseconds(180))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
                  InputTarget.current() == nil else { throw VoiceError(label + " 被误认为输入框。") }
            if readOnlyCenter == nil {
                var children: CFTypeRef?
                guard let window = target.window,
                      AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
                      let field = (children as? [AXUIElement])?.first(where: { child in
                          var id: CFTypeRef?
                          AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &id)
                          return id as? String == "readOnlyFixtureField"
                      }) else { throw VoiceError("未找到测试只读控件。") }
                readOnlyCenter = try center(field)
            }
            let final = "以后粘贴 · " + label
            guard await TranscriptDelivery.send(final, fallbackClipboard: clipboard, pointer: { readOnlyCenter }),
                  clipboard.string(forType: .string) == final else { throw VoiceError(label + "下终稿未自动复制。") }
        }
        let oldChange = clipboard.changeCount
        guard await TranscriptDelivery.send("", fallbackClipboard: clipboard), clipboard.changeCount == oldChange
        else { throw VoiceError("空转写覆盖了剪贴板。") }
        print("Final-focus insertion, read-only/no-field clipboard fallback and empty result: passed")
        guard await TranscriptDelivery.send("悬停", fallbackClipboard: clipboard, pointer: { firstCenter }),
              let inserted = value(target.element), inserted.contains("悬停"),
              inserted.replacingOccurrences(of: "悬停", with: "") == "原文，Kafka",
              clipboard.changeCount == oldChange else { throw VoiceError("悬停回填失败，或覆盖了已有文字。") }
        print("Hovered field acquired focus and preserved its original content: passed")
        let hud = RecordingPanel()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { throw VoiceError("未找到浮窗所在屏幕。") }
        let area = screen.visibleFrame
        func isBottomCentered(_ frame: NSRect) -> Bool {
            abs(frame.midX - area.midX) <= 0.5 && frame.minY == area.minY + 48
        }
        let meter = AudioLevelMeter()
        hud.start("正在听写…", meter: meter)
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              panel.frame.width == 216, panel.frame.height == 26,
              isBottomCentered(panel.frame),
              panel.ignoresMouseEvents, !panel.isKeyWindow,
              let waveform = panel.contentView?.subviews.compactMap({ $0 as? WaveformView }).first,
              let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first,
              waveform.frame.maxX < label.frame.minX, label.stringValue == "正在听写…"
        else { throw VoiceError("紧凑浮窗验收失败。") }
        let frame = panel.frame
        func pixels() throws -> Data {
            guard let bitmap = waveform.bitmapImageRepForCachingDisplay(in: waveform.bounds)
            else { throw VoiceError("无法读取波形。") }
            waveform.cacheDisplay(in: waveform.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VoiceError("无法渲染波形。") }
            return data
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320),
              let samples = pcm.floatChannelData?[0] else { throw VoiceError("无法构造音量样本。") }
        pcm.frameLength = pcm.frameCapacity
        func feed(_ amplitude: Float) {
            for i in 0..<Int(pcm.frameLength) { samples[i] = amplitude * sin(Float(i) * 0.1) }
            meter.ingest(pcm)
        }
        feed(0)
        let silent = try pixels()
        guard meter.level == 0 else { throw VoiceError("静音电平错误。") }
        feed(0.03)
        let quietLevel = meter.level
        feed(0.8)
        try await Task.sleep(for: .milliseconds(450))
        guard meter.level > quietLevel, quietLevel > 0, try pixels() != silent else { throw VoiceError("波形没有响应实际音量。") }
        hud.updateTranscript("明天下午三点")
        hud.updateTranscript("明天下午四点")
        guard label.stringValue == "明天下午四点" else { throw VoiceError("识别修订未替换旧预览。") }
        let long = String(repeating: "很长的一段中文。", count: 80) + "最新的句子"
        hud.updateTranscript(long)
        guard label.stringValue == String(long.suffix(90)), label.lineBreakMode == .byTruncatingHead,
              panel.frame == frame else { throw VoiceError("长句预览未保留最新文字或位置发生变化。") }
        hud.processing()
        hud.updateTranscript("迟到的中间结果")
        guard waveform.isHidden, label.stringValue.hasSuffix("最新的句子"), panel.frame == frame else { throw VoiceError("等待终稿时未保留预览。") }
        hud.hide()
        guard !panel.isVisible else { throw VoiceError("终稿浮窗未立即隐藏。") }
        hud.start("持续听写中…", meter: AudioLevelMeter())
        guard !waveform.isHidden, label.stringValue == "持续听写中…" else { throw VoiceError("新会话仍显示旧文字。") }
        hud.processing(reachedLimit: true)
        guard label.stringValue.contains("已到时限") else { throw VoiceError("时限提示未显示。") }
        hud.hide()
        print("HUD: live audio-driven waveform, revised and long previews, stable bottom-center position, synchronous dismissal passed")
        try await checkSettings()
    }

    @MainActor static func checkSettings() async throws {
        var result: (Bindings, RecordingLimit)?
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        var stored: String?
        var engine = Engine.apple
        var refuseWrite = false
        func activate(_ choice: Engine, _ key: String?) throws {
            if refuseWrite { throw VoiceError("测试写入失败。") }
            if let key { stored = key }
            guard choice == .apple || stored != nil else { throw VoiceError("请先填写 API Key。") }
            engine = choice
        }
        let form = Preferences(hasSavedKey: { stored != nil }, clipboard: clipboard, activate: activate) { selected, keys, limit, key in
            try activate(selected, key)
            result = (keys, limit)
        }
        let initial = Bindings(hold: .controlOptionSpace, continuous: .controlShiftSpace)
        form.show(engine: .apple, bindings: initial, limit: .standard)
        try await Task.sleep(for: .milliseconds(200))
        guard let window = NSApp.keyWindow, let content = window.contentView else { throw VoiceError("设置窗口未打开。") }
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let all = children(content)
        let buttons = all.compactMap { $0 as? NSButton }
        let fields = all.compactMap { $0 as? NSTextField }.filter { $0.isEditable && !($0 is NSSecureTextField) }
        guard let binding = buttons.first(where: { $0.tag == Int(TalkMode.continuous.rawValue) }),
              let hold = buttons.first(where: { $0.tag == Int(TalkMode.hold.rawValue) }),
              let reset = buttons.first(where: { $0.title == "重置" }),
              let save = buttons.first(where: { $0.title == "保存" }),
              let hours = fields.first(where: { $0.accessibilityLabel()?.hasSuffix("小时") == true }),
              let minutes = fields.first(where: { $0.accessibilityLabel()?.hasSuffix("分钟") == true }),
              let seconds = fields.first(where: { $0.accessibilityLabel()?.hasSuffix("秒") == true })
        else { throw VoiceError("设置控件缺失。") }
        precondition(hours.stringValue == "0" && minutes.stringValue == "30" && seconds.stringValue == "0")
        binding.performClick(nil)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control,.option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: UInt16(kVK_ANSI_J))!
        NSApp.postEvent(key, atStart: false)
        try await Task.sleep(for: .milliseconds(120))
        let expected = Shortcut(key: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))
        guard binding.title == expected.title else { throw VoiceError("自定义键盘录入失败。") }
        hours.stringValue = "12"; minutes.stringValue = "0"; seconds.stringValue = "1"
        save.performClick(nil)
        guard result == nil, window.isVisible else { throw VoiceError("超出 12 小时的值被保存。") }
        seconds.stringValue = "0"; save.performClick(nil)
        guard result?.0.continuous == expected, result?.0.hold == initial.hold,
              result?.1.seconds == 43200, !window.isVisible else { throw VoiceError("时限和快捷键保存失败。") }
        result = nil
        let custom = Bindings(hold: .optionShiftD, continuous: expected)
        let customLimit = RecordingLimit(seconds: 600)!
        form.show(engine: .apple, bindings: custom, limit: customLimit)
        hold.performClick(nil)
        reset.performClick(nil)
        guard result == nil, window.isVisible, !form.record(expected),
              hold.title == Shortcut.controlOptionSpace.title, binding.title == Shortcut.controlShiftSpace.title
        else { throw VoiceError("重置未正确恢复两组默认快捷键或提前保存。") }
        save.performClick(nil)
        guard result?.0 == initial, result?.1 == customLimit else { throw VoiceError("保存重置快捷键失败。") }
        print("Shortcut reset: both defaults restored on Save, capture ended, duration preserved")
        print("Settings UI: custom shortcut recorded, 30-minute default, 12-hour maximum and validation passed")
        form.show(engine: engine, bindings: initial, limit: .standard)
        func postRightControl(_ down: Bool) async throws {
            let flags: NSEvent.ModifierFlags = down ? [.control] : []
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_RightControl))!
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
        hold.performClick(nil)
        try await postRightControl(true)
        try await postRightControl(false)
        guard hold.title == "右 Ctrl" else { throw VoiceError("设置中无法录入单独的右 Ctrl。") }
        save.performClick(nil)
        guard result?.0.hold == .rightControl else { throw VoiceError("右 Ctrl 未保存。") }
        form.show(engine: engine, bindings: initial, limit: .standard)
        hold.performClick(nil)
        try await postRightControl(true)
        NSApp.postEvent(key, atStart: false)
        try await Task.sleep(for: .milliseconds(80))
        try await postRightControl(false)
        guard hold.title == expected.title else { throw VoiceError("录入含 Control 的组合键时被识别成单键。") }
        window.performClose(nil)
        func openSettings() { form.show(engine: engine, bindings: initial, limit: .standard) }
        openSettings()
        guard let selector = all.compactMap({ $0 as? NSSegmentedControl }).first,
              let secret = all.compactMap({ $0 as? NSSecureTextField }).first,
              let paste = buttons.first(where: { $0.title == "粘贴" }) else { throw VoiceError("缺少引擎设置控件。") }
        func choose(_ index: Int) {
            selector.selectedSegment = index
            _ = selector.sendAction(selector.action, to: selector.target)
        }
        choose(1)
        guard engine == .apple, selector.label(forSegment: 0)?.contains("已启用") == true,
              selector.label(forSegment: 1) == "阿里云" else { throw VoiceError("尚未配置的引擎被标记为已启用。") }
        clipboard.setString(" fixture-key-1\n", forType: .string)
        window.makeFirstResponder(secret)
        let pasteEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: UInt16(kVK_ANSI_V))!
        NSApp.sendEvent(pasteEvent)
        guard secret.currentEditor()?.string == "fixture-key-1" else { throw VoiceError("⌘V 未粘贴到密钥框。") }
        openSettings()
        window.performClose(nil)
        guard !window.isVisible, stored == "fixture-key-1", engine == .aliyun else { throw VoiceError("关闭设置未保存并启用密钥。") }
        openSettings()
        guard selector.label(forSegment: 1)?.contains("已启用") == true, secret.stringValue.isEmpty,
              secret.placeholderString?.contains("已保存") == true else { throw VoiceError("重新打开未正确显示已保存状态。") }
        clipboard.clearContents()
        clipboard.setString("fixture-key-2", forType: .string)
        paste.performClick(nil)
        refuseWrite = true
        window.performClose(nil)
        guard window.isVisible, stored == "fixture-key-1" else { throw VoiceError("保存失败后未保留设置。") }
        refuseWrite = false
        save.performClick(nil)
        guard !window.isVisible, stored == "fixture-key-2" else { throw VoiceError("粘贴按钮更换密钥失败。") }
        openSettings()
        choose(0)
        guard engine == .apple, selector.label(forSegment: 0)?.contains("已启用") == true,
              selector.label(forSegment: 1) == "阿里云" else { throw VoiceError("Apple 启用标记错误。") }
        choose(1)
        guard engine == .aliyun, stored == "fixture-key-2", selector.label(forSegment: 0) == "Apple 本机",
              selector.label(forSegment: 1)?.contains("已启用") == true else { throw VoiceError("已保存密钥未复用。") }
        window.performClose(nil)
        print("Settings UI: keyboard and button paste, save on close, write failure, saved key and active engine passed")
    }
}
