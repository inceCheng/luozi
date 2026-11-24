import AppKit
import Carbon
import Security

enum KeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.pressspeak.aliyun",
         kSecAttrAccount as String: "beijing"]
    }
    static func hasSavedKey() throws -> Bool {
        // An existence query needs no password data and never fills the settings field.
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw VoiceError("无法确认钥匙串状态（\(status)）。") }
        return true
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8)
        else { throw VoiceError("读取钥匙串失败（\(status)）。") }
        return key
    }
    static func save(_ value: String) throws {
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            let fields = [kSecValueData as String: Data(value.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
            status = updated == errSecItemNotFound
                ? SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) : updated
        }
        guard status == errSecSuccess else { throw VoiceError("保存钥匙串失败（\(status)）。") }
    }
}

private func ax(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

private func canSet(_ element: AXUIElement, _ name: String) -> Bool {
    var writable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
}

private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = ax(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

@MainActor enum TranscriptDelivery {
    static func send(_ text: String, fallbackClipboard: NSPasteboard = .general,
                     pointer: () -> CGPoint? = { CGEvent(source: nil)?.location }) async -> Bool {
        guard !text.isEmpty else { return true }
        if let app = InputTarget.frontApplication {
            InputTarget.prepareAccessibility(for: app)
            // Chromium may publish its focused element shortly after enabling accessibility.
            for attempt in 0..<3 {
                guard InputTarget.frontApplication?.processIdentifier == app.processIdentifier else { break }
                if let target = InputTarget.current() {
                    if await target.insert(text) { return true }
                    break
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(55)) }
                else if let point = pointer(), let target = InputTarget.focusEditor(at: point, in: app),
                        await target.insert(text) { return true }
            }
        }
        return copy(text, to: fallbackClipboard)
    }

    @discardableResult static func copy(_ text: String, to board: NSPasteboard = .general) -> Bool {
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}

struct InputTarget {
    static let pasteTag: Int64 = 0x5053504B56
    let pid: pid_t
    let element: AXUIElement
    let window: AXUIElement?

    static var frontApplication: NSRunningApplication? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    static func prepareAccessibility(for app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let electron = Bundle(url: url)?.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil ||
            FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        let chromium = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser"]
            .contains { app.bundleIdentifier == $0 || app.bundleIdentifier?.hasPrefix($0 + ".") == true }
        guard electron || chromium else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        if electron, AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            return
        }
        if ax(application, "AXEnhancedUserInterface") as? Bool != true {
            AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func excluded(_ element: AXUIElement) -> Bool {
        let subrole = ax(element, kAXSubroleAttribute) as? String ?? ""
        return subrole.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("password") ||
               (ax(element, kAXEnabledAttribute) as? Bool) == false || (ax(element, "AXReadOnly") as? Bool) == true ||
               (ax(element, "AXProtectedContent") as? Bool) == true
    }

    private static func editor(for node: AXUIElement) -> AXUIElement? {
        guard !excluded(node) else { return nil }
        let element = axElement(node, "AXEditableAncestor") ?? node
        guard !excluded(element), (ax(element, "AXEditable") as? Bool) != false else { return nil }
        let role = ax(element, kAXRoleAttribute) as? String ?? ""
        let textRole = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        guard (ax(element, "AXEditable") as? Bool) == true || canSet(element, kAXSelectedTextAttribute) ||
              (textRole && canSet(element, kAXValueAttribute)) else { return nil }
        return element
    }

    private static func focusedNode(in application: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let node = axElement(application, kAXFocusedUIElementAttribute) { return node }
        var owner: pid_t = 0
        guard let node = axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              AXUIElementGetPid(node, &owner) == .success, owner == pid else { return nil }
        return node
    }

    static func current() -> Self? {
        guard let app = frontApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let focused = focusedNode(in: application, pid: app.processIdentifier),
              let element = editor(for: focused) else { return nil }
        return .init(pid: app.processIdentifier, element: element, window: axElement(application, kAXFocusedWindowAttribute))
    }

    static func focusEditor(at point: CGPoint, in app: NSRunningApplication) -> Self? {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard frontApplication?.processIdentifier == pid,
              let window = axElement(application, kAXFocusedWindowAttribute) else { return nil }
        if let focused = focusedNode(in: application, pid: pid),
           excluded(focused) || editor(for: focused) != nil { return nil }

        // Quartz mouse positions and AX hit testing share the global top-left coordinate system.
        var hit: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid,
              let element = editor(for: hit), let hitWindow = axElement(element, kAXWindowAttribute),
              CFEqual(window, hitWindow), frontApplication?.processIdentifier == pid,
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              let target = current(), CFEqual(target.element, element), let focusedWindow = target.window,
              CFEqual(focusedWindow, window) else { return nil }

        // Focusing a native field can select all its contents. A hover insertion must preserve them.
        var position = point
        var result: CFTypeRef?
        var range = CFRange()
        if let param = AXValueCreate(.cgPoint, &position),
           AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
               param, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID(),
           AXValueGetValue(result as! AXValue, .cfRange, &range), range.location >= 0 {
            range.length = 0
        } else if let selected = target.selectionRange() {
            if selected.length == 0 { return target }
            range = CFRange(location: selected.location + selected.length, length: 0)
        } else { return nil }
        guard let caret = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caret) == .success,
              let selection = target.selectionRange(), selection.location == range.location, selection.length == 0
        else { return nil }
        return target
    }

    func stillFocused() -> Bool {
        guard let now = Self.current(), pid == now.pid, CFEqual(element, now.element) else { return false }
        if let window, let other = now.window { return CFEqual(window, other) }
        return window == nil && now.window == nil
    }

    private func selectionRange() -> CFRange? {
        guard let value = ax(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    // A posted Cmd-V has no success receipt. Restore the old clipboard only if
    // the caret and a short suffix confirm that the target consumed this paste.
    private func containsPaste(_ text: String, at start: CFRange?) -> Bool {
        guard let start, let caret = selectionRange(), caret.length == 0 else { return false }
        let length = text.utf16.count
        guard caret.location >= start.location, caret.location - start.location == length else { return false }
        let suffix = String(text.suffix(24))
        var span = CFRange(location: caret.location - suffix.utf16.count, length: suffix.utf16.count)
        guard let parameter = AXValueCreate(.cfRange, &span) else { return false }
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success && (result as? String) == suffix
    }

    // Large or promised clipboard items can be expensive to duplicate. An editable
    // control can still receive Cmd-V in that case; the transcript stays available.
    @MainActor private func snapshot(of board: NSPasteboard) -> [NSPasteboardItem]? {
        var saved = [NSPasteboardItem]()
        var size = 0
        for item in board.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                size += data.count
                guard size <= 8 * 1024 * 1024 else { return nil }
                copy.setData(data, forType: type)
            }
            saved.append(copy)
        }
        return saved
    }

    @MainActor func insert(_ text: String) async -> Bool {
        guard stillFocused() else { return false }
        // Chromium can acknowledge AXSelectedText without updating a contenteditable
        // DOM or firing an input event. Let the web editor handle its regular paste.
        if axElement(element, "AXEditableAncestor") == nil, canSet(element, kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return true }

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        let board = NSPasteboard.general
        let initial = board.changeCount
        let saved = snapshot(of: board)
        let selection = selectionRange()
        guard board.changeCount == initial, stillFocused() else { return false }
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            if let saved, !saved.isEmpty { board.writeObjects(saved) }
            return false
        }
        let change = board.changeCount
        down.setIntegerValueField(.eventSourceUserData, value: Self.pasteTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.pasteTag)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        try? await Task.sleep(for: .milliseconds(600))
        if let saved, board.changeCount == change, containsPaste(text, at: selection), board.changeCount == change {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        return true
    }
}
