import AppKit
import Foundation
import Observation

/// Owns the app's long-lived objects and wires them together.
@Observable
final class AppModel {
    enum WindowRequest: Equatable {
        case cleanup
    }

    let settings: AppSettings
    let metrics: MetricsMonitor
    let cleanFlow: CleanFlow
    let diskMap: DiskMapModel
    let moleVersion: String?

    /// Set when something outside a view (a notification tap) needs a window opened.
    var windowRequest: WindowRequest?

    @ObservationIgnored let notifications = NotificationCenterBridge()
    @ObservationIgnored private var lowSpace: LowSpaceNotifier!

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let disk = DiskReader()
        metrics = MetricsMonitor(temperature: TemperatureReader(), memory: MemoryReader(), disk: disk)
        let runner = MoleRunner.bundled()
        cleanFlow = CleanFlow(runner: runner, freeSpace: { disk.diskUsage()?.freeBytes })
        diskMap = DiskMapModel(cache: DiskScanCache(), changes: FSEventsChangeTracker())
        moleVersion = runner.flatMap { runner in
            try? String(contentsOf: runner.scriptURL.deletingLastPathComponent().appendingPathComponent("VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        lowSpace = LowSpaceNotifier(
            threshold: { [settings] in settings.lowSpaceThresholdBytes },
            post: { [notifications] free in notifications.postLowSpace(freeBytes: free) }
        )
        metrics.onRefresh = { [weak self] snapshot in
            self?.lowSpace.evaluate(freeBytes: snapshot.disk?.freeBytes)
        }
        notifications.onFreeUpSpace = { [weak self] in
            self?.freeUpSpaceFromNotification()
        }

        guard !Self.isRunningTests else { return }
        notifications.configure()
        metrics.start()
    }

    func freeUpSpaceFromNotification() {
        if !cleanFlow.isBusy, case .idle = cleanFlow.state {
            cleanFlow.startPreview()
        }
        windowRequest = .cleanup
    }

    func setLowSpaceAlerts(_ enabled: Bool) {
        settings.lowSpaceAlertsEnabled = enabled
        guard enabled else { return }
        Task { await notifications.requestAuthorization() }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
