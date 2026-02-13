import CoreBluetooth
import Foundation
import SwiftUI
import UserNotifications

enum BLEConnectionState: String {
    case idle
    case scanning
    case connecting
    case preparing
    case streaming
    case signalTimeout
    case disconnected
    case failed
}

final class BLEManager: NSObject, ObservableObject {
    struct AdvertisedInfo {
        let serialHex: String
        let bootReason: UInt8?
        let versionMajor: UInt8?
        let versionMinor: UInt8?
    }

    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var isScanning = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var connectionState: BLEConnectionState = .idle
    @Published var statusMessage: String = "Bluetooth idle"
    @Published var connectionDurationSec: TimeInterval = 0
    @Published var connectionDurationsByDeviceId: [String: TimeInterval] = [:]

    @Published var methaneRawData: [Double] = []
    @Published var methanePPMData: [Double] = []
    @Published var methaneTimestamps: [Date] = []

    @Published var temperatureData: [Double] = []
    @Published var temperatureTimestamps: [Date] = []
    @Published var humidityData: [Double] = []
    @Published var humidityTimestamps: [Date] = []

    @Published var batteryLevel: Int?
    @Published var deviceSerial: String?
    @Published var firmwareRevision: String?
    @Published var advertisementSerials: [UUID: String] = [:]
    @Published var peripheralSerials: [UUID: String] = [:]
    @Published var advertisedInfoByPeripheral: [UUID: AdvertisedInfo] = [:]
    @Published var disSerialsByPeripheral: [UUID: String] = [:]

    @Published var latestReading: MethaneReading?
    @Published var liveReadings: [MethaneReading] = []

    @Published var isPreparingBaseline = false
    @Published var preparationSecondsLeft: Int = 0
    @Published var preparationTotalSeconds: Int = 0

    @Published var isSampling = false
    @Published var sampleSecondsLeft = 0
    @Published var sampleDurationSeconds = BLEConstants.defaultTimedSampleDurationSeconds
    @Published var timedSampleReadings: [MethaneReading] = []
    @Published var lastTimedSample: MethaneTimedSample?

    private let sessionStore: SessionStore
    private let calibrationProfile: MethaneCalibrationProfile

    private var centralManager: CBCentralManager!

    private var methaneCharacteristic: CBCharacteristic?
    private var temperatureCharacteristic: CBCharacteristic?
    private var humidityCharacteristic: CBCharacteristic?
    private var batteryLevelCharacteristic: CBCharacteristic?

    private var preparationTimer: Timer?
    private var preparationCountdownTimer: Timer?
    private var methaneReadFallbackTimer: Timer?
    private var temperatureReadFallbackTimer: Timer?
    private var humidityReadFallbackTimer: Timer?
    private var batteryReadFallbackTimer: Timer?
    private var signalWatchdogTimer: Timer?
    private var connectionDurationTimer: Timer?
    private var connectionStartDate: Date?
    private var timedSampleTimer: Timer?
    private var timedSampleStartedAt: Date?

    private var lastMethaneUpdateAt: Date?
    private var isPreparationComplete = false
    private var hasReadBatteryLevelThisConnection = false
    private var lowBatteryNotifiedDeviceIds: Set<String> = []

    private var activeDeviceIdByPeripheral: [UUID: String] = [:]
    private var connectionStartDatesByDeviceId: [String: Date] = [:]
    private var connectionTimersByDeviceId: [String: Timer] = [:]
    private var cumulativeDurationsByDeviceId: [String: TimeInterval] = [:]

    init(
        sessionStore: SessionStore,
        calibrationProfile: MethaneCalibrationProfile = .defaultLinear
    ) {
        self.sessionStore = sessionStore
        self.calibrationProfile = calibrationProfile
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        invalidateAllTimers()
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            transition(to: .idle, message: "Bluetooth is not powered on.")
            return
        }
        if isScanning { return }

