import AppKit
import AVFoundation
import Carbon

enum Engine: String { case apple, aliyun
    var title: String { self == .apple ? "Apple 本机" : "阿里云" }
}

@MainActor final class WaveformView: NSView {
    private var envelope = [CGFloat](repeating: 0, count: 9)
    private var smoothed: CGFloat = 0
    private let ink = NSColor(srgbRed: 0.52, green: 0.90, blue: 0.84, alpha: 1)

    func sample(_ level: CGFloat) {
        smoothed += (level - smoothed) * (level > smoothed ? 0.82 : 0.44)
        if smoothed < 0.015 { smoothed = 0 }
        if smoothed == 0 && envelope.allSatisfy({ $0 == 0 }) { return }
        envelope.removeFirst()
        envelope.append(smoothed)
        needsDisplay = true
    }

    func reset() {
        smoothed = 0
        envelope = Array(repeating: 0, count: envelope.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bars = NSBezierPath()
        let step = bounds.width / CGFloat(envelope.count)
        for (index, value) in envelope.enumerated() {
            let height = 2.4 + value * (bounds.height - 2.4)
            let bar = NSRect(x: (CGFloat(index) + 0.5) * step - 1.2, y: bounds.midY - height / 2,
                             width: 2.4, height: height)
            bars.appendRoundedRect(bar, xRadius: 1.2, yRadius: 1.2)
        }
        ink.setFill()
        bars.fill()
    }
}

@MainActor final class RecordingPanel {
    private let waveform = WaveformView()
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var meterTimer: Timer?
    private var expiry: Timer?
    private var screenFrame: NSRect?
    private var hasPreview = false
    private let recordingSize = NSSize(width: 216, height: 26)

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 13
        effect.layer?.masksToBounds = true
        symbol.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        symbol.contentTintColor = .labelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        for view in [waveform, spinner, symbol, label] { effect.addSubview(view) }
        p.contentView = effect
        return p
    }()

    private func present(size: NSSize) {
        let p = panel
        if screenFrame == nil {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            screenFrame = screen?.visibleFrame
        }
        guard let area = screenFrame else { return }
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 48, width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: false) }
        if !p.isVisible {
            p.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
            p.orderFrontRegardless()
            if p.alphaValue == 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    p.animator().alphaValue = 1
                }
            }
        }
    }

    func start(_ prompt: String, meter: AudioLevelMeter) {
        stopAnimations()
        screenFrame = nil
        hasPreview = false
        waveform.reset()
        waveform.frame = NSRect(x: 10, y: 5, width: 36, height: 16)
        waveform.isHidden = false
        symbol.isHidden = true
        spinner.frame = NSRect(x: 20, y: 5, width: 16, height: 16)
        label.frame = NSRect(x: 54, y: 5, width: recordingSize.width - 65, height: 16)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        label.stringValue = prompt
        present(size: recordingSize)
        let interval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 1.0 / 24
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.waveform.sample(meter.level)
            }
        }
        timer.tolerance = interval * 0.15
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func updateTranscript(_ text: String) {
        guard meterTimer != nil else { return }
        let tail = text.suffix(90).split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !tail.isEmpty else { return }
        hasPreview = true
        if label.stringValue != tail { label.stringValue = tail }
    }

    func processing(reachedLimit: Bool = false) {
        stopAnimations()
        waveform.isHidden = true
        symbol.isHidden = true
        spinner.startAnimation(nil)
        if reachedLimit { label.stringValue = "已到时限 · 转写中" }
        else if !hasPreview { label.stringValue = "转写中" }
        present(size: recordingSize)
    }

    func showNotice(_ text: String) {
        stopAnimations()
        waveform.isHidden = true
        symbol.isHidden = false
        let content = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let measured = ceil((content as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)]).width) + 4
        let labelWidth = min(measured, 245)
        let height: CGFloat = measured > labelWidth ? 42 : 26
        symbol.frame = NSRect(x: 9, y: (height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: 5, width: labelWidth, height: height - 10)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = content
        present(size: NSSize(width: 38 + labelWidth, height: height))
        expiry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] timer in
            MainActor.assumeIsolated { if self?.expiry === timer { self?.hide() } }
        }
    }

    private func stopAnimations() {
        meterTimer?.invalidate()
        meterTimer = nil
        expiry?.invalidate()
        expiry = nil
        spinner.stopAnimation(nil)
    }

    func hide() {
        stopAnimations()
        panel.orderOut(nil)
        screenFrame = nil
    }
}

