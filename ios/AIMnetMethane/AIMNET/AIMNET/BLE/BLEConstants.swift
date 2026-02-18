import CoreBluetooth
import Foundation

enum BLEConstants {
    static let deviceNamePrefix = "AIMNet"
    static let scanServiceUUIDs: [CBUUID]? = nil
    static let telemetryCharUUID = CBUUID(string: "abcd1234-5678-1234-5678-abcdef123456")

    static let readFallbackIntervalSeconds: TimeInterval = 1
    static let signalTimeoutSeconds: TimeInterval = 6
    static let defaultTimedSampleDurationSeconds: Int = 30
}
