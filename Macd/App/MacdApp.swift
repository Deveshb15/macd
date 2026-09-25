import SwiftUI

@main
struct MacdApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Disk Map", id: WindowID.analyze) {
            DiskMapWindow(model: model.diskMap)
        }
        .defaultSize(width: 1400, height: 900)
        .defaultLaunchBehavior(.suppressed)

        Window("Free Up Space", id: WindowID.cleanup) {
            CleanupWindow(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("mac'd Settings", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Hosts the clean flow when it is started from a notification, since a menu bar panel
/// cannot be opened programmatically.
private struct CleanupWindow: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.cleanFlow.state == .idle {
                Text("Nothing in progress.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                CleanView(flow: model.cleanFlow) { dismissWindow(id: WindowID.cleanup) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
