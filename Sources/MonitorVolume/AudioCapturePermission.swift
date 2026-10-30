import AppKit

/// The "System Audio Recording" privacy permission a process tap needs.
///
/// macOS has no public API to check it, and a tap created without it silently delivers zeros,
/// which would mute the monitor entirely. So we query TCC directly (as Apple's own samples do)
/// and only start the engine once access is granted.
enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    // dlopen handles are process-wide and immutable once loaded.
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunc.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt (only if the user hasn't answered yet) and reports the result on the main queue.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: RequestFunc.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
