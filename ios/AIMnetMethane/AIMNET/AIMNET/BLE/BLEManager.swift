import Combine
import CoreBluetooth
import Foundation

enum BLEConnectionState: String {
    case idle
    case scanning
    case connecting
    case streaming
    case signalTimeout
    case disconnected
    case failed
}

enum SensorDeviceType: String {
    case unknown = "Unknown"
    case methane = "Methane"
    case h2s = "H2S"
}

final class BLEManager: NSObject, ObservableObject {
    struct AdvertisedInfo {
        let serialHex: String
        let bootReason: UInt8?
        let versionMajor: UInt8?
        let versionMinor: UInt8?
    }

    private struct MethanePayload {
        let deviceTime: Int
        let h2oSensor1: Double
        let h2oSensor2: Double
        let co2Sensor: Double
        let pressureRaw: Double
        let temperature1: Double
        let temperature2: Double
        let temperature3: Double
        let humidityRaw: Double
        let temperature4: Double
        let h2oSignal: Double
        let ch4Signal: Double
        let co2Signal: Double
    }

    private struct H2SPayload {
        let deviceTime: Int
        let primaryPPB: Double
        let secondaryPPB: Double
    }

    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var isScanning = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var connectionState: BLEConnectionState = .idle
    @Published var statusMessage: String = "Bluetooth idle"
    @Published var connectionDurationSec: TimeInterval = 0
    @Published var connectionDurationsByDeviceId: [String: TimeInterval] = [:]

    // Methane series
    @Published var methaneRawData: [Double] = []
    // Kept for existing timed-sample/session objects; now mirrors raw CH4 signal.
    @Published var methanePPMData: [Double] = []
    @Published var methaneTimestamps: [Date] = []

    @Published var waterData: [Double] = []
    @Published var waterSecondaryData: [Double] = []
    @Published var waterTimestamps: [Date] = []

    @Published var co2Data: [Double] = []
    @Published var co2Timestamps: [Date] = []

    @Published var pressureData: [Double] = []
    @Published var pressureTimestamps: [Date] = []
    @Published var pressureKPaData: [Double] = []

    @Published var temperatureData: [Double] = []
    @Published var temperature2Data: [Double] = []
    @Published var temperature3Data: [Double] = []
    @Published var temperature4Data: [Double] = []
    @Published var temperatureTimestamps: [Date] = []
    @Published var temperatureCData: [Double] = []
    @Published var temperature2CData: [Double] = []
    @Published var temperature3CData: [Double] = []
    @Published var temperature4CData: [Double] = []

    @Published var humidityData: [Double] = []
    @Published var humidityTimestamps: [Date] = []
    @Published var humidityRHData: [Double] = []

    @Published var h2oSignalData: [Double] = []
    @Published var co2SignalData: [Double] = []

    // H2S series
    @Published var h2sPrimaryData: [Double] = []
    @Published var h2sSecondaryData: [Double] = []
    @Published var h2sTimestamps: [Date] = []

    @Published var advertisementSerials: [UUID: String] = [:]
    @Published var peripheralSerials: [UUID: String] = [:]
    @Published var advertisedInfoByPeripheral: [UUID: AdvertisedInfo] = [:]

    @Published var detectedDeviceType: SensorDeviceType = .unknown
    @Published var latestDeviceTime: Int?
    @Published var latestH2OSensor1: Double?
    @Published var latestH2OSensor2: Double?
    @Published var latestCO2Sensor: Double?
    @Published var latestPressureRaw: Double?
    @Published var latestPressureKPa: Double?
    @Published var latestTemperature1: Double?
    @Published var latestTemperature2: Double?
    @Published var latestTemperature3: Double?
    @Published var latestTemperature4: Double?
    @Published var latestTemperature1C: Double?
    @Published var latestTemperature2C: Double?
    @Published var latestTemperature3C: Double?
    @Published var latestTemperature4C: Double?
    @Published var latestHumidityRaw: Double?
    @Published var latestHumidityRH: Double?
    @Published var latestH2OSignal: Double?
    @Published var latestCH4Signal: Double?
    @Published var latestCO2Signal: Double?
    @Published var latestH2SPrimary: Double?
    @Published var latestH2SSecondary: Double?
    @Published var latestPayloadDeviceName: String?
    @Published var latestRawPayload: String = ""
    @Published var latestRawFields: [String] = []

    @Published var latestReading: MethaneReading?
    @Published var liveReadings: [MethaneReading] = []

