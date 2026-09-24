import SwiftUI

/// The dropdown panel: detailed metrics plus the two actions.
struct PanelView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.cleanFlow.state == .idle {
                overview
            } else {
                CleanView(flow: model.cleanFlow)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.metrics.setPanelOpen(true) }
        .onDisappear { model.metrics.setPanelOpen(false) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            let snapshot = model.metrics.snapshot

            MetricRow(
                symbol: "thermometer.medium",
                title: "CPU temperature",
                value: snapshot.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? "Unavailable"
            )
            MetricRow(
                symbol: "memorychip",
                title: "Memory used",
                value: snapshot.memory.map { "\(Formatters.bytes($0.usedBytes)) of \(Formatters.bytes($0.totalBytes))" } ?? "Unavailable",
                fraction: snapshot.memory?.fraction
            )
            MetricRow(
                symbol: "internaldrive",
                title: "Disk free",
                value: snapshot.disk.map { "\(Formatters.bytes($0.freeBytes)) of \(Formatters.bytes($0.totalBytes))" } ?? "Unavailable",
                fraction: snapshot.disk?.usedFraction
            )

            Divider()

            VStack(spacing: 8) {
                Button {
                    model.cleanFlow.startPreview()
                } label: {
                    Label("Free Up Space…", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    NSApp.activate()
                    openWindow(id: WindowID.analyze)
                } label: {
                    Label("Analyze Disk…", systemImage: "chart.bar.doc.horizontal").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openWindow(id: WindowID.settings)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
    }
}

private struct MetricRow: View {
    let symbol: String
    let title: String
    let value: String
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(fraction > 0.9 ? .red : .accentColor)
            }
        }
    }
}
