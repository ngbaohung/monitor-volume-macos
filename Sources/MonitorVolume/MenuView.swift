import CoreAudio
import SwiftUI

/// Content of the menu bar popover, laid out like a Control Center module.
struct MenuView: View {
    @Bindable var controller: VolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker
            if controller.isAvailable {
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

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use volume keys", isOn: $controller.keysEnabled)
                Toggle("Open at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                HStack {
                    Toggle("Set volume at login", isOn: $controller.setVolumeAtLogin)
                    Spacer()
                    Stepper(value: $controller.loginVolume, in: 0...100, step: 5) {
                        Text("\(controller.loginVolume)%")
                            .monospacedDigit()
                            .foregroundStyle(controller.setVolumeAtLogin ? .primary : .secondary)
                    }
                    .disabled(!controller.setVolumeAtLogin)
                }
                .disabled(!controller.launchAtLogin)
                if controller.mode == .hardware {
                    Toggle("Reset to 100% when Mac sleeps", isOn: $controller.resetOnSleep)
                        .help("Gives another computer on this monitor full volume. Your level is restored on wake.")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
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
        .onAppear { controller.refresh() }
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
            if controller.isAvailable {
                Text("\(controller.isMuted ? 0 : controller.volume)%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Volume mode", selection: $controller.mode) {
                Text("Monitor").tag(VolumeMode.hardware)
                Text("Mac").tag(VolumeMode.software)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(controller.mode == .hardware
                 ? "Changes the monitor's own volume. Other computers on this monitor share it."
                 : "The Mac turns its own audio down. The monitor stays at 100% for other computers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Picker("Play sound effects through", selection: Binding(
                get: { controller.soundEffectsOutputID ?? 0 },
                set: { controller.selectSoundEffectsOutput($0) }
            )) {
                ForEach(controller.soundEffectsDevices) { device in
                    Label(device.name, systemImage: device.symbolName).tag(device.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
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
