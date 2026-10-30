import CoreAudio
import Foundation

/// A sound output device as shown in the Output list.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    /// `true` for HDMI/DisplayPort devices (i.e. monitor speakers).
    var isDisplay: Bool {
        transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }

    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeBuiltIn: "macmini.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplay.audio"
        default: "hifispeaker.fill"
        }
    }
}

/// Small helpers for listing and switching the system sound output.
enum AudioOutput {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// UID prefix of the private aggregate device the software volume engine creates; hidden from lists.
    static let privateDeviceUIDPrefix = "com.hungnb.MonitorVolume."

    /// `true` when the default output is the monitor's speakers, which macOS cannot change the volume of.
    static var isDisplayOutput: Bool {
        guard let id = defaultOutputID,
              let transport = uint32Property(id, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }

    static var defaultOutputID: AudioObjectID? {
        uint32Property(system, kAudioHardwarePropertyDefaultOutputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// The device alerts and sound effects play through.
    static var systemOutputID: AudioObjectID? {
        uint32Property(system, kAudioHardwarePropertyDefaultSystemOutputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// Devices allowed to play alerts and sound effects.
    static func soundEffectsDevices(from devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter {
            uint32Property($0.id, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioObjectPropertyScopeOutput) == 1
        }
    }

    /// All devices that can play sound, sorted by name.
    static var outputDevices: [AudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> AudioDevice? in
            guard hasOutputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(privateDeviceUIDPrefix),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name,
                               transport: uint32Property(id, kAudioDevicePropertyTransportType) ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// This process's Core Audio process object, so a tap can exclude our own playback.
    static var currentProcessObjectID: AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        setDevice(id, for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setSystemOutput(_ id: AudioObjectID) {
        setDevice(id, for: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private static func setDevice(_ id: AudioObjectID, for selector: AudioObjectPropertySelector) {
        var address = address(selector)
        var value = id
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        if status != noErr {
            NSLog("MonitorVolume: failed to set output device (\(status))")
        }
    }

    /// Calls `handler` on the main queue whenever devices appear/disappear or an output selection changes.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in handler() }
        }
    }

    // MARK: Property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
