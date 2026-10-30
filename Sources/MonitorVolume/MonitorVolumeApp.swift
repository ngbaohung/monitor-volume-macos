import SwiftUI

@main
struct MonitorVolumeApp: App {
    // The App value lives for the whole process, so a plain constant is enough.
    private let controller = VolumeController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: menuBarSymbol, variableValue: controller.level)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if !controller.isAvailable { return "speaker.badge.exclamationmark.fill" }
        return controller.isMuted || controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }
}
