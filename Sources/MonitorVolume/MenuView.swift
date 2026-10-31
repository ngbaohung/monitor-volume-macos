import CoreAudio
import SwiftUI

/// Content of the menu bar popover, laid out like a Control Center module.
struct MenuView: View {
    @Bindable var controller: VolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker
            if isLockedMonitorTab {
                monitorModeLockedNotice
            } else if controller.isAvailable {
                volumeSlider
            } else if controller.mode == .hardware {
                notConnected
            } else if let problem = controller.softwareProblem {
                softwareNotice(problem)
            }

            if !controller.hasAccessibility {
                accessibilityNotice
            }

            Divider()

            outputList
            soundEffectsPicker

            Divider()

            // Every row has the same height, label on the left and switch on the right, like System Settings.
            VStack(alignment: .leading, spacing: 8) {
                SettingRow("Use volume keys", isOn: $controller.keysEnabled)
                SettingRow("Open at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if controller.selectedTab == .software {
                    // Type a value (applied on Return or when the field loses focus) or step by 1%.
                    let loginVolume = Binding(
                        get: { controller.loginVolume },
                        set: { controller.loginVolume = min(max($0, 0), 100) }
                    )
                    SettingRow("Set volume at login", isOn: $controller.setVolumeAtLogin) {
                        HStack(spacing: 2) {
                            TextField("Login volume", value: loginVolume, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 34)
                            Text("%").foregroundStyle(.secondary)
                            Stepper("Login volume", value: loginVolume, in: 0...100, step: 1)
                                .labelsHidden()
                        }
                        .controlSize(.mini)
                        .disabled(!controller.setVolumeAtLogin)
                    }
                    .disabled(!controller.launchAtLogin)
                }
                SettingRow("Reset monitor to 100% on sleep", isOn: $controller.resetOnSleep)
                    .help("When the Mac sleeps or shuts down, the monitor goes to 100% so another computer on it gets full volume. The monitor's level is restored on wake.")
            }
            .font(.system(size: 13))

            Divider()

