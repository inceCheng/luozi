import AppKit
import Carbon
import IOKit.hidsystem

enum TalkMode: UInt32, CaseIterable {
    case hold = 1, continuous = 3
    var title: String { self == .hold ? "按住说话" : "持续听写" }
}

struct RecordingLimit: Equatable {
    static let maximum = 12 * 60 * 60
    static let standard = RecordingLimit(seconds: 1800)!
    let seconds: Int

    init?(seconds: Int) {
        guard (1...Self.maximum).contains(seconds) else { return nil }
        self.seconds = seconds
    }
    init?(hours: String, minutes: String, seconds: String) {
        func number(_ input: String, max: Int) -> Int? {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return 0 }
            guard s.allSatisfy({ $0.isNumber }), let n = Int(s), (0...max).contains(n) else { return nil }
            return n
        }
        guard let h = number(hours, max: 12), let m = number(minutes, max: 59), let s = number(seconds, max: 59)
        else { return nil }
        self.init(seconds: h * 3600 + m * 60 + s)
    }
    var title: String {
        [(seconds / 3600, "小时"), (seconds / 60 % 60, "分钟"), (seconds % 60, "秒")]
            .compactMap { $0.0 == 0 ? nil : "\($0.0) \($0.1)" }.joined(separator: " ")
    }
    func schedule(from start: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await ContinuousClock().sleep(until: start.advanced(by: .seconds(seconds))) }
            catch { return }
            if !Task.isCancelled { action() }
        }
    }
}

struct Shortcut: Hashable {
    let key: UInt32
    let modifiers: UInt32
    static let controlOptionSpace = Shortcut(key: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    static let controlShiftSpace = Shortcut(key: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    static let optionShiftD = Shortcut(key: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey))
    static let rightControl = Shortcut(key: UInt32(kVK_RightControl), modifiers: 0)

    // flagsChanged identifies the physical key by keyCode. Device flags distinguish
    // releasing right Control while left Control is still held.
    static func rightControlIsDown(_ flags: CGEventFlags) -> Bool {
        let sides = UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)
        if flags.rawValue & sides != 0 { return flags.rawValue & UInt64(NX_DEVICERCTLKEYMASK) != 0 }
        return flags.contains(.maskControl)
    }
    static func rightControlAlone(_ flags: CGEventFlags) -> Bool {
        rightControlIsDown(flags) && flags.rawValue & UInt64(NX_DEVICELCTLKEYMASK) == 0 &&
            flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
    }

    init(key: UInt32, modifiers: UInt32) { self.key = key; self.modifiers = modifiers }
    init(event: NSEvent) {
        var mods: UInt32 = 0
        for (flag, mask): (NSEvent.ModifierFlags, Int) in [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { mods |= UInt32(mask) }
        }
        self.init(key: UInt32(event.keyCode), modifiers: mods)
    }

    var title: String {
        let prefixes = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return prefixes.compactMap { modifiers & UInt32($0.0) != 0 ? $0.1 : nil }.joined() + keyName
    }
    private var keyName: String {
        if key == UInt32(kVK_RightControl) { return "右 Ctrl" }
        let specials = [kVK_Space:"空格", kVK_Return:"↩", kVK_Tab:"⇥", kVK_Escape:"Esc", kVK_Delete:"⌫",
            kVK_ForwardDelete:"⌦", kVK_LeftArrow:"←", kVK_RightArrow:"→", kVK_UpArrow:"↑", kVK_DownArrow:"↓",
            kVK_Home:"Home", kVK_End:"End", kVK_PageUp:"PgUp", kVK_PageDown:"PgDn", kVK_ANSI_KeypadEnter:"小键盘 ↩"]
        if let name = specials[Int(key)] { return name }
        let functions = [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,
                         kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20]
        if let index = functions.firstIndex(of: Int(key)) { return "F\(index + 1)" }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                              OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars) == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "键 \(key)"
    }
}

struct Bindings: Equatable {
    static let standard = Bindings(hold: .controlOptionSpace, continuous: .controlShiftSpace)
    var hold: Shortcut
    var continuous: Shortcut
    subscript(_ mode: TalkMode) -> Shortcut {
        get { mode == .hold ? hold : continuous }
        set { if mode == .hold { hold = newValue } else { continuous = newValue } }
    }
    init(hold: Shortcut, continuous: Shortcut) { self.hold = hold; self.continuous = continuous }
    init(defaults: UserDefaults) {
        func saved(_ name: String) -> Shortcut? {
            guard let pair = defaults.dictionary(forKey: name) as? [String: Int],
                  let key = pair["key"], (0...127).contains(key), let mods = pair["modifiers"],
                  mods >= 0, mods & ~(controlKey | optionKey | shiftKey | cmdKey) == 0 else { return nil }
            return Shortcut(key: UInt32(key), modifiers: UInt32(mods))
        }
        let legacy = [Self.standard.hold, Self.standard.continuous, .optionShiftD]
        let index = defaults.integer(forKey: "shortcut")
        hold = saved("holdShortcut") ?? (legacy.indices.contains(index) ? legacy[index] : Self.standard.hold)
        continuous = saved("continuousShortcut") ?? (hold == Self.standard.continuous ? Self.standard.hold : Self.standard.continuous)
    }
    func save(_ defaults: UserDefaults) {
        for (name, item) in [("holdShortcut", hold), ("continuousShortcut", continuous)] {
            defaults.set(["key": Int(item.key), "modifiers": Int(item.modifiers)], forKey: name)
        }
    }
}

