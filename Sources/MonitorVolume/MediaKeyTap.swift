import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

/// Intercepts the hardware volume keys (F10/F11/F12 or the media keys on any
/// keyboard) before the system sees them.
@MainActor
final class MediaKeyTap {
    enum Key {
        case volumeUp, volumeDown, mute
    }

    struct Press {
        let key: Key
        let isRepeat: Bool
    }

    /// Decides whether volume keys are taken from the system right now.
    var shouldIntercept: (() -> Bool)?
    /// Called on key-down (including auto-repeat) for intercepted keys.
    var onPress: ((Press) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Requires Accessibility permission. Returns `false` if the tap could not be created.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << NX_SYSDEFINED)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated { tap.shouldSwallow(type: type, event: event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
    }

    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else { return false }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 0x1

        let key: Key
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: key = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
        case NX_KEYTYPE_MUTE: key = .mute
        default: return false
        }

        guard shouldIntercept?() == true else { return false }

        if isDown {
            onPress?(Press(key: key, isRepeat: isRepeat))
        }
        // Swallow both key-down and key-up so macOS never sees the key.
        return true
    }
}