        discoveredPeripherals.removeAll()
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.sensorServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        transition(to: .scanning, message: "Scanning for methane sensors...")
    }

    func stopScanning() {
        isScanning = false
        centralManager.stopScan()
        if connectionState == .scanning {
            transition(to: .idle, message: "Scan stopped.")
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        transition(to: .connecting, message: "Connecting to \(peripheral.name ?? "sensor")...")
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            transition(to: .disconnected, message: "No connected device.")
            return
        }
        transition(to: .disconnected, message: "Disconnecting...")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func clearLiveTelemetry() {
        methaneRawData.removeAll()
        methanePPMData.removeAll()
        methaneTimestamps.removeAll()
        temperatureData.removeAll()
        temperatureTimestamps.removeAll()
        humidityData.removeAll()
        humidityTimestamps.removeAll()
        liveReadings.removeAll()
        latestReading = nil
        lastMethaneUpdateAt = nil
    }

    func startTimedSample(durationSec: Int = BLEConstants.defaultTimedSampleDurationSeconds) {
        guard connectedPeripheral != nil else {
            statusMessage = "Connect to a device before starting a timed sample."
            return
        }
        guard !isPreparingBaseline else {
            statusMessage = "Wait for warmup to finish before sampling."
            return
        }

        timedSampleTimer?.invalidate()
        isSampling = true
        sampleDurationSeconds = max(1, durationSec)
        sampleSecondsLeft = sampleDurationSeconds
        timedSampleReadings.removeAll()
        lastTimedSample = nil
        timedSampleStartedAt = Date()

        timedSampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sampleSecondsLeft = max(0, self.sampleSecondsLeft - 1)
            if self.sampleSecondsLeft == 0 {
                self.stopTimedSample()
            }
        }
    }

    func stopTimedSample() {
        guard isSampling else { return }
        timedSampleTimer?.invalidate()
        timedSampleTimer = nil
        isSampling = false

        let start = timedSampleStartedAt ?? Date()
        let end = Date()
        lastTimedSample = MethaneTimedSample(
            startedAt: start,
            endedAt: end,
            targetDurationSec: sampleDurationSeconds,
            readings: timedSampleReadings
        )
    }

    func cancelTimedSample() {
        timedSampleTimer?.invalidate()
        timedSampleTimer = nil
        isSampling = false
        sampleSecondsLeft = 0
        timedSampleReadings.removeAll()
    }

    private func transition(to state: BLEConnectionState, message: String) {
        connectionState = state
        statusMessage = message
    }

    private func beginPreparation(for peripheral: CBPeripheral) {
        isPreparationComplete = false
        preparationTimer?.invalidate()
        preparationCountdownTimer?.invalidate()

        preparationTotalSeconds = Int(BLEConstants.preparationDelaySeconds)
        preparationSecondsLeft = preparationTotalSeconds
        isPreparingBaseline = true
        transition(to: .preparing, message: "Sensor warmup in progress...")

        preparationCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.preparationSecondsLeft = max(0, self.preparationSecondsLeft - 1)
            if self.preparationSecondsLeft == 0 {
                timer.invalidate()
                self.preparationCountdownTimer = nil
                self.isPreparingBaseline = false
            }
        }

        preparationTimer = Timer.scheduledTimer(withTimeInterval: BLEConstants.preparationDelaySeconds, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let connected = peripheral else { return }
            self.isPreparationComplete = true
            self.isPreparingBaseline = false
            self.transition(to: .preparing, message: "Warmup completed. Waiting for methane stream...")
            self.enableStreamingIfReady(connected)
        }
    }

    private func enableStreamingIfReady(_ peripheral: CBPeripheral) {
        guard isPreparationComplete else { return }

        if let methaneChar = methaneCharacteristic {
            configureStreamingCharacteristic(
                methaneChar,
                on: peripheral,
                kind: .methane
            )
        }
        if let temperatureChar = temperatureCharacteristic {
            configureStreamingCharacteristic(
                temperatureChar,
                on: peripheral,
                kind: .temperature
            )
        }
        if let humidityChar = humidityCharacteristic {
            configureStreamingCharacteristic(
                humidityChar,
                on: peripheral,
                kind: .humidity
            )
        }
        if let batteryChar = batteryLevelCharacteristic {
            if batteryChar.properties.contains(.notify) || batteryChar.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: batteryChar)
            }
            if batteryChar.properties.contains(.read) {
                peripheral.readValue(for: batteryChar)
            }
            scheduleBatteryReadFallback(for: peripheral)
        }
    }

    private enum StreamKind {
        case methane
        case temperature
        case humidity
    }

    private func configureStreamingCharacteristic(
        _ characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        kind: StreamKind
    ) {
        let canNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
        let canRead = characteristic.properties.contains(.read)

        if canNotify {
            peripheral.setNotifyValue(true, for: characteristic)
            stopReadFallback(for: kind)
        } else if canRead {
            startReadFallback(for: kind, peripheral: peripheral, characteristic: characteristic)
        }

        if canRead {
            peripheral.readValue(for: characteristic)
        }
    }

    private func startReadFallback(
        for kind: StreamKind,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        let timer = Timer.scheduledTimer(withTimeInterval: BLEConstants.readFallbackIntervalSeconds, repeats: true) { _ in
            peripheral.readValue(for: characteristic)
        }

        switch kind {
        case .methane:
            methaneReadFallbackTimer?.invalidate()
            methaneReadFallbackTimer = timer
        case .temperature:
            temperatureReadFallbackTimer?.invalidate()
            temperatureReadFallbackTimer = timer
        case .humidity:
            humidityReadFallbackTimer?.invalidate()
            humidityReadFallbackTimer = timer
        }
    }

    private func stopReadFallback(for kind: StreamKind) {
        switch kind {
        case .methane:
            methaneReadFallbackTimer?.invalidate()
            methaneReadFallbackTimer = nil
        case .temperature:
            temperatureReadFallbackTimer?.invalidate()
            temperatureReadFallbackTimer = nil
        case .humidity:
            humidityReadFallbackTimer?.invalidate()
            humidityReadFallbackTimer = nil
        }
    }

    private func scheduleBatteryReadFallback(for peripheral: CBPeripheral) {
        batteryReadFallbackTimer?.invalidate()
        batteryReadFallbackTimer = Timer.scheduledTimer(withTimeInterval: BLEConstants.batteryReadDelaySeconds, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let connected = peripheral, let batteryChar = self.batteryLevelCharacteristic else { return }
            guard batteryChar.properties.contains(.read), !self.hasReadBatteryLevelThisConnection else { return }
            connected.readValue(for: batteryChar)
        }
    }

    private func resolveDeviceId(for peripheral: CBPeripheral) -> String? {
        let id = peripheral.identifier
        if let dis = disSerialsByPeripheral[id], !dis.isEmpty { return dis }
        if let adv = peripheralSerials[id], !adv.isEmpty { return adv }
        if let adv = advertisementSerials[id], !adv.isEmpty { return adv }
        return nil
    }

    private func isDeviceCurrentlyConnected(_ deviceId: String) -> Bool {
        guard let connected = connectedPeripheral else { return false }
        return activeDeviceIdByPeripheral[connected.identifier] == deviceId
    }

    private func beginTimerTracking(forDeviceId deviceId: String) {
        connectionStartDatesByDeviceId[deviceId] = Date()
        connectionTimersByDeviceId[deviceId]?.invalidate()
        connectionTimersByDeviceId[deviceId] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self,
                  let startedAt = self.connectionStartDatesByDeviceId[deviceId],
                  self.isDeviceCurrentlyConnected(deviceId) else { return }
            let base = self.cumulativeDurationsByDeviceId[deviceId] ?? 0
            let elapsed = base + Date().timeIntervalSince(startedAt)
            self.connectionDurationsByDeviceId[deviceId] = elapsed
            self.connectionDurationSec = elapsed
        }
    }

    private func startConnectionDurationTimer() {
        connectionDurationTimer?.invalidate()
        connectionStartDate = Date()
        connectionDurationSec = 0
        connectionDurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.connectionStartDate else { return }
            self.connectionDurationSec = Date().timeIntervalSince(start)
        }
    }

    private func startSignalWatchdog() {
        signalWatchdogTimer?.invalidate()
        signalWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.connectedPeripheral != nil, self.isPreparationComplete else { return }

            guard let lastUpdate = self.lastMethaneUpdateAt else { return }
            let stale = Date().timeIntervalSince(lastUpdate) > BLEConstants.signalTimeoutSeconds
            if stale {
                if self.connectionState != .signalTimeout {
                    self.transition(to: .signalTimeout, message: "Methane signal timeout. Attempting recovery...")
                }
                if let peripheral = self.connectedPeripheral,
                   let methaneChar = self.methaneCharacteristic,
                   methaneChar.properties.contains(.read) {
                    peripheral.readValue(for: methaneChar)
                }
            } else if self.connectionState == .signalTimeout {
                self.transition(to: .streaming, message: "Methane stream restored.")
            }
        }
    }

    private func maybeStoreReading(_ reading: MethaneReading) {
        Task { @MainActor in
            sessionStore.append(reading: reading)
        }
    }

    private func startSessionIfNeeded(for peripheral: CBPeripheral) {
        Task { @MainActor in
            if sessionStore.activeSession == nil {
                sessionStore.startSession(
                    deviceId: peripheral.identifier.uuidString,
                    deviceName: peripheral.name ?? "Methane Sensor"
                )
            } else {
                sessionStore.updateActiveSessionDevice(
                    deviceId: peripheral.identifier.uuidString,
                    deviceName: peripheral.name ?? "Methane Sensor"
                )
            }
        }
    }

    private func appendCapped<T>(_ value: T, into array: inout [T], cap: Int) {
        array.append(value)
        if array.count > cap {
            array.removeFirst(array.count - cap)
        }
    }

    private func publishMethane(rawValue: Double, at timestamp: Date) {
        let ppm = calibrationProfile.ppm(fromRaw: rawValue)
        appendCapped(rawValue, into: &methaneRawData, cap: 7200)
        appendCapped(ppm, into: &methanePPMData, cap: 7200)
        appendCapped(timestamp, into: &methaneTimestamps, cap: 7200)
        lastMethaneUpdateAt = timestamp

        let reading = MethaneReading(
            timestamp: timestamp,
            rawValue: rawValue,
            ppm: ppm,
            temperatureC: temperatureData.last,
            humidityRH: humidityData.last,
            batteryPercent: batteryLevel
        )
        appendCapped(reading, into: &liveReadings, cap: 300)
        if isSampling {
            appendCapped(reading, into: &timedSampleReadings, cap: 6000)
        }
        latestReading = reading
        maybeStoreReading(reading)

        if connectionState != .streaming {
            transition(to: .streaming, message: "Receiving methane telemetry.")
        }
    }

    private func resetCharacteristicReferences() {
        methaneCharacteristic = nil
        temperatureCharacteristic = nil
        humidityCharacteristic = nil
        batteryLevelCharacteristic = nil
    }

    private func invalidateAllTimers() {
        preparationTimer?.invalidate()
        preparationCountdownTimer?.invalidate()
        methaneReadFallbackTimer?.invalidate()
        temperatureReadFallbackTimer?.invalidate()
        humidityReadFallbackTimer?.invalidate()
        batteryReadFallbackTimer?.invalidate()
        signalWatchdogTimer?.invalidate()
        connectionDurationTimer?.invalidate()
        timedSampleTimer?.invalidate()

        for timer in connectionTimersByDeviceId.values {
            timer.invalidate()
        }

        preparationTimer = nil
        preparationCountdownTimer = nil
        methaneReadFallbackTimer = nil
        temperatureReadFallbackTimer = nil
        humidityReadFallbackTimer = nil
        batteryReadFallbackTimer = nil
        signalWatchdogTimer = nil
        connectionDurationTimer = nil
        timedSampleTimer = nil
        connectionTimersByDeviceId.removeAll()
    }

    private func parseMethaneRaw(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        let raw = (UInt16(data[0]) << 8) | UInt16(data[1])
        return Double(raw)
    }

    private func parseTemperature(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        let u16 = (UInt16(data[1]) << 8) | UInt16(data[0])
        let s16 = Int16(bitPattern: u16)
        return Double(s16) / 100.0
    }

    private func parseHumidity(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        let u16 = (UInt16(data[1]) << 8) | UInt16(data[0])
        return Double(u16) / 100.0
    }

    private func parseBatteryLevel(_ data: Data) -> Int? {
        guard let first = data.first else { return nil }
        return min(100, max(0, Int(first)))
    }

    private func maybeNotifyLowBattery(level: Int?, for peripheral: CBPeripheral) {
        guard let level, level <= BLEConstants.lowBatteryThresholdPercent else { return }
        let deviceId = resolveDeviceId(for: peripheral) ?? peripheral.identifier.uuidString
        if lowBatteryNotifiedDeviceIds.contains(deviceId) { return }
        lowBatteryNotifiedDeviceIds.insert(deviceId)

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleLowBatteryNotification(level: level, deviceId: deviceId)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        self.scheduleLowBatteryNotification(level: level, deviceId: deviceId)
                    }
                }
            default:
                break
            }
        }
    }

    private func scheduleLowBatteryNotification(level: Int, deviceId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Low Battery"
        content.body = "Device \(deviceId) battery is at \(level)%. Please replace or recharge it."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "low_battery_\(deviceId)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state != .poweredOn {
            stopScanning()
            transition(to: .idle, message: "Bluetooth unavailable.")
            isPreparingBaseline = false
            cancelTimedSample()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }

        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 2 {
            let payload = manufacturerData.dropFirst(2)
            if payload.count >= 8 {
                let serialHex = payload.prefix(8).map { String(format: "%02X", $0) }.joined()
                var bootReason: UInt8?
                var versionMajor: UInt8?
                var versionMinor: UInt8?

                if payload.count >= 9 {
                    bootReason = payload[payload.index(payload.startIndex, offsetBy: 8)]
                }
                if payload.count >= 11 {
                    versionMajor = payload[payload.index(payload.startIndex, offsetBy: 9)]
                    versionMinor = payload[payload.index(payload.startIndex, offsetBy: 10)]
                }

                advertisementSerials[peripheral.identifier] = serialHex
                peripheralSerials[peripheral.identifier] = serialHex
                advertisedInfoByPeripheral[peripheral.identifier] = AdvertisedInfo(
                    serialHex: serialHex,
                    bootReason: bootReason,
                    versionMajor: versionMajor,
                    versionMinor: versionMinor
                )
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopScanning()
        connectedPeripheral = peripheral
        peripheral.delegate = self

        clearLiveTelemetry()
        resetCharacteristicReferences()
        isPreparationComplete = false
        batteryLevel = nil
        firmwareRevision = nil
        deviceSerial = nil
        hasReadBatteryLevelThisConnection = false

        startConnectionDurationTimer()
        startSignalWatchdog()
        startSessionIfNeeded(for: peripheral)
        beginPreparation(for: peripheral)

        if let deviceId = resolveDeviceId(for: peripheral) {
            activeDeviceIdByPeripheral[peripheral.identifier] = deviceId
            beginTimerTracking(forDeviceId: deviceId)
        }

        peripheral.discoverServices([
            BLEConstants.sensorServiceUUID,
            BLEConstants.deviceInfoServiceUUID,
            BLEConstants.batteryServiceUUID
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        transition(to: .failed, message: "Failed to connect: \(error?.localizedDescription ?? "unknown error").")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
        }
        discoveredPeripherals.removeAll { $0.identifier == peripheral.identifier }
        isPreparationComplete = false
        invalidateAllTimers()
        resetCharacteristicReferences()
        connectionDurationSec = 0
        isPreparingBaseline = false
        preparationSecondsLeft = 0
        preparationTotalSeconds = 0
        cancelTimedSample()

        let uuid = peripheral.identifier
        if let deviceId = activeDeviceIdByPeripheral[uuid] ?? resolveDeviceId(for: peripheral) {
            if let startedAt = connectionStartDatesByDeviceId[deviceId] {
                let base = cumulativeDurationsByDeviceId[deviceId] ?? 0
                let total = base + Date().timeIntervalSince(startedAt)
                cumulativeDurationsByDeviceId[deviceId] = total
                connectionDurationsByDeviceId[deviceId] = total
            }
            connectionTimersByDeviceId[deviceId]?.invalidate()
            connectionTimersByDeviceId.removeValue(forKey: deviceId)
            connectionStartDatesByDeviceId.removeValue(forKey: deviceId)
        }
        activeDeviceIdByPeripheral.removeValue(forKey: uuid)

        if let error = error {
            transition(to: .disconnected, message: "Disconnected: \(error.localizedDescription)")
        } else {
            transition(to: .disconnected, message: "Device disconnected.")
        }

        Task { @MainActor in
            _ = sessionStore.endSession()
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case BLEConstants.sensorServiceUUID:
                peripheral.discoverCharacteristics(
                    [
                        BLEConstants.methaneCharUUID,
                        BLEConstants.temperatureCharUUID,
                        BLEConstants.humidityCharUUID
                    ],
                    for: service
                )
            case BLEConstants.deviceInfoServiceUUID:
                peripheral.discoverCharacteristics(
                    [
                        BLEConstants.serialNumberCharUUID,
                        BLEConstants.firmwareRevisionCharUUID
                    ],
                    for: service
                )
            case BLEConstants.batteryServiceUUID:
                peripheral.discoverCharacteristics([BLEConstants.batteryLevelCharUUID], for: service)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLEConstants.methaneCharUUID:
                methaneCharacteristic = characteristic
            case BLEConstants.temperatureCharUUID:
                temperatureCharacteristic = characteristic
            case BLEConstants.humidityCharUUID:
                humidityCharacteristic = characteristic
            case BLEConstants.batteryLevelCharUUID:
                batteryLevelCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                scheduleBatteryReadFallback(for: peripheral)
            case BLEConstants.serialNumberCharUUID:
                peripheral.readValue(for: characteristic)
            case BLEConstants.firmwareRevisionCharUUID:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }

        if isPreparationComplete {
            enableStreamingIfReady(peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if error != nil { return }
        guard isPreparationComplete else { return }

        if characteristic.uuid == BLEConstants.methaneCharUUID {
            if characteristic.isNotifying {
                stopReadFallback(for: .methane)
            } else if characteristic.properties.contains(.read) {
                startReadFallback(for: .methane, peripheral: peripheral, characteristic: characteristic)
            }
        } else if characteristic.uuid == BLEConstants.temperatureCharUUID {
            if characteristic.isNotifying {
                stopReadFallback(for: .temperature)
            } else if characteristic.properties.contains(.read) {
                startReadFallback(for: .temperature, peripheral: peripheral, characteristic: characteristic)
            }
        } else if characteristic.uuid == BLEConstants.humidityCharUUID {
            if characteristic.isNotifying {
                stopReadFallback(for: .humidity)
            } else if characteristic.properties.contains(.read) {
                startReadFallback(for: .humidity, peripheral: peripheral, characteristic: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == BLEConstants.serialNumberCharUUID {
            let serial = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            deviceSerial = serial.isEmpty ? nil : serial
            if let serial = deviceSerial, !serial.isEmpty {
                disSerialsByPeripheral[peripheral.identifier] = serial
                if activeDeviceIdByPeripheral[peripheral.identifier] == nil {
                    activeDeviceIdByPeripheral[peripheral.identifier] = serial
                    beginTimerTracking(forDeviceId: serial)
                } else {
                    activeDeviceIdByPeripheral[peripheral.identifier] = serial
                }
                Task { @MainActor in
                    sessionStore.updateActiveSessionDevice(
                        deviceId: serial,
                        deviceName: peripheral.name ?? "Methane Sensor"
                    )
                }
            }
            return
        }
        if characteristic.uuid == BLEConstants.firmwareRevisionCharUUID {
            firmwareRevision = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if characteristic.uuid == BLEConstants.batteryLevelCharUUID {
            let level = parseBatteryLevel(data)
            batteryLevel = level
            hasReadBatteryLevelThisConnection = true
            batteryReadFallbackTimer?.invalidate()
            batteryReadFallbackTimer = nil
            maybeNotifyLowBattery(level: level, for: peripheral)
            return
        }

        switch characteristic.uuid {
        case BLEConstants.methaneCharUUID:
            let raw = parseMethaneRaw(data)
            publishMethane(rawValue: raw, at: Date())
        case BLEConstants.temperatureCharUUID:
            appendCapped(parseTemperature(data), into: &temperatureData, cap: 7200)
            appendCapped(Date(), into: &temperatureTimestamps, cap: 7200)
        case BLEConstants.humidityCharUUID:
            appendCapped(parseHumidity(data), into: &humidityData, cap: 7200)
            appendCapped(Date(), into: &humidityTimestamps, cap: 7200)
        default:
            break
        }
    }
}
