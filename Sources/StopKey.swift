import AppKit
import Carbon
import IOKit.hidsystem

// This tap exists only during hands-free recording (and until its ending key is released).
// It uses virtual key codes and modifier transitions; it never reads typed text.
final class StopKey {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var onStop: (() -> Void)?
    private var swallowed: CGKeyCode?
    private var flags: CGEventFlags = []
    private var startupKey: CGKeyCode?
    private var drainTimeout: DispatchWorkItem?

    func start(trigger: Shortcut, onStop: @escaping () -> Void) throws {
        guard swallowed == nil else { throw VoiceError("请松开上一次的结束键再开始。") }
        invalidate()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, kind, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<StopKey>.fromOpaque(info).takeUnretainedValue()
                return monitor.handle(kind, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw VoiceError("持续听写需要键盘事件权限。请在系统隐私设置中允许落字使用辅助功能，按系统提示重新打开。")
        }
        port = tap; source = runSource; self.onStop = onStop
        flags = CGEventSource.flagsState(.combinedSessionState)
        startupKey = CGKeyCode(trigger.key)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Carbon can receive the global shortcut's release before Quartz reports another key.
    func triggerReleased() { startupKey = nil }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let stop = onStop
            invalidate()
            if let stop { DispatchQueue.main.async(execute: stop) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputTarget.pasteTag { return false }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let swallowed {
            guard code == swallowed else { return false }
            if type == .keyUp { invalidate() }
            return type == .keyDown || type == .keyUp
        }
        guard let stop = onStop else { return false }
        if type == .keyUp {
            if code == startupKey { startupKey = nil }
            return false
        }
        if type == .flagsChanged {
            let previous = flags
            flags = event.flags
            guard code != startupKey, Self.modifierPressed(code: code, previous: previous, current: flags) else { return false }
            invalidate()
            DispatchQueue.main.async(execute: stop)
            // A modifier carries no text. Keep the system's modifier-down/up state paired.
            return false
        }
        guard type == .keyDown, code != startupKey, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        self.onStop = nil
        swallowed = code
        // Recover if a device disconnects before sending its key-up.
        let timeout = DispatchWorkItem { [weak self] in self?.invalidate() }
        drainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        DispatchQueue.main.async(execute: stop)
        return true
    }

    static func modifierPressed(code: CGKeyCode, previous: CGEventFlags, current: CGEventFlags) -> Bool {
        // Inspect the key that generated flagsChanged. When Shift and Control started
        // the session, releasing Shift must not count the still-held Control as a press.
        let group: CGEventFlags
        let side: UInt64
        switch Int(code) {
        case kVK_Shift: group = .maskShift; side = UInt64(NX_DEVICELSHIFTKEYMASK)
        case kVK_RightShift: group = .maskShift; side = UInt64(NX_DEVICERSHIFTKEYMASK)
        case kVK_Control: group = .maskControl; side = UInt64(NX_DEVICELCTLKEYMASK)
        case kVK_RightControl: group = .maskControl; side = UInt64(NX_DEVICERCTLKEYMASK)
        case kVK_Option: group = .maskAlternate; side = UInt64(NX_DEVICELALTKEYMASK)
        case kVK_RightOption: group = .maskAlternate; side = UInt64(NX_DEVICERALTKEYMASK)
        case kVK_Command: group = .maskCommand; side = UInt64(NX_DEVICELCMDKEYMASK)
        case kVK_RightCommand: group = .maskCommand; side = UInt64(NX_DEVICERCMDKEYMASK)
        case kVK_Function: group = .maskSecondaryFn; side = 0
        case kVK_CapsLock: return current.contains(.maskAlphaShift) != previous.contains(.maskAlphaShift)
        default: return false
        }
        guard current.contains(group) else { return false }
        return !previous.contains(group) || current.rawValue & ~previous.rawValue & side != 0
    }

    func endRecording() {
        if swallowed == nil { invalidate() }
    }
    func invalidate() {
        drainTimeout?.cancel(); drainTimeout = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil; port = nil; onStop = nil; swallowed = nil; startupKey = nil
    }
    deinit { invalidate() }
}