// A menu-bar app has no Edit menu to route standard shortcuts to its field editor.
@MainActor private final class PreferencesWindow: NSWindow {
    weak var keyField: NSSecureTextField?
    var pasteKey: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": performClose(nil); return true
            case "v", "a":
                if let editor = keyField?.currentEditor() as? NSTextView, firstResponder === editor {
                    if event.charactersIgnoringModifiers?.lowercased() == "v" { pasteKey?() }
                    else { editor.selectAll(nil) }
                    return true
                }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class Preferences: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let window: PreferencesWindow
    private let mode = NSSegmentedControl(labels: ["Apple 本机", "阿里云"], trackingMode: .selectOne, target: nil, action: nil)
    private let holdButton = NSButton()
    private let continuousButton = NSButton()
    private let hour = NSTextField()
    private let minute = NSTextField()
    private let second = NSTextField()
    private var bindings = Bindings.standard
    private var recording: TalkMode?
    var isCapturingShortcut: Bool { recording != nil && window.isKeyWindow }
    private var captureMonitor: Any?
    private let secret = NSSecureTextField()
    private let keyRow = NSStackView()
    private let clipboard: NSPasteboard
    private let hasSavedKey: () throws -> Bool
    private let activate: (Engine, String?) throws -> Void
    private var activeEngine = Engine.apple
    private var storedKey: Bool?
    private var selectedEngine: Engine { mode.selectedSegment == 1 ? .aliyun : .apple }
    private var draftKey: String? {
        let value = (secret.currentEditor()?.string ?? secret.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let lastRecognition = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let microphone = NSButton()
    private let access = NSButton()
    private let assets = NSButton()
    private let save: (Engine, Bindings, RecordingLimit, String?) throws -> Void

    init(hasSavedKey: @escaping () throws -> Bool = KeyStore.hasSavedKey, clipboard: NSPasteboard = .general,
         activate: @escaping (Engine, String?) throws -> Void,
         save: @escaping (Engine, Bindings, RecordingLimit, String?) throws -> Void) {
        self.hasSavedKey = hasSavedKey
        self.clipboard = clipboard
        self.activate = activate
        self.save = save
        window = PreferencesWindow(contentRect: NSRect(x: 0, y: 0, width: 475, height: 545),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "落字 · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)])
        func label(_ text: String) -> NSTextField {
            let value = NSTextField(labelWithString: text)
            value.font = .systemFont(ofSize: 13, weight: .semibold)
            return value
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.spacing = 8; return row
        }
        mode.target = self; mode.action = #selector(changedMode)
        for (button, mode) in [(holdButton, TalkMode.hold), (continuousButton, .continuous)] {
            button.bezelStyle = .rounded
            button.tag = Int(mode.rawValue)
            button.target = self
            button.action = #selector(startCapture(_:))
            button.toolTip = "点按后按下新的快捷键"
            button.setAccessibilityLabel("修改" + mode.title + "快捷键")
        }
        for (field, unit) in [(hour, "小时"), (minute, "分钟"), (second, "秒")] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
            field.setAccessibilityLabel("持续听写时限，" + unit)
        }
        let timing = row([hour, NSTextField(labelWithString: "时"), minute, NSTextField(labelWithString: "分"),
                          second, NSTextField(labelWithString: "秒")])
        secret.delegate = self
        secret.setAccessibilityLabel("北京地域的百炼 API Key")
        window.keyField = secret
        window.pasteKey = { [weak self] in self?.pasteKey(replaceAll: false) }
        let paste = NSButton(title: "粘贴", target: self, action: #selector(pasteFromClipboard))
        keyRow.spacing = 8
        keyRow.addArrangedSubview(secret)
        keyRow.addArrangedSubview(paste)
        secret.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secret.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        lastRecognition.font = hint.font
        lastRecognition.textColor = .secondaryLabelColor
        lastRecognition.isHidden = true
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        for (button, action) in [(microphone, #selector(requestMic)), (access, #selector(requestAccess)), (assets, #selector(prepareAssets))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        assets.title = "准备中文资源"
        let resetButton = NSButton(title: "重置", target: self, action: #selector(resetShortcuts))
        resetButton.controlSize = .small
        resetButton.setAccessibilityLabel("重置启动快捷键")
        resetButton.toolTip = "恢复两组默认快捷键"
        let shortcutHeader = row([label("启动快捷键"), NSView(), resetButton])
        let saveButton = NSButton(title: "保存", target: self, action: #selector(apply))
        saveButton.keyEquivalent = "\r"
        [label("识别引擎"), mode, hint, keyRow, lastRecognition, shortcutHeader,
         row([holdButton, NSTextField(labelWithString: "按住说话，松开输入")]),
         row([continuousButton, NSTextField(labelWithString: "点按开始，按任意键输入")]),
         label("持续听写时限（最长 12 小时）"), timing, label("系统权限"),
         row([microphone, access]), assets, message, saveButton].forEach { stack.addArrangedSubview($0) }
        [hint, keyRow, message, shortcutHeader].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.center()
    }
    func showLastRecognition(engine: Engine, time: Date, model: String? = nil) {
        let date = DateFormatter.localizedString(from: time, dateStyle: .short, timeStyle: .medium)
        let title = model == AliyunDictation.model ? "阿里云（口语润色）" : engine.title
        lastRecognition.stringValue = "上次成功转写：\(title) · \(date)"
        lastRecognition.toolTip = model
        lastRecognition.isHidden = false
    }
    func show(engine: Engine, bindings: Bindings, limit: RecordingLimit) {
        if window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        endCapture()
        self.bindings = bindings
        updateButtons()
        hour.stringValue = String(limit.seconds / 3600)
        minute.stringValue = String(limit.seconds / 60 % 60)
        second.stringValue = String(limit.seconds % 60)
        mode.selectedSegment = engine == .apple ? 0 : 1
        secret.stringValue = ""
        activeEngine = engine
        storedKey = try? hasSavedKey()
        renderEngine()
        refreshPermissions()
        message.stringValue = "点按快捷键按钮即可修改。按住模式下可用 Esc 取消。"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Clicking the red close button saves a typed or pasted credential, even
        // while the secure field is still being edited. Shortcuts keep their Save flow.
        guard let key = draftKey else { return true }
        return commitEngine(selectedEngine, key: key)
    }
    func windowWillClose(_ notification: Notification) { endCapture(); secret.stringValue = "" }
    func windowDidResignKey(_ notification: Notification) { endCapture() }

    private func updateButtons() {
        holdButton.title = recording == .hold ? "请按下快捷键…" : bindings.hold.title
        continuousButton.title = recording == .continuous ? "请按下快捷键…" : bindings.continuous.title
    }
    @objc private func resetShortcuts() {
        bindings = .standard
        endCapture()
        message.stringValue = "已恢复默认快捷键，点击「保存」后生效。"
    }
    private func endCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        recording = nil
        updateButtons()
    }
    @discardableResult func record(_ shortcut: Shortcut) -> Bool {
        guard let recording, window.isKeyWindow else { return false }
        bindings[recording] = shortcut
        endCapture()
        message.stringValue = "已录入，点击「保存」后生效。"
        return true
    }
    @objc private func startCapture(_ sender: NSButton) {
        endCapture()
        window.makeFirstResponder(nil)
        recording = TalkMode(rawValue: UInt32(sender.tag))
        updateButtons()
        message.stringValue = "按下组合键，或单独按下再松开右 Ctrl。Esc 取消。"
        var rightControlCandidate = false
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording != nil else { return event }
            if event.type == .flagsChanged {
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                if event.keyCode != UInt16(kVK_RightControl) { rightControlCandidate = false }
                else if Shortcut.rightControlIsDown(flags) { rightControlCandidate = Shortcut.rightControlAlone(flags) }
                else if rightControlCandidate { self.record(.rightControl) }
                return event
            }
            guard event.type == .keyDown else { self.endCapture(); return event }
            if !event.isARepeat {
                let shortcut = Shortcut(event: event)
                if shortcut.key == UInt32(kVK_Escape), shortcut.modifiers == 0 {
                    self.endCapture()
                    self.message.stringValue = "已取消快捷键录入。"
                } else { self.record(shortcut) }
            }
            return nil
        }
    }
    private func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        microphone.title = mic ? "麦克风已授权" : "允许麦克风"
        microphone.isEnabled = !mic
        let trusted = AXIsProcessTrusted()
        access.title = trusted ? "回填已授权" : "允许跨应用回填"
        access.isEnabled = !trusted
    }
    private func renderEngine() {
        let cloud = selectedEngine == .aliyun
        keyRow.isHidden = !cloud
        for (index, engine) in [Engine.apple, .aliyun].enumerated() {
            let enabled = activeEngine == engine && (engine == .apple || storedKey == true)
            mode.setLabel(engine.title + (enabled ? " · 已启用" : ""), forSegment: index)
        }
        secret.placeholderString = storedKey == true ? "已保存 · 粘贴新密钥可替换" : "北京地域的百炼 API Key"
        if !cloud { hint.stringValue = "使用 Mac 上的普通话听写资源，音频在本机处理。" }
        else if draftKey != nil { hint.stringValue = "新密钥待保存，点「保存」或关闭设置后生效。" }
        else if storedKey == true { hint.stringValue = "API Key 已保存在钥匙串。云端模型 \(AliyunDictation.model) 已开启口语润色。" }
        else if storedKey == false { hint.stringValue = "尚未配置 API Key。粘贴后点「保存」或关闭设置，即可启用。" }
        else { hint.stringValue = "无法确认钥匙串中的密钥，请检查钥匙串访问权限。" }
    }

    private func commitEngine(_ engine: Engine, key: String?) -> Bool {
        do {
            try activate(engine, key)
            activeEngine = engine
            if key != nil { storedKey = true; clearDraftKey() }
            renderEngine()
            return true
        } catch {
            message.stringValue = error.localizedDescription
            renderEngine()
            return false
        }
    }

    private func clearDraftKey() {
        secret.currentEditor()?.string = ""
        secret.stringValue = ""
    }

    @objc private func changedMode() {
        endCapture()
        storedKey = try? hasSavedKey()
        let engine = selectedEngine
        if engine == .aliyun && storedKey != true && draftKey == nil {
            renderEngine()
            window.makeFirstResponder(secret)
        } else if commitEngine(engine, key: draftKey) {
            message.stringValue = ""
        }
    }

    func controlTextDidChange(_ notification: Notification) { renderEngine() }

    @objc private func pasteFromClipboard() { pasteKey(replaceAll: true) }

    private func pasteKey(replaceAll: Bool) {
        guard let value = clipboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { message.stringValue = "剪贴板中没有可粘贴的文本。"; return }
        window.makeFirstResponder(secret)
        guard let editor = secret.currentEditor() as? NSTextView else { return }
        let range = replaceAll ? NSRange(location: 0, length: editor.string.utf16.count) : editor.selectedRange()
        editor.insertText(value, replacementRange: range)
        message.stringValue = ""
        renderEngine()
    }
    @objc private func requestMic() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            refreshPermissions()
        }
    }
    @objc private func requestAccess() {
        Self.openInputPermission()
    }
    static func openInputPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func prepareAssets() {
        assets.isEnabled = false
        message.stringValue = "正在检查普通话听写资源…"
        Task {
            do { try await AppleDictation.prepare(); message.stringValue = "本机中文听写资源已就绪。" }
            catch { message.stringValue = error.localizedDescription }
            assets.isEnabled = true
        }
    }
    @objc private func apply() {
        let engine = selectedEngine
        do {
            guard let limit = RecordingLimit(hours: hour.stringValue, minutes: minute.stringValue, seconds: second.stringValue) else {
                throw VoiceError("请输入 1 秒到 12 小时的有效时长，分和秒的范围为 0–59。")
            }
            try save(engine, bindings, limit, draftKey)
            clearDraftKey()
            window.close()
        } catch { message.stringValue = error.localizedDescription }
    }
}
