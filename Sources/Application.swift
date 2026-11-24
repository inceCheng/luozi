import AppKit
import AVFoundation
import Carbon

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let keys = Hotkeys()
    private let hud = RecordingPanel()
    private var status: NSStatusItem!
    private var preferences: Preferences?
    private var bindings = Bindings.standard
    private var limit = RecordingLimit.standard
    private let stopKey = StopKey()
    private var durationTask: Task<Void, Never>?
    private var talkMode: TalkMode?
    private var confirmed: ConfirmedText?
    private var engine: Engine = .apple
    private var recent = ""
    private var microphone: Microphone?
    private var active: UUID?
    private var job: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var inserting = false
    private var queryingMic = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .apple
        bindings = Bindings(defaults: defaults)
        limit = RecordingLimit(seconds: defaults.integer(forKey: "continuousLimitSeconds")) ?? .standard
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        refreshIcon()
        var shortcutIssue: String?
        do { try keys.configure([.hold: bindings.hold, .continuous: bindings.continuous]) }
        catch {
            shortcutIssue = error.localizedDescription
            do { try keys.configure([.hold: bindings.hold]) }
            catch { try? keys.configure([.continuous: bindings.continuous]) }
        }
        keys.onTrigger = { [weak self] mode, down in
            guard let self else { return }
            if down {
                if self.bindings[mode] == .rightControl, self.preferences?.isCapturingShortcut == true { return }
                if self.preferences?.record(self.bindings[mode]) == true { return }
                if self.talkMode == .continuous, self.microphone != nil { self.finishRecording() }
                else { self.begin(mode) }
            } else if mode == .continuous { self.stopKey.triggerReleased() }
            else if self.talkMode == .hold { self.finishRecording() }
        }
        keys.onEscape = { [weak self] in self?.cancel() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        if !defaults.bool(forKey: "opened") || shortcutIssue != nil {
            showSettings()
            defaults.set(true, forKey: "opened")
            if let shortcutIssue { notify("请修改快捷键", shortcutIssue) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = menu.addItem(withTitle: "\(engine.title)  ·  按住 \(bindings.hold.title)  ·  持续 \(bindings.continuous.title)", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        let copy = menu.addItem(withTitle: "复制最近一次听写", action: recent.isEmpty ? nil : #selector(copyRecent), keyEquivalent: "")
        copy.target = self
        if active != nil && !inserting {
            menu.addItem(withTitle: "取消本次听写", action: #selector(cancelButton), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "当前仅复制 · 开启直接输入…", action: #selector(authorizeInput), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出落字", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    private func refreshIcon() {
        let name = active == nil ? "waveform" : "waveform.circle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "落字")
        image?.isTemplate = true
        status.button?.image = image
        status.button?.toolTip = "落字 · \(engine.title) · 按住 \(bindings.hold.title) / 持续 \(bindings.continuous.title)"
    }
    @objc private func copyRecent() {
        TranscriptDelivery.copy(recent)
    }
    @objc private func authorizeInput() { Preferences.openInputPermission() }
    private func activateEngine(_ selected: Engine, key: String?) throws {
        if let key { try KeyStore.save(key) }
        else if selected == .aliyun, try !KeyStore.hasSavedKey() {
            throw VoiceError("请先粘贴北京地域的百炼 API Key。")
        }
        engine = selected
        defaults.set(selected.rawValue, forKey: "engine")
        refreshIcon()
    }
    @objc private func showSettings() {
        if !inserting { cancel(silent: true) }
        if preferences == nil {
            preferences = Preferences(activate: { [unowned self] selected, key in
                try activateEngine(selected, key: key)
            }) { [weak self] engine, bindings, limit, key in
                guard let self else { return }
                try self.keys.configure([.hold: bindings.hold, .continuous: bindings.continuous]) {
                    try self.activateEngine(engine, key: key)
                }
                self.bindings = bindings; self.limit = limit
                bindings.save(self.defaults)
                self.defaults.set(limit.seconds, forKey: "continuousLimitSeconds")
                self.refreshIcon()
            }
        }
        if let last = defaults.dictionary(forKey: "lastSuccessfulRecognition"),
           let name = last["engine"] as? String, let used = Engine(rawValue: name), let time = last["time"] as? Date {
            preferences?.showLastRecognition(engine: used, time: time, model: last["model"] as? String)
        }
        preferences?.show(engine: engine, bindings: bindings, limit: limit)
    }

    private func begin(_ interaction: TalkMode) {
        guard active == nil, !queryingMic else { return }
        guard !IsSecureEventInputEnabled() else { notify("安全输入已启用", "请移到普通文本输入框后重试。"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                queryingMic = true
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    queryingMic = false
                    notify(granted ? "麦克风已就绪" : "需要麦克风权限", granted ? "请重新按快捷键说话。" : "在落字设置中允许使用麦克风。")
                }
            } else { notify("需要麦克风权限", "打开菜单栏的落字设置，允许使用麦克风。") }
            return
        }
        let mode = engine
        do {
            let key = mode == .aliyun ? try KeyStore.read() : ""
            if mode == .aliyun && key.isEmpty { throw VoiceError("请在设置中填写百炼 API Key。") }
            let id = UUID()
            if interaction == .continuous {
                try stopKey.start(trigger: bindings.continuous) { [weak self] in
                    if self?.active == id { self?.finishRecording() }
                }
            }
            let mic = Microphone()
            let started = ContinuousClock.now
            try mic.start()
            talkMode = interaction
            active = id; microphone = mic
            keys.enableEscape(interaction == .hold)
            if interaction == .continuous {
                durationTask = limit.schedule(from: started) { [weak self] in
                    if self?.active == id { self?.finishRecording(reachedLimit: true) }
                }
            }
            let buffer = ConfirmedText()
            confirmed = buffer
            refreshIcon()
            hud.start(interaction == .hold ? "正在听写…" : "持续听写中…", meter: mic.meter)
            let chunks = mic.chunks
            let preview: Preview = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.active == id, self.microphone != nil, !self.inserting, !value.isEmpty else { return }
                    self.hud.updateTranscript(value)
                }
            }
            job = Task {
                do {
                    if let app = InputTarget.frontApplication { InputTarget.prepareAccessibility(for: app) }
                    let text: String
                    switch mode {
                    case .apple: text = try await AppleDictation.run(chunks, confirmed: buffer, preview: preview)
                    case .aliyun: text = try await AliyunDictation.run(chunks, key: key, confirmed: buffer, preview: preview)
                    }
                    guard active == id else { return }
                    if !text.isEmpty {
                        let time = Date()
                        let model = mode == .aliyun ? AliyunDictation.model : nil
                        var receipt: [String: Any] = ["engine": mode.rawValue, "time": time]
                        if let model { receipt["model"] = model }
                        defaults.set(receipt, forKey: "lastSuccessfulRecognition")
                        preferences?.showLastRecognition(engine: mode, time: time, model: model)
                    }
                    await deliver(text, id: id)
                } catch {
                    guard active == id else { return }
                    failRecording(error.localizedDescription)
                }
            }
        } catch { stopKey.endRecording(); notify("无法开始听写", error.localizedDescription) }
    }

    private func finishRecording(reachedLimit: Bool = false) {
        guard let id = active, let microphone else { return }
        durationTask?.cancel(); durationTask = nil
        stopKey.endRecording()
        microphone.stop(); self.microphone = nil
        hud.processing(reachedLimit: reachedLimit)
        deadline = Task {
            do { try await Task.sleep(for: .seconds(28)) } catch { return }
            if active == id && !inserting {
                job?.cancel()
                failRecording("识别等待超时。")
            }
        }
    }

    private func deliver(_ text: String, id: UUID) async {
        guard active == id else { return }
        hud.hide()
        if text.isEmpty { reset(); return }
        recent = text
        inserting = true
        keys.enableEscape(false)
        let delivered = await TranscriptDelivery.send(text)
        reset()
        if !delivered { notify("剪贴板写入失败", "可从菜单复制最近一次听写。") }
    }
    private func notify(_ title: String, _ detail: String) {
        hud.showNotice(title + " · " + detail)
    }
    private func failRecording(_ detail: String) {
        let partial = confirmed?.value() ?? ""
        if !partial.isEmpty { recent = partial }
        reset()
        notify("听写未完成", partial.isEmpty ? detail : detail + " 可从菜单复制已识别的部分。")
    }
    private func reset() {
        durationTask?.cancel(); durationTask = nil
        stopKey.endRecording()
        talkMode = nil; confirmed = nil
        active = nil; inserting = false
        microphone?.stop(); microphone = nil
        deadline?.cancel(); deadline = nil
        job = nil
        keys.enableEscape(false)
        refreshIcon()
    }
    private func cancel(silent: Bool = false) {
        guard active != nil, !inserting else { return }
        job?.cancel()
        reset()
        if silent { hud.hide() } else { notify("已取消听写", "本次内容已丢弃。") }
    }
    @objc private func sleeping() { keys.clearPressedState(); stopKey.invalidate(); cancel(silent: true) }
    @objc private func cancelButton() { cancel() }
    func applicationWillTerminate(_ notification: Notification) { cancel(silent: true) }
}
