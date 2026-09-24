import XCTest
@testable import Macd

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macd.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshInstallDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showTemperature)
        XCTAssertTrue(settings.showMemory)
        XCTAssertTrue(settings.showDisk)
        XCTAssertTrue(settings.lowSpaceAlertsEnabled)
        XCTAssertEqual(settings.lowSpaceThresholdGB, 20)
        XCTAssertEqual(settings.lowSpaceThresholdBytes, 20_000_000_000)
    }

    func testChangesPersistAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.showTemperature = false
        settings.lowSpaceThresholdGB = 35

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showTemperature)
        XCTAssertEqual(reloaded.lowSpaceThresholdGB, 35)
    }

    func testNonPositiveThresholdMeansOff() {
        let settings = AppSettings(defaults: defaults)
        settings.lowSpaceThresholdGB = 0
        XCTAssertNil(settings.lowSpaceThresholdBytes)
        settings.lowSpaceThresholdGB = -5
        XCTAssertNil(settings.lowSpaceThresholdBytes)
    }

    func testDisabledAlertsMeanNoThreshold() {
        let settings = AppSettings(defaults: defaults)
        settings.lowSpaceAlertsEnabled = false
        XCTAssertNil(settings.lowSpaceThresholdBytes)
    }
}
