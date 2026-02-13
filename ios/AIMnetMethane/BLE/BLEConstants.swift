import CoreBluetooth
import Foundation

enum BLEConstants {
    static let sensorServiceUUID = CBUUID(string: "0000181a-0000-1000-8000-00805f9b34fb")
    static let methaneCharUUID = CBUUID(string: "00002bd0-0000-1000-8000-00805f9b34fb")
    static let temperatureCharUUID = CBUUID(string: "00002a6e-0000-1000-8000-00805f9b34fb")
    static let humidityCharUUID = CBUUID(string: "00002a6f-0000-1000-8000-00805f9b34fb")

    static let deviceInfoServiceUUID = CBUUID(string: "180A")
    static let serialNumberCharUUID = CBUUID(string: "2A25")
    static let firmwareRevisionCharUUID = CBUUID(string: "2A26")

    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharUUID = CBUUID(string: "2A19")

    static let preparationDelaySeconds: TimeInterval = 20
    static let readFallbackIntervalSeconds: TimeInterval = 1
    static let signalTimeoutSeconds: TimeInterval = 6
    static let batteryReadDelaySeconds: TimeInterval = 10
    static let lowBatteryThresholdPercent: Int = 10
    static let defaultTimedSampleDurationSeconds: Int = 30
}