    @Published var isSampling = false
    @Published var sampleSecondsLeft = 0
    @Published var sampleDurationSeconds = BLEConstants.defaultTimedSampleDurationSeconds
    @Published var timedSampleReadings: [MethaneReading] = []
    @Published var lastTimedSample: MethaneTimedSample?

    private let sessionStore: SessionStore

    private var centralManager: CBCentralManager!
    private var telemetryCharacteristic: CBCharacteristic?

    private var telemetryReadFallbackTimer: Timer?
    private var signalWatchdogTimer: Timer?
    private var connectionDurationTimer: Timer?
    private var connectionStartDate: Date?
    private var timedSampleTimer: Timer?
    private var timedSampleStartedAt: Date?
    private var lastTelemetryUpdateAt: Date?

    private var activeDeviceIdByPeripheral: [UUID: String] = [:]
    private var connectionStartDatesByDeviceId: [String: Date] = [:]
    private var connectionTimersByDeviceId: [String: Timer] = [:]
    private var cumulativeDurationsByDeviceId: [String: TimeInterval] = [:]

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
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
            withServices: BLEConstants.scanServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        transition(to: .scanning, message: "Scanning for sensors...")
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

        waterData.removeAll()
        waterSecondaryData.removeAll()
        waterTimestamps.removeAll()

        co2Data.removeAll()
        co2Timestamps.removeAll()

        pressureData.removeAll()
        pressureTimestamps.removeAll()
        pressureKPaData.removeAll()

        temperatureData.removeAll()
        temperature2Data.removeAll()
        temperature3Data.removeAll()
        temperature4Data.removeAll()
        temperatureTimestamps.removeAll()
        temperatureCData.removeAll()
        temperature2CData.removeAll()
        temperature3CData.removeAll()
        temperature4CData.removeAll()

        humidityData.removeAll()
        humidityTimestamps.removeAll()
        humidityRHData.removeAll()

        h2oSignalData.removeAll()
        co2SignalData.removeAll()

        h2sPrimaryData.removeAll()
        h2sSecondaryData.removeAll()
        h2sTimestamps.removeAll()

        liveReadings.removeAll()
        latestReading = nil

        detectedDeviceType = .unknown
        latestDeviceTime = nil
        latestH2OSensor1 = nil
        latestH2OSensor2 = nil
        latestCO2Sensor = nil
        latestPressureRaw = nil
        latestPressureKPa = nil
        latestTemperature1 = nil
        latestTemperature2 = nil
        latestTemperature3 = nil
        latestTemperature4 = nil
        latestTemperature1C = nil
        latestTemperature2C = nil
        latestTemperature3C = nil
        latestTemperature4C = nil
        latestHumidityRaw = nil
        latestHumidityRH = nil
        latestH2OSignal = nil
        latestCH4Signal = nil
        latestCO2Signal = nil
        latestH2SPrimary = nil
        latestH2SSecondary = nil
        latestPayloadDeviceName = nil
        latestRawPayload = ""
        latestRawFields = []

