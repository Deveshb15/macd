import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    enum Key {
        static let showTemperature = "showTemperature"
        static let showMemory = "showMemory"
        static let showDisk = "showDisk"
        static let lowSpaceAlertsEnabled = "lowSpaceAlertsEnabled"
        static let lowSpaceThresholdGB = "lowSpaceThresholdGB"
    }

    static let defaultThresholdGB = 20

    @ObservationIgnored private let defaults: UserDefaults

    var showTemperature: Bool { didSet { defaults.set(showTemperature, forKey: Key.showTemperature) } }
    var showMemory: Bool { didSet { defaults.set(showMemory, forKey: Key.showMemory) } }
    var showDisk: Bool { didSet { defaults.set(showDisk, forKey: Key.showDisk) } }
    var lowSpaceAlertsEnabled: Bool { didSet { defaults.set(lowSpaceAlertsEnabled, forKey: Key.lowSpaceAlertsEnabled) } }
    var lowSpaceThresholdGB: Int { didSet { defaults.set(lowSpaceThresholdGB, forKey: Key.lowSpaceThresholdGB) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showTemperature: true,
            Key.showMemory: true,
            Key.showDisk: true,
            Key.lowSpaceAlertsEnabled: true,
            Key.lowSpaceThresholdGB: Self.defaultThresholdGB,
        ])
        showTemperature = defaults.bool(forKey: Key.showTemperature)
        showMemory = defaults.bool(forKey: Key.showMemory)
        showDisk = defaults.bool(forKey: Key.showDisk)
        lowSpaceAlertsEnabled = defaults.bool(forKey: Key.lowSpaceAlertsEnabled)
        lowSpaceThresholdGB = defaults.integer(forKey: Key.lowSpaceThresholdGB)
    }

    /// The low-space threshold in bytes, or `nil` when alerts are off or the threshold is not positive.
    var lowSpaceThresholdBytes: Int64? {
        guard lowSpaceAlertsEnabled, lowSpaceThresholdGB > 0 else { return nil }
        return Int64(lowSpaceThresholdGB) * 1_000_000_000
    }
}

/// Launch-at-login state lives with the system, not in `UserDefaults`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
