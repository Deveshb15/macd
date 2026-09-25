import SwiftUI

/// The dropdown panel: three live ring gauges, the storage bar, and one glowing action.
struct PanelView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Group {
                if model.cleanFlow.state == .idle {
                    overview.transition(.blurReplace)
                } else {
                    CleanView(flow: model.cleanFlow).transition(.blurReplace)
                }
            }
            .animation(Theme.spring, value: model.cleanFlow.state == .idle)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.metrics.setPanelOpen(true) }
        .onDisappear { model.metrics.setPanelOpen(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("mac'd")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                GlassIconButton(systemImage: "gearshape", help: "Settings") { open(WindowID.settings) }
                GlassIconButton(systemImage: "power", help: "Quit mac'd") { NSApplication.shared.terminate(nil) }
            }
            .macdGlassGroup(spacing: 6)
        }
    }

    private var overview: some View {
        let snapshot = model.metrics.snapshot
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 4) {
                RingGauge(
                    fraction: snapshot.cpuTemperature.map { $0 / 100 },
                    value: Formatters.temperature(snapshot.cpuTemperature),
                    label: "CPU",
                    caption: Theme.temperatureWord(snapshot.cpuTemperature),
                    colors: Theme.temperatureGradient(snapshot.cpuTemperature)
                )
                RingGauge(
                    fraction: snapshot.memory?.fraction,
                    value: Formatters.percent(snapshot.memory?.fraction),
                    label: "MEMORY",
                    caption: snapshot.memory.map { "\(Formatters.bytes($0.usedBytes)) of \(Formatters.bytes($0.totalBytes))" } ?? "unavailable",
                    colors: Theme.memoryGradient
                )
                RingGauge(
                    fraction: snapshot.disk?.usedFraction,
                    value: snapshot.disk.map { Formatters.bytes($0.freeBytes) } ?? "—",
                    label: "FREE",
                    caption: snapshot.disk.map { "of \(Formatters.bytes($0.totalBytes))" } ?? "unavailable",
                    colors: Theme.diskGradient
                )
            }

            if let disk = snapshot.disk {
                StorageBar(disk: disk, segments: StorageBreakdown.segments(disk: disk, tree: model.diskMap.tree))
            }

            VStack(spacing: 8) {
                Button {
                    model.cleanFlow.startPreview()
                } label: {
                    Label(freeUpTitle, systemImage: "sparkles")
                        .symbolEffect(.bounce, value: model.cleanFlow.lastPreviewTotal)
                }
                .buttonStyle(PrimaryGlassButtonStyle())

                Button {
                    open(WindowID.analyze)
                } label: {
                    Label("Open Disk Map", systemImage: "square.grid.3x3.topleft.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryGlassButtonStyle())
            }
        }
    }

    private var freeUpTitle: String {
        if let total = model.cleanFlow.lastPreviewTotal, total > 0 {
            return "Free Up \(Formatters.bytes(total))"
        }
        return "Free Up Space"
    }

    private var status: (text: String, color: Color) {
        let snapshot = model.metrics.snapshot
        if let free = snapshot.disk?.freeBytes, let threshold = model.settings.lowSpaceThresholdBytes, free < threshold {
            return ("Low on space", .orange)
        }
        if let temperature = snapshot.cpuTemperature, temperature >= 80 {
            return ("Running hot", .red)
        }
        return ("All good", .green)
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}