final class Hotkeys {
    var onTrigger: ((TalkMode, Bool) -> Void)?
    var onEscape: (() -> Void)?
    private var pressed = Set<UInt32>()
    private var modes = [UInt32: TalkMode]()
    private var entries = [Shortcut: (id: UInt32, ref: EventHotKeyRef)]()
    private var nextID: UInt32 = 10
    private var handler: EventHandlerRef?
    private var escape: EventHotKeyRef?
    private var modifierTap: CFMachPort?
    private var modifierSource: CFRunLoopSource?
    private var rightControlMode: TalkMode?
    private var rightControlHeld = false
    private let signature: OSType = 0x5053504B
    func clearPressedState() { pressed.removeAll(); rightControlHeld = false }

    private func listenForRightControl() throws {
        guard modifierTap == nil else { return }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue, callback: { _, type, event, info in
                if let info {
                    Unmanaged<Hotkeys>.fromOpaque(info).takeUnretainedValue().modifierChanged(type, event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw VoiceError("使用右 Ctrl 需要键盘事件权限，请在设置中点「允许跨应用回填」后重试。")
        }
        modifierTap = tap; modifierSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func modifierChanged(_ type: CGEventType, _ event: CGEvent) {
        guard let mode = rightControlMode else { return }
        let down: Bool
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let modifierTap { CGEvent.tapEnable(tap: modifierTap, enable: true) }
            down = false
        } else {
            guard type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightControl) else { return }
            down = Shortcut.rightControlIsDown(event.flags)
            if down && !Shortcut.rightControlAlone(event.flags) { return }
        }
        guard rightControlHeld != down else { return }
        rightControlHeld = down
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rightControlMode == mode else { return }
            self.onTrigger?(mode, down)
        }
    }

    private func removeModifierTap() {
        if let modifierSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), modifierSource, .commonModes) }
        if let modifierTap { CFMachPortInvalidate(modifierTap) }
        modifierTap = nil; modifierSource = nil; rightControlHeld = false
    }

    init() {
        var events = [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: $0)
        }
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == keys.signature else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if let mode = keys.modes[id.id] {
                if down {
                    if keys.pressed.insert(id.id).inserted { keys.onTrigger?(mode, true) }
                } else if keys.pressed.remove(id.id) != nil { keys.onTrigger?(mode, false) }
            } else if id.id == 2 && down { keys.onEscape?() }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    // Existing chords keep their registration when swapping the two modes.
    // Only publish the new mapping after every registration and optional settings write succeeds.
    func configure(_ desired: [TalkMode: Shortcut], beforeCommit: () throws -> Void = {}) throws {
        guard Set(desired.values).count == desired.count else { throw VoiceError("两个模式需要不同的快捷键。") }
        var next = [Shortcut: (id: UInt32, ref: EventHotKeyRef)]()
        var added = [EventHotKeyRef]()
        var mapping = [UInt32: TalkMode]()
        let modifierMode = desired.first { $0.value == .rightControl }?.key
        do {
            if modifierMode != nil { try listenForRightControl() }
            for mode in TalkMode.allCases {
                guard let shortcut = desired[mode], shortcut != .rightControl else { continue }
                if let old = entries[shortcut] { next[shortcut] = old; mapping[old.id] = mode; continue }
                var ref: EventHotKeyRef?
                nextID += 1
                guard handler != nil, RegisterEventHotKey(shortcut.key, shortcut.modifiers, .init(signature: signature, id: nextID),
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref) == noErr, let ref else {
                    throw VoiceError("「\(mode.title)」的 \(shortcut.title) 已被占用或系统不可用，请重新录入。")
                }
                added.append(ref); next[shortcut] = (nextID, ref); mapping[nextID] = mode
            }
            try beforeCommit()
        } catch {
            added.forEach { UnregisterEventHotKey($0) }
            if rightControlMode == nil { removeModifierTap() }
            throw error
        }
        if modifierMode != rightControlMode { rightControlHeld = false }
        rightControlMode = modifierMode
        if modifierMode == nil { removeModifierTap() }
        for (key, entry) in entries where next[key] == nil { UnregisterEventHotKey(entry.ref) }
        entries = next; modes = mapping
        pressed.formIntersection(mapping.keys)
    }

    func enableEscape(_ enabled: Bool) {
        if let escape { UnregisterEventHotKey(escape); self.escape = nil }
        if enabled {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, .init(signature: signature, id: 2), GetApplicationEventTarget(), 0, &escape)
        }
    }
    deinit {
        removeModifierTap()
        entries.values.forEach { UnregisterEventHotKey($0.ref) }
        if let escape { UnregisterEventHotKey(escape) }
        if let handler { RemoveEventHandler(handler) }
    }
}