        lastTelemetryUpdateAt = nil
    }

    func startTimedSample(durationSec: Int = BLEConstants.defaultTimedSampleDurationSeconds) {
        guard connectedPeripheral != nil else {
            statusMessage = "Connect to a device before starting a timed sample."
            return
        }
        guard detectedDeviceType != .h2s else {
            statusMessage = "Timed sampling is available for methane devices only."
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

    private func enableStreamingIfReady(_ peripheral: CBPeripheral) {
        if let telemetryChar = telemetryCharacteristic {
            configureStreamingCharacteristic(telemetryChar, on: peripheral)
        }
    }

    private func configureStreamingCharacteristic(
        _ characteristic: CBCharacteristic,
        on peripheral: CBPeripheral
    ) {
        let canNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
        let canRead = characteristic.properties.contains(.read)

        if canNotify {
            peripheral.setNotifyValue(true, for: characteristic)
            stopTelemetryReadFallback()
        } else if canRead {
            startTelemetryReadFallback(peripheral: peripheral, characteristic: characteristic)
        }

        if canRead {
            peripheral.readValue(for: characteristic)
        }
    }

    private func startTelemetryReadFallback(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        telemetryReadFallbackTimer?.invalidate()
        telemetryReadFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: BLEConstants.readFallbackIntervalSeconds,
            repeats: true
        ) { _ in
            peripheral.readValue(for: characteristic)
        }
    }

    private func stopTelemetryReadFallback() {
        telemetryReadFallbackTimer?.invalidate()
        telemetryReadFallbackTimer = nil
    }

    private func resolveDeviceId(for peripheral: CBPeripheral) -> String? {
        let id = peripheral.identifier
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
            guard self.connectedPeripheral != nil else { return }

            guard let lastUpdate = self.lastTelemetryUpdateAt else { return }
            let stale = Date().timeIntervalSince(lastUpdate) > BLEConstants.signalTimeoutSeconds
            if stale {
                if self.connectionState != .signalTimeout {
                    self.transition(to: .signalTimeout, message: "Telemetry timeout. Attempting recovery...")
                }
                if let peripheral = self.connectedPeripheral,
                   let telemetryChar = self.telemetryCharacteristic,
                   telemetryChar.properties.contains(.read) {
                    peripheral.readValue(for: telemetryChar)
                }
            } else if self.connectionState == .signalTimeout {
                self.transition(to: .streaming, message: "Telemetry stream restored.")
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
                    deviceName: peripheral.name ?? "Sensor"
                )
            } else {
                sessionStore.updateActiveSessionDevice(
                    deviceId: peripheral.identifier.uuidString,
                    deviceName: peripheral.name ?? "Sensor"
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
        let ppm = rawValue
        appendCapped(rawValue, into: &methaneRawData, cap: 7200)
        appendCapped(ppm, into: &methanePPMData, cap: 7200)
        appendCapped(timestamp, into: &methaneTimestamps, cap: 7200)
        lastTelemetryUpdateAt = timestamp

        let reading = MethaneReading(
            timestamp: timestamp,
            rawValue: rawValue,
            ppm: ppm,
            temperatureC: latestTemperature1C,
            humidityRH: latestHumidityRH
        )
        appendCapped(reading, into: &liveReadings, cap: 300)
        if isSampling {
            appendCapped(reading, into: &timedSampleReadings, cap: 6000)
        }
        latestReading = reading
        maybeStoreReading(reading)

        if connectionState != .streaming {
            transition(to: .streaming, message: "Receiving telemetry.")
        }
    }

    private func resetCharacteristicReferences() {
        telemetryCharacteristic = nil
    }

    private func invalidateAllTimers() {
        telemetryReadFallbackTimer?.invalidate()
        signalWatchdogTimer?.invalidate()
        connectionDurationTimer?.invalidate()
        timedSampleTimer?.invalidate()

        for timer in connectionTimersByDeviceId.values {
            timer.invalidate()
        }

        telemetryReadFallbackTimer = nil
        signalWatchdogTimer = nil
        connectionDurationTimer = nil
        timedSampleTimer = nil
        connectionTimersByDeviceId.removeAll()
    }

    private func decodePayloadString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseCSVFields(_ payload: String) -> [String] {
        guard !payload.isEmpty else { return [] }
        return payload
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func splitDevicePrefix(from fields: [String]) -> (deviceName: String?, payloadFields: [String]) {
        guard let first = fields.first, !first.isEmpty else {
            return (nil, fields)
        }
        if first.rangeOfCharacter(from: .letters) != nil {
            return (first, Array(fields.dropFirst()))
        }
        return (nil, fields)
    }

    private func parseDouble(_ token: String) -> Double? {
        Double(token)
    }

    private func parseInt(_ token: String) -> Int? {
        if let value = Int(token) {
            return value
        }
        if let asDouble = Double(token) {
            return Int(asDouble)
        }
        return nil
    }

    private func parseMethanePayload(_ fields: [String]) -> MethanePayload? {
        guard fields.count >= 17 else { return nil }
        guard fields[1].lowercased() == "start", fields[12].lowercased() == "end" else { return nil }

        guard
            let deviceTime = parseInt(fields[0]),
            let h2o1 = parseDouble(fields[2]),
            let h2o2 = parseDouble(fields[3]),
            let co2Sensor = parseDouble(fields[4]),
            let pressureRaw = parseDouble(fields[5]),
            let temperature1 = parseDouble(fields[6]),
            let temperature2 = parseDouble(fields[7]),
            let temperature3 = parseDouble(fields[9]),
            let humidityRaw = parseDouble(fields[10]),
            let temperature4 = parseDouble(fields[11]),
            let h2oSignal = parseDouble(fields[14]),
            let ch4Signal = parseDouble(fields[15]),
            let co2Signal = parseDouble(fields[16])
        else {
            return nil
        }

        return MethanePayload(
            deviceTime: deviceTime,
            h2oSensor1: h2o1,
            h2oSensor2: h2o2,
            co2Sensor: co2Sensor,
            pressureRaw: pressureRaw,
            temperature1: temperature1,
            temperature2: temperature2,
            temperature3: temperature3,
            humidityRaw: humidityRaw,
            temperature4: temperature4,
            h2oSignal: h2oSignal,
            ch4Signal: ch4Signal,
            co2Signal: co2Signal
        )
    }

    private func parseH2SPayload(_ fields: [String]) -> H2SPayload? {
        guard fields.count >= 3 else { return nil }
        guard
            let deviceTime = parseInt(fields[0]),
            let primaryPPB = parseDouble(fields[1]),
            let secondaryPPB = parseDouble(fields[2])
        else {
            return nil
        }

        return H2SPayload(
            deviceTime: deviceTime,
            primaryPPB: primaryPPB,
            secondaryPPB: secondaryPPB
        )
    }

    private func processMethanePayload(_ payload: MethanePayload, at timestamp: Date) {
        if detectedDeviceType != .methane {
            h2sPrimaryData.removeAll()
            h2sSecondaryData.removeAll()
            h2sTimestamps.removeAll()
        }

        let pressureKPa = payload.pressureRaw / 100.0
        let temperature1C = payload.temperature1 / 100.0
        let temperature2C = payload.temperature2 / 100.0
        let temperature3C = payload.temperature3 / 100.0
        let temperature4C = payload.temperature4 / 100.0
        let humidityRH = payload.humidityRaw / 100.0

        detectedDeviceType = .methane
        latestDeviceTime = payload.deviceTime
        latestH2OSensor1 = payload.h2oSensor1
        latestH2OSensor2 = payload.h2oSensor2
        latestCO2Sensor = payload.co2Sensor
        latestPressureRaw = payload.pressureRaw
        latestPressureKPa = pressureKPa
        latestTemperature1 = payload.temperature1
        latestTemperature2 = payload.temperature2
        latestTemperature3 = payload.temperature3
        latestTemperature4 = payload.temperature4
        latestTemperature1C = temperature1C
        latestTemperature2C = temperature2C
        latestTemperature3C = temperature3C
        latestTemperature4C = temperature4C
        latestHumidityRaw = payload.humidityRaw
        latestHumidityRH = humidityRH
        latestH2OSignal = payload.h2oSignal
        latestCH4Signal = payload.ch4Signal
        latestCO2Signal = payload.co2Signal
        latestH2SPrimary = nil
        latestH2SSecondary = nil

        appendCapped(payload.h2oSensor1, into: &waterData, cap: 7200)
        appendCapped(payload.h2oSensor2, into: &waterSecondaryData, cap: 7200)
        appendCapped(timestamp, into: &waterTimestamps, cap: 7200)

        appendCapped(payload.co2Sensor, into: &co2Data, cap: 7200)
        appendCapped(timestamp, into: &co2Timestamps, cap: 7200)

        appendCapped(payload.pressureRaw, into: &pressureData, cap: 7200)
        appendCapped(timestamp, into: &pressureTimestamps, cap: 7200)
        appendCapped(pressureKPa, into: &pressureKPaData, cap: 7200)

        appendCapped(payload.temperature1, into: &temperatureData, cap: 7200)
        appendCapped(payload.temperature2, into: &temperature2Data, cap: 7200)
        appendCapped(payload.temperature3, into: &temperature3Data, cap: 7200)
        appendCapped(payload.temperature4, into: &temperature4Data, cap: 7200)
        appendCapped(timestamp, into: &temperatureTimestamps, cap: 7200)
        appendCapped(temperature1C, into: &temperatureCData, cap: 7200)
        appendCapped(temperature2C, into: &temperature2CData, cap: 7200)
        appendCapped(temperature3C, into: &temperature3CData, cap: 7200)
        appendCapped(temperature4C, into: &temperature4CData, cap: 7200)

        appendCapped(payload.humidityRaw, into: &humidityData, cap: 7200)
        appendCapped(timestamp, into: &humidityTimestamps, cap: 7200)
        appendCapped(humidityRH, into: &humidityRHData, cap: 7200)

        appendCapped(payload.h2oSignal, into: &h2oSignalData, cap: 7200)
        appendCapped(payload.co2Signal, into: &co2SignalData, cap: 7200)

        publishMethane(rawValue: payload.ch4Signal, at: timestamp)
    }

    private func processH2SPayload(_ payload: H2SPayload, at timestamp: Date) {
        if detectedDeviceType != .h2s {
            methaneRawData.removeAll()
            methanePPMData.removeAll()
            methaneTimestamps.removeAll()
            waterData.removeAll()
            waterSecondaryData.removeAll()
            waterTimestamps.removeAll()
            co2Data.removeAll()
            co2Timestamps.removeAll()
            pressureData.removeAll()
            pressureTimestamps.removeAll()
            pressureKPaData.removeAll()
            temperatureData.removeAll()
            temperature2Data.removeAll()
            temperature3Data.removeAll()
            temperature4Data.removeAll()
            temperatureTimestamps.removeAll()
            temperatureCData.removeAll()
            temperature2CData.removeAll()
            temperature3CData.removeAll()
            temperature4CData.removeAll()
            humidityData.removeAll()
            humidityTimestamps.removeAll()
            humidityRHData.removeAll()
            h2oSignalData.removeAll()
            co2SignalData.removeAll()
            liveReadings.removeAll()
            latestReading = nil
            timedSampleReadings.removeAll()
            if isSampling {
                cancelTimedSample()
            }
        }

        detectedDeviceType = .h2s
        latestDeviceTime = payload.deviceTime
        latestH2SPrimary = payload.primaryPPB
        latestH2SSecondary = payload.secondaryPPB

        latestH2OSensor1 = nil
        latestH2OSensor2 = nil
        latestCO2Sensor = nil
        latestPressureRaw = nil
        latestPressureKPa = nil
        latestTemperature1 = nil
        latestTemperature2 = nil
        latestTemperature3 = nil
        latestTemperature4 = nil
        latestTemperature1C = nil
        latestTemperature2C = nil
        latestTemperature3C = nil
        latestTemperature4C = nil
        latestHumidityRaw = nil
        latestHumidityRH = nil
        latestH2OSignal = nil
        latestCH4Signal = nil
        latestCO2Signal = nil

        appendCapped(payload.primaryPPB, into: &h2sPrimaryData, cap: 7200)
        appendCapped(payload.secondaryPPB, into: &h2sSecondaryData, cap: 7200)
        appendCapped(timestamp, into: &h2sTimestamps, cap: 7200)
        lastTelemetryUpdateAt = timestamp

        if connectionState != .streaming {
            transition(to: .streaming, message: "Receiving H2S telemetry.")
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state != .poweredOn {
            stopScanning()
            transition(to: .idle, message: "Bluetooth unavailable.")
            cancelTimedSample()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let candidateName = peripheral.name ?? advertisedName ?? ""
        let isLikelyAIMnetDevice = candidateName.hasPrefix(BLEConstants.deviceNamePrefix)
        if !isLikelyAIMnetDevice { return }

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

        startConnectionDurationTimer()
        startSignalWatchdog()
        startSessionIfNeeded(for: peripheral)

        if let deviceId = resolveDeviceId(for: peripheral) {
            activeDeviceIdByPeripheral[peripheral.identifier] = deviceId
            beginTimerTracking(forDeviceId: deviceId)
        }

        transition(to: .connecting, message: "Discovering services...")
        peripheral.discoverServices(nil)
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
        invalidateAllTimers()
        resetCharacteristicReferences()
        connectionDurationSec = 0
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
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BLEConstants.telemetryCharUUID {
                telemetryCharacteristic = characteristic
            }
        }

        enableStreamingIfReady(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if error != nil { return }

        if characteristic.uuid == BLEConstants.telemetryCharUUID {
            if characteristic.isNotifying {
                stopTelemetryReadFallback()
            } else if characteristic.properties.contains(.read) {
                startTelemetryReadFallback(peripheral: peripheral, characteristic: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        guard characteristic.uuid == BLEConstants.telemetryCharUUID else { return }

        let timestamp = Date()
        let payload = decodePayloadString(data)
        guard !payload.isEmpty else { return }

        let fields = parseCSVFields(payload)
        latestRawPayload = payload
        latestRawFields = fields
        let normalized = splitDevicePrefix(from: fields)
        latestPayloadDeviceName = normalized.deviceName
        let payloadFields = normalized.payloadFields
        guard !payloadFields.isEmpty else { return }

        if let methanePayload = parseMethanePayload(payloadFields) {
            processMethanePayload(methanePayload, at: timestamp)
            return
        }
        if let h2sPayload = parseH2SPayload(payloadFields) {
            processH2SPayload(h2sPayload, at: timestamp)
            return
        }

        // Fallback when incoming payload is neither expected methane nor H2S frame.
        if let fallbackValue = payloadFields.compactMap(parseDouble).first {
            detectedDeviceType = .methane
            latestCH4Signal = fallbackValue
            publishMethane(rawValue: fallbackValue, at: timestamp)
        }
    }
}
