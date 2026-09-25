import SwiftUI

enum MenuBarText {
    /// The menu bar string for the enabled metrics, or `nil` to show the icon alone.
    static func compose(_ snapshot: MetricsSnapshot, showTemperature: Bool, showMemory: Bool, showDisk: Bool) -> String? {
        var parts: [String] = []
        if showTemperature { parts.append(Formatters.temperature(snapshot.cpuTemperature)) }
        if showMemory { parts.append(Formatters.percent(snapshot.memory?.fraction)) }
        if showDisk { parts.append(Formatters.diskFree(snapshot.disk)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

/// The always-visible menu bar item. Because it is always alive, it also opens windows
/// requested from outside SwiftUI, such as a notification tap.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let text = MenuBarText.compose(
                model.metrics.snapshot,
                showTemperature: model.settings.showTemperature,
                showMemory: model.settings.showMemory,
                showDisk: model.settings.showDisk
            ) {
                HStack(spacing: 3) {
                    if (model.metrics.snapshot.cpuTemperature ?? 0) >= 80 {
                        Image(systemName: "flame.fill")
                    }
                    Text(text).monospacedDigit()
                }
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        .onChange(of: model.windowRequest) { _, request in
            guard request == .cleanup else { return }
            model.windowRequest = nil
            NSApp.activate()
            openWindow(id: WindowID.cleanup)
        }
    }
}

enum WindowID {
    static let analyze = "analyze"
    static let settings = "settings"
    static let cleanup = "cleanup"
}
