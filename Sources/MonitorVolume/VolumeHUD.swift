import AppKit
import SwiftUI

/// On-screen volume overlay shown when a volume key is pressed:
/// a Liquid Glass card with a circular volume knob, centred near the bottom of the screen.
@MainActor
final class VolumeHUD {
    @Observable
    final class Model {
        var level = 0.0
        var muted = false
        var deviceName = ""
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(level: Double, muted: Bool, deviceName: String) {
        model.level = level
        model.muted = muted
        model.deviceName = deviceName

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)

        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUDView.size.width, height: HUDView.size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.12))
    }
}

private struct HUDView: View {
    static let size = CGSize(width: 220, height: 236)

    let model: VolumeHUD.Model

    var body: some View {
        VStack(spacing: 10) {
            VolumeKnob(level: model.muted ? 0 : model.level, muted: model.muted)
                .frame(width: 164, height: 164)
            Text(model.deviceName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 44))
    }
}

/// A rotary knob: a 270° ring split into ten 10% segments (the current one fills
/// proportionally, so fine steps are visible) around a knob whose marker points at the level.
private struct VolumeKnob: View {
    private static let segments = 10
    private static let sweep = 0.75            // fraction of a full turn (270°)
    private static let gap = 0.008             // gap between segments, as a fraction of a turn
    private static let lineWidth: CGFloat = 9

    let level: Double
    let muted: Bool

    var body: some View {
        ZStack {
            ring
                .padding(Self.lineWidth / 2)
                // Circle paths start at 3 o'clock; rotate so the ring starts at the bottom-left.
                .rotationEffect(.degrees(135))

            knob
                .padding(30)

            VolumeIcon(level: level, muted: muted)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(y: 70)
        }
        .animation(.smooth(duration: 0.18), value: level)
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<Self.segments, id: \.self) { index in
                let length = Self.sweep / Double(Self.segments)
                let start = Double(index) * length + Self.gap / 2
                let usable = length - Self.gap
                let fill = min(max(level * Double(Self.segments) - Double(index), 0), 1)

                Circle()
                    .trim(from: start, to: start + usable)
                    .stroke(.primary.opacity(0.15), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: start, to: start + usable * fill)
                    .stroke(.primary, lineWidth: Self.lineWidth)
            }
        }
    }

    private var knob: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.primary.opacity(0.16), .primary.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            // Marker: 0% points at the ring's start (bottom-left), 100% at its end (bottom-right).
            GeometryReader { geo in
                Capsule()
                    .fill(.primary)
                    .frame(width: 4, height: 12)
                    .position(x: geo.size.width / 2, y: 12)
            }
            .rotationEffect(.degrees(-135 + level * 270))

            Text(muted ? "Muted" : "\(Int((level * 100).rounded()))%")
                .font(.system(size: muted ? 15 : 24, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
        }
    }
}

/// Speaker glyph whose waves fill with the level, matching Control Center.
struct VolumeIcon: View {
    let level: Double
    let muted: Bool

    var body: some View {
        Image(systemName: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
              variableValue: level)
            .contentTransition(.symbolEffect(.replace))
            .symbolRenderingMode(.hierarchical)
    }
}
