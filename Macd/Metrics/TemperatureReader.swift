import Foundation
import IOKit

/// Reads Apple Silicon CPU die temperature through the IOHID sensor event system,
/// the same private interface the open-source Stats app uses. Every failure maps to `nil`.
final class TemperatureReader: TemperatureSource {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias ClientSetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias EventGetFloatValue = @convention(c) (OpaquePointer, Int32) -> Double

    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16 // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    private let copyServices: ClientCopyServices
    private let copyProperty: ServiceCopyProperty
    private let copyEvent: ServiceCopyEvent
    private let getFloatValue: EventGetFloatValue
    private let client: OpaquePointer

    /// Returns `nil` when the private symbols are unavailable on this macOS version.
    init?() {
        guard
            let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
            let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let matchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let servicesSymbol = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let propertySymbol = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let eventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let floatSymbol = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        let create = unsafeBitCast(createSymbol, to: ClientCreate.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: ClientSetMatching.self)
        copyServices = unsafeBitCast(servicesSymbol, to: ClientCopyServices.self)
        copyProperty = unsafeBitCast(propertySymbol, to: ServiceCopyProperty.self)
        copyEvent = unsafeBitCast(eventSymbol, to: ServiceCopyEvent.self)
        getFloatValue = unsafeBitCast(floatSymbol, to: EventGetFloatValue.self)

        guard let client = create(kCFAllocatorDefault) else { return nil }
        self.client = client

        // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
    }

    deinit {
        Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(client)).release()
    }

    func cpuTemperature() -> Double? {
        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }

        var readings: [(name: String, celsius: Double)] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = OpaquePointer(raw)
            guard
                let nameRef = copyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                let name = nameRef as? String,
                let event = copyEvent(service, Self.temperatureEventType, 0, 0)
            else { continue }
            let celsius = getFloatValue(event, Self.temperatureField)
            Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(event)).release()
            readings.append((name, celsius))
        }

        let cpu = readings
            .filter { Self.isCPUSensor($0.name) }
            .map(\.celsius)
            .filter(TemperatureValidator.isPlausible)
        guard !cpu.isEmpty else { return nil }
        return cpu.reduce(0, +) / Double(cpu.count)
    }

    /// CPU die sensors are named "PMU tdie…" on most Apple Silicon chips and
    /// "pACC/eACC MTR Temp Sensor…" on some. Calibration sensors ("tcal") are excluded.
    static func isCPUSensor(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !lower.contains("tcal") else { return false }
        return lower.contains("tdie") || lower.contains("acc mtr temp")
    }
}

enum TemperatureValidator {
    /// Rejects the zeros and garbage values some sensors report.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius >= 1 && celsius <= 150
    }

    static func validated(_ celsius: Double?) -> Double? {
        guard let celsius, isPlausible(celsius) else { return nil }
        return celsius
    }
}
