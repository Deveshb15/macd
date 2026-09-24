import Foundation
import Observation

/// Polls the metric sources on a cadence: every 5 s normally, every 1 s while the panel is open.
@Observable
final class MetricsMonitor {
    static let idleInterval: Duration = .seconds(5)
    static let panelInterval: Duration = .seconds(1)

    private(set) var snapshot: MetricsSnapshot = .empty
    private(set) var isPanelOpen = false

    /// Called after every refresh, for observers such as the low-space notifier.
    @ObservationIgnored var onRefresh: ((MetricsSnapshot) -> Void)?

    @ObservationIgnored private let temperature: TemperatureSource?
    @ObservationIgnored private let memory: MemorySource
    @ObservationIgnored private let disk: DiskSource
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(temperature: TemperatureSource?, memory: MemorySource, disk: DiskSource) {
        self.temperature = temperature
        self.memory = memory
        self.disk = disk
    }

    var interval: Duration {
        isPanelOpen ? Self.panelInterval : Self.idleInterval
    }

    func start() {
        guard loop == nil else { return }
        startLoop()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen else { return }
        isPanelOpen = open
        guard loop != nil else { return }
        // Restart so the new cadence applies immediately.
        loop?.cancel()
        startLoop()
    }

    func refresh() {
        snapshot = MetricsSnapshot(
            cpuTemperature: TemperatureValidator.validated(temperature?.cpuTemperature()),
            memory: memory.memoryUsage(),
            disk: disk.diskUsage()
        )
        onRefresh?(snapshot)
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: self.interval)
            }
        }
    }
}
