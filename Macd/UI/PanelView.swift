import SwiftUI

/// The dropdown panel: three readings, then actions laid out like a native menu.
struct PanelView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.cleanFlow.state == .idle {
                readings
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                Divider().padding(.horizontal, 10)
                VStack(spacing: 0) {
                    MenuRow(title: "Free Up Space…", trailing: estimate) { model.cleanFlow.startPreview() }
                    MenuRow(title: "Disk Map…") { open(WindowID.analyze) }
                }
                .padding(5)
                Divider().padding(.horizontal, 10)
                VStack(spacing: 0) {
                    MenuRow(title: "Settings…") { open(WindowID.settings) }
                    MenuRow(title: "Quit mac'd", trailing: "⌘Q") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
                .padding(5)
            } else {
                CleanView(flow: model.cleanFlow)
                    .padding(14)
            }
        }
        .frame(width: 280)
        .onAppear { model.metrics.setPanelOpen(true) }
        .onDisappear { model.metrics.setPanelOpen(false) }
    }

    private var readings: some View {
        let snapshot = model.metrics.snapshot
        let diskSignal = Signal.disk(free: snapshot.disk?.freeBytes, threshold: model.settings.lowSpaceThresholdBytes)
        return VStack(alignment: .leading, spacing: 12) {
            Reading(
                label: "CPU",
                value: snapshot.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? "Unavailable",
                signal: .temperature(snapshot.cpuTemperature)
            )
            Reading(
                label: "Memory",
                value: snapshot.memory.map { Formatters.memory($0.usedBytes) } ?? "Unavailable",
                detail: snapshot.memory.map { "of \(Formatters.memory($0.totalBytes))" },
                fraction: snapshot.memory?.fraction,
                signal: .memory(snapshot.memory?.fraction)
            )
            Reading(
                label: "Disk",
                value: snapshot.disk.map { "\(Formatters.bytes($0.freeBytes)) free" } ?? "Unavailable",
                detail: snapshot.disk.map { "of \(Formatters.bytes($0.totalBytes))" },
                fraction: snapshot.disk?.usedFraction,
                signal: diskSignal
            )
        }
    }

    private var estimate: String? {
        guard let total = model.cleanFlow.lastPreviewTotal, total > 0 else { return nil }
        return Formatters.bytes(total)
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}

private struct Reading: View {
    let label: String
    let value: String
    var detail: String?
    var fraction: Double?
    var signal: Signal = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .fontWeight(.medium)
                    .foregroundStyle(signal.color)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if let fraction {
                Meter(fraction: fraction, signal: signal)
            }
        }
    }
}