            HStack(spacing: 8) {
                Button { controller.reconnect() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            controller.resetSelectedTab()
            controller.refresh()
        }
        .onDisappear { controller.resetSelectedTab() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Monitor Volume").font(.system(size: 13, weight: .semibold))
                Text(controller.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isAvailable && !isLockedMonitorTab {
                Text("\(controller.isMuted ? 0 : controller.volume)%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Custom segmented control: the system one can't show an icon next to a segment's title.
            HStack(spacing: 2) {
                ModeSegment(title: "Monitor", isSelected: controller.selectedTab == .hardware,
                            isLocked: !controller.isMonitorModeUnlocked) {
                    controller.selectTab(.hardware)
                }
                ModeSegment(title: "Mac", isSelected: controller.selectedTab == .software, isLocked: false) {
                    controller.selectTab(.software)
                }
            }
            .padding(2)
            .background(.quaternary, in: .capsule)
            if !isLockedMonitorTab {
                Text(modeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What other computers on the monitor get, accounting for the reset-on-sleep option
    /// (the reset changes the volume only, so a muted monitor stays muted).
    private var isLockedMonitorTab: Bool {
        controller.selectedTab == .hardware && !controller.isMonitorModeUnlocked
    }

    /// The whole content of the Monitor tab until it's unlocked for this session.
    private var monitorModeLockedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Monitor mode is locked", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("It changes your monitor's own hardware volume setting over DDC/CI, not a software or driver setting like Mac mode. The new level stays on the monitor and applies to every computer connected to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(action: controller.unlockMonitorMode) {
                Label("Unlock Monitor Mode", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .controlSize(.large)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
    }

    private var modeDescription: String {
        let afterSleep = "while the Mac is awake, and 100% once it sleeps or shuts down"
        switch controller.mode {
        case .hardware:
            return controller.resetOnSleep
                ? "Changes the monitor's own volume. Other computers get this level \(afterSleep)."
                : "Changes the monitor's own volume. Other computers on this monitor share it."
        case .software:
            let intro = "The Mac turns its own audio down."
            guard controller.isConnected else {
                return "\(intro) The monitor keeps its own level for other computers."
            }
            if controller.hardwareMuted {
                return "\(intro) The monitor is muted for other computers; change it in the Monitor tab."
            }
            let level = "\(controller.hardwareVolume * 100 / max(controller.hardwareMaxVolume, 1))%"
            return controller.resetOnSleep
                ? "\(intro) Other computers get the monitor's \(level) \(afterSleep)."
                : "\(intro) The monitor stays at \(level) for other computers; change it in the Monitor tab."
        }
    }

    private func softwareNotice(_ problem: VolumeController.SoftwareProblem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch problem {
            case .outputNotMonitor:
                Label("Select the monitor as the sound output to control its volume.",
                      systemImage: "display")
            case .needsPermission:
                Label("Allow System Audio Recording so Monitor Volume can adjust the Mac's audio.",
                      systemImage: "waveform")
                Button("Open Privacy Settings…") { controller.openAudioCaptureSettings() }
                    .controlSize(.small)
                    .buttonStyle(.glass)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                Button("Try Again") { controller.retrySoftwareVolume() }
                    .controlSize(.small)
                    .buttonStyle(.glass)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Button {
                controller.setMuted(!controller.isMuted)
            } label: {
                VolumeIcon(level: controller.level, muted: controller.isMuted)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help(controller.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(get: { controller.level }, set: { controller.setLevel($0) }),
                in: 0...1
            )
            .controlSize(.small)
        }
    }

    private var outputList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Output")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 4)
            ForEach(controller.outputDevices) { device in
                OutputRow(device: device, isSelected: device.id == controller.currentOutputID) {
                    controller.selectOutput(device)
                }
            }
        }
    }

    /// Mirrors System Settings › Sound › "Play sound effects through", pinned to a specific device
    /// so alerts can stay on one device while everything else plays through another.
    private var soundEffectsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Play sound effects through")
                .font(.system(size: 13, weight: .semibold))
            // A full-width button that opens a native menu: SwiftUI's menu Picker and Menu both
            // size themselves to their text and ignore a full-width frame on macOS.
            Button(action: showSoundEffectsMenu) {
                let current = controller.soundEffectsDevices.first { $0.id == controller.soundEffectsOutputID }
                HStack(spacing: 8) {
                    Image(systemName: current?.symbolName ?? "speaker.wave.2.fill")
                    Text(current?.name ?? "Choose a device")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .font(.system(size: 13))
        }
    }

    /// Pops up like a standard pop-up button: the current device sits under the pointer, with a checkmark.
    private func showSoundEffectsMenu() {
        let menu = NSMenu()
        var selected: NSMenuItem?
        for device in controller.soundEffectsDevices {
            let item = ClosureMenuItem(title: device.name) { controller.selectSoundEffectsOutput(device.id) }
            item.image = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)
            if device.id == controller.soundEffectsOutputID {
                item.state = .on
                selected = item
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: selected, at: NSEvent.mouseLocation, in: nil)
    }

    private var notConnected: some View {
        Label("No DDC/CI monitor found. Make sure DDC/CI is enabled in the monitor's menu.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow Accessibility access so the volume keys can control your monitor.",
                  systemImage: "keyboard")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings…") { controller.requestAccessibility() }
                .controlSize(.small)
                .buttonStyle(.glass)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

/// A Control Center-style device row: tinted circle when selected, highlight on hover.
private struct OutputRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let action: () -> Void

    // Plain `State` instead of `@State`: the Command Line Tools ship without the SwiftUI macro plugin.
    private let hovered = State(initialValue: false)
    private var isHovered: Bool { hovered.wrappedValue }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(width: 26, height: 26)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                Text(device.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered.wrappedValue = $0 }
        .padding(.horizontal, -6)
    }
}

/// A menu item that runs a closure; it targets itself so no separate target object is needed.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}

/// One segment of the Monitor / Mac switch, drawn like a macOS segmented control.
private struct ModeSegment: View {
    let title: String
    let isSelected: Bool
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    // Adapts like the system control: white in light mode, raised grey in dark mode.
                    Capsule()
                        .fill(Color(nsColor: .controlColor))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Locked: Monitor mode changes the monitor's own hardware volume" : "")
    }
}

/// A settings row of fixed height: label, optional extra controls, then a switch at the trailing edge.
private struct SettingRow<Accessory: View>: View {
    let title: String
    @Binding var isOn: Bool
    let accessory: Accessory

    init(_ title: String, isOn: Binding<Bool>, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._isOn = isOn
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(height: 22)
    }
}

extension SettingRow where Accessory == EmptyView {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(title, isOn: isOn) { EmptyView() }
    }
}
