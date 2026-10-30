import AppKit
import CoreAudio
import Observation
import ServiceManagement

/// How the volume is changed.
enum VolumeMode: String {
    /// The monitor's own speaker volume, over DDC/CI. Shared with every computer on the monitor.
    case hardware
    /// The Mac turns its audio down before sending it; the monitor keeps its own level
    /// (set in Monitor mode), which is what other computers on the monitor get.
    case software
}

@MainActor
@Observable
final class VolumeController {
    /// One key press = 1%, the monitor's finest DDC volume step. The HUD still shows 10% segments.
    private static let steps = 100.0

    // Monitor hardware volume (DDC).
    private(set) var hardwareVolume = 0
    private(set) var hardwareMaxVolume = 100
    private(set) var hardwareMuted = false
    // Software volume, 0...100.
    private(set) var softwareVolume: Int {
        didSet { UserDefaults.standard.set(softwareVolume, forKey: "softwareVolume") }
    }
    private(set) var softwareMuted = false
    private(set) var softwareRunning = false
    private(set) var softwareProblem: SoftwareProblem?

    enum SoftwareProblem: Equatable {
        case needsPermission
        case outputNotMonitor
        case failed(String)
    }

    var mode: VolumeMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "volumeMode")
            switchMode(from: oldValue)
        }
    }

    // The active mode's values; this is what the UI and the keys work with.
    var volume: Int { mode == .hardware ? hardwareVolume : softwareVolume }
    var maxVolume: Int { mode == .hardware ? hardwareMaxVolume : 100 }
    var isMuted: Bool { mode == .hardware ? hardwareMuted : softwareMuted }
    /// Whether the active mode can currently change the volume.
    var isAvailable: Bool { mode == .hardware ? isConnected : softwareRunning }

    private(set) var isConnected = false
    private(set) var displayName = "Monitor"
    private(set) var hasAccessibility = AXIsProcessTrusted()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var outputDevices = AudioOutput.outputDevices
    private(set) var currentOutputID = AudioOutput.defaultOutputID
    private(set) var soundEffectsDevices: [AudioDevice] = []
    private(set) var soundEffectsOutputID = AudioOutput.systemOutputID

    var keysEnabled: Bool {
        didSet { UserDefaults.standard.set(keysEnabled, forKey: "keysEnabled") }
    }
    /// Put the monitor at 100% when the Mac sleeps or shuts down, so another computer on the
    /// same monitor (e.g. Windows) gets full volume and controls it itself. Restored on wake.
    var resetOnSleep: Bool {
        didSet { UserDefaults.standard.set(resetOnSleep, forKey: "resetOnSleep") }
    }
    /// Set the monitor to `loginVolume` when the app is started automatically at login.
    var setVolumeAtLogin: Bool {
        didSet { UserDefaults.standard.set(setVolumeAtLogin, forKey: "setVolumeAtLogin") }
    }
    var loginVolume: Int {
        didSet { UserDefaults.standard.set(loginVolume, forKey: "loginVolume") }
    }

    /// 0...1
    var level: Double { maxVolume > 0 ? Double(volume) / Double(maxVolume) : 0 }

    @ObservationIgnored private var display: DDCDisplay?
    @ObservationIgnored private let engine = SoftwareVolumeEngine()
    @ObservationIgnored private let keyTap = MediaKeyTap()
    @ObservationIgnored private let hud = VolumeHUD()
    @ObservationIgnored private var accessibilityTimer: Timer?
    /// Volume to apply as soon as the monitor is (re)connected: the login level, or the level before sleep.
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var volumeBeforeSleep: Int?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["keysEnabled": true, "resetOnSleep": true,
                                     "setVolumeAtLogin": true, "loginVolume": 10,
                                     "volumeMode": VolumeMode.software.rawValue, "softwareVolume": 30])
        mode = VolumeMode(rawValue: defaults.string(forKey: "volumeMode") ?? "") ?? .hardware
        softwareVolume = defaults.integer(forKey: "softwareVolume")
        keysEnabled = defaults.bool(forKey: "keysEnabled")
        resetOnSleep = defaults.bool(forKey: "resetOnSleep")
        setVolumeAtLogin = defaults.bool(forKey: "setVolumeAtLogin")
        loginVolume = defaults.integer(forKey: "loginVolume")
        if setVolumeAtLogin && LoginSession.appWasLaunchedAtLogin {
            if mode == .hardware {
                pendingVolume = loginVolume
            } else {
                softwareVolume = loginVolume
            }
        }
        soundEffectsDevices = AudioOutput.soundEffectsDevices(from: outputDevices)

        // The keys control whichever output is selected: the monitor via DDC, anything else via macOS.
        keyTap.shouldIntercept = { [unowned self] in
            keysEnabled && isAvailable && AudioOutput.isDisplayOutput
        }
        keyTap.onPress = { [unowned self] press in handle(press) }

        observeSystemEvents()
        refreshOutputs()
        reconnect()
        startKeyTap()
        registerLoginItemOnFirstLaunch()
    }

    // MARK: Display connection

    func reconnect() {
        Task.detached(priority: .userInitiated) {
            let display = DDCDisplay.discover()
            await MainActor.run { self.attach(display) }
        }
    }

    private func attach(_ display: DDCDisplay?) {
        self.display = display
        isConnected = display != nil
        displayName = NSScreen.screens
            .first { CGDisplayIsBuiltin($0.displayID) == 0 }?
            .localizedName ?? "Monitor"
        if let display, let pendingVolume {
            // Queued before the read below on the same serial queue, so the read sees the new value.
            display.write(.volume, value: UInt16(pendingVolume))
            self.pendingVolume = nil
        }
        refresh()
    }

    /// Re-reads volume and mute from the monitor (it may have changed via its own buttons).
    func refresh() {
        guard let display else { return }
        display.read(.volume) { result in
            guard let result else { return }
            Task { @MainActor in
                self.hardwareMaxVolume = Int(max(result.max, 1))
                self.hardwareVolume = Int(result.current)
            }
        }
        display.read(.mute) { result in
            guard let result else { return }
            Task { @MainActor in self.hardwareMuted = result.current == 1 }
        }
    }

    // MARK: Volume

    func setLevel(_ newLevel: Double, showHUD: Bool = false) {
        let clamped = min(max(newLevel, 0), 1)
        let newVolume = Int((clamped * Double(maxVolume)).rounded())
        switch mode {
        case .hardware:
            hardwareVolume = newVolume
            display?.write(.volume, value: UInt16(newVolume))
        case .software:
            softwareVolume = newVolume
            applySoftwareGain()
        }
        if isMuted && volume > 0 { setMuted(false) }
        if showHUD { hud.show(level: level, muted: isMuted, deviceName: displayName) }
    }

    func setMuted(_ muted: Bool, showHUD: Bool = false) {
        switch mode {
        case .hardware:
            hardwareMuted = muted
            display?.write(.mute, value: muted ? 1 : 2)
        case .software:
            softwareMuted = muted
            applySoftwareGain()
        }
        if showHUD { hud.show(level: level, muted: isMuted, deviceName: displayName) }
    }

    private func handle(_ press: MediaKeyTap.Press) {
        let step = 1 / Self.steps
        switch press.key {
        case .volumeUp:
            setLevel(nextLevel(by: step), showHUD: true)
        case .volumeDown:
            setLevel(nextLevel(by: -step), showHUD: true)
        case .mute:
            guard !press.isRepeat else { return }
            setMuted(!isMuted, showHUD: true)
        }
    }

    /// Snaps to the step grid like macOS does, while guaranteeing the monitor's
    /// integer volume actually moves (the grid rarely lines up with 0...100).
    private func nextLevel(by step: Double) -> Double {
        let rounding: FloatingPointRoundingRule = step > 0 ? .down : .up
        var target = ((level + step) / abs(step)).rounded(rounding) * abs(step)
        if Int((min(max(target, 0), 1) * Double(maxVolume)).rounded()) == volume {
            target += step
        }
        return target
    }

    // MARK: Sound output

    func selectOutput(_ device: AudioDevice) {
        AudioOutput.setDefaultOutput(device.id)
        refreshOutputs()
    }

    /// Alerts and sound effects stay on this device regardless of the main output.
    func selectSoundEffectsOutput(_ id: AudioObjectID) {
        AudioOutput.setSystemOutput(id)
        refreshOutputs()
    }

    private func refreshOutputs() {
        outputDevices = AudioOutput.outputDevices
        soundEffectsDevices = AudioOutput.soundEffectsDevices(from: outputDevices)
        currentOutputID = AudioOutput.defaultOutputID
        soundEffectsOutputID = AudioOutput.systemOutputID
        updateEngine()
    }

    // MARK: Software volume

    /// Each mode keeps its own level; switching never changes the monitor's own volume.
    private func switchMode(from oldMode: VolumeMode) {
        switch mode {
        case .software:
            updateEngine()
        case .hardware:
            stopEngine()
            softwareProblem = nil
        }
    }

    /// Starts, restarts or stops the engine to match the mode, output device and permission.
    private func updateEngine() {
        guard mode == .software else { return stopEngine() }
        guard let device = outputDevices.first(where: { $0.id == currentOutputID }), device.isDisplay else {
            stopEngine()
            softwareProblem = .outputNotMonitor
            return
        }
        switch AudioCapturePermission.status {
        case .granted:
            break
        case .denied:
            stopEngine()
            softwareProblem = .needsPermission
            return
        case .unknown:
            stopEngine()
            softwareProblem = .needsPermission
            AudioCapturePermission.request { granted in
                Task { @MainActor in if granted { self.updateEngine() } }
            }
            return
        }
        guard !(engine.isRunning && engine.deviceID == device.id) else { return }

        applySoftwareGain()
        do {
            try engine.start(device: device)
            softwareRunning = true
            softwareProblem = nil
            NSLog("MonitorVolume: software volume running on \(device.name), own process object: \(AudioOutput.currentProcessObjectID.map(String.init) ?? "none")")
        } catch {
            NSLog("MonitorVolume: software volume failed: \(error.localizedDescription)")
            softwareRunning = false
            softwareProblem = .failed(error.localizedDescription)
        }
    }

    private func stopEngine() {
        engine.stop()
        softwareRunning = false
    }

    /// Perceptual curve: volume 50% ≈ -12 dB, 10% ≈ -40 dB.
    private func applySoftwareGain() {
        let level = Float(softwareVolume) / 100
        engine.setGain(softwareMuted ? 0 : level * level)
    }

    func openAudioCaptureSettings() {
        AudioCapturePermission.openSettings()
    }

    func retrySoftwareVolume() {
        stopEngine()
        updateEngine()
    }

    // MARK: Key tap & permissions

    private func startKeyTap() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility, keyTap.start() {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            return
        }
        // Wait until the user grants Accessibility access, then start.
        guard accessibilityTimer == nil else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in self.startKeyTap() }
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MonitorVolume: launch-at-login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func registerLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "didRegisterLoginItem") else { return }
        UserDefaults.standard.set(true, forKey: "didRegisterLoginItem")
        setLaunchAtLogin(true)
    }

    // MARK: System events

    private func observeSystemEvents() {
        AudioOutput.observeChanges {
            Task { @MainActor in self.refreshOutputs() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.reconnect() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Must finish synchronously: the Mac may sleep as soon as this returns.
                MainActor.assumeIsolated { self.resetForSleep() }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if let level = self.volumeBeforeSleep {
                    self.pendingVolume = level
                    self.volumeBeforeSleep = nil
                }
                // Give the display a moment to come back before talking DDC.
                try? await Task.sleep(for: .seconds(3))
                self.reconnect()
                // The audio route doesn't always survive sleep; rebuild it.
                if self.mode == .software { self.retrySoftwareVolume() }
            }
        }
    }

    private func resetForSleep() {
        guard resetOnSleep, let display else { return }
        volumeBeforeSleep = hardwareVolume
        display.writeNow(.volume, value: UInt16(maxVolume))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
