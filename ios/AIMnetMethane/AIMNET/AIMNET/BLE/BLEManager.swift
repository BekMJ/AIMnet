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

/// Readiness of the methane model for the device on view (mirrors the Python UI's readiness light).
struct MethaneModelStatus: Equatable {
    var ready = false
    var zeroed = false
    var holding = false
    var zeroCounter: Double?
    var detail: [String: Double] = [:]
    var powerOn = 0
}

final class BLEManager: NSObject, ObservableObject {
    struct AdvertisedInfo {
        let serialHex: String
        let bootReason: UInt8?
        let versionMajor: UInt8?
        let versionMinor: UInt8?
    }

    private struct H2SPayload {
        let deviceTime: Int
        let primaryPPB: Double
        let secondaryPPB: Double
    }

    private static let seriesCap = 7200

    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var isScanning = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var connectionState: BLEConnectionState = .idle
    @Published var statusMessage: String = "Bluetooth idle"
    @Published var connectionDurationSec: TimeInterval = 0
    @Published var connectionDurationsByDeviceId: [String: TimeInterval] = [:]

    // Methane (K96) series, one value per accepted frame, all aligned with `methaneTimestamps`.
    @Published var methaneTimestamps: [Date] = []
    /// Optical CH4 counts.
    @Published var methaneRawData: [Double] = []
    /// Model readings per active model (displayed rule max(0, x), < 0.5 shown as 0), aligned with `methaneTimestamps`.
    @Published private(set) var ppmSeriesByModel: [String: [Double]] = [:]
    /// Model readings not clipped at 0, per active model.
    @Published private(set) var ppmRawSeriesByModel: [String: [Double]] = [:]
    @Published var f1Data: [Double] = []
    @Published var f2Data: [Double] = []
    @Published var f3Data: [Double] = []
    @Published var pressureHPaData: [Double] = []
    @Published var t1CData: [Double] = []
    @Published var ntc1CData: [Double] = []
    @Published var dieCData: [Double] = []
    @Published var gasCData: [Double] = []
    @Published var humidityRHData: [Double] = []
    @Published var opticalH2OData: [Double] = []
    @Published var opticalCO2Data: [Double] = []

    @Published var latestFrame: K96Frame?
    /// Output of the displayed model (`displayedModelKey`).
    @Published var latestModelOutput: K96Output?
    /// Outputs of the active models, keyed by model key.
    @Published var latestModelOutputs: [String: K96Output] = [:]
    @Published var modelStatus = MethaneModelStatus()
    @Published private(set) var modelLoadError: String?

    /// Installation: sample tube at the device inlet (AIMNet_1.7) or at the old position (C5).
    /// Must match the real set-up: a wrong setting can make the reading wrong by tens to hundreds of ppm.
    @Published var tubeAtInlet: Bool {
        didSet {
            UserDefaults.standard.set(tubeAtInlet, forKey: Self.tubeAtInletKey)
            applyActiveModels()
        }
    }

    /// Model shown in the app: `automaticModelKey` = the config's recommendation for the tube position, else a model key.
    @Published var selectedModelKey: String {
        didSet {
            UserDefaults.standard.set(selectedModelKey, forKey: Self.selectedModelDefaultsKey)
            applyActiveModels()
        }
    }
    static let automaticModelKey = "auto"

    /// Manual zero mode: the model holds its one-time zero until `startZeroNow()` (choose before the power-on is zeroed).
    @Published var manualZero: Bool {
        didSet {
            UserDefaults.standard.set(manualZero, forKey: Self.manualZeroKey)
            for mm in multiModels.values { mm.setZeroMode(manual: manualZero) }
            refreshModelStatus()
        }
    }

    // H2S series
    @Published var h2sPrimaryData: [Double] = []
    @Published var h2sSecondaryData: [Double] = []
    @Published var h2sTimestamps: [Date] = []
    @Published var latestH2SPrimary: Double?
    @Published var latestH2SSecondary: Double?

    @Published var advertisementSerials: [UUID: String] = [:]
    @Published var peripheralSerials: [UUID: String] = [:]
    @Published var advertisedInfoByPeripheral: [UUID: AdvertisedInfo] = [:]

    @Published var detectedDeviceType: SensorDeviceType = .unknown
    @Published var latestDeviceTime: Int?
    @Published var latestPayloadDeviceName: String?
    @Published var latestRawPayload: String = ""
    @Published var latestRawFields: [String] = []
    @Published private(set) var currentRawLogURL: URL?

    @Published var latestReading: MethaneReading?
    @Published var liveReadings: [MethaneReading] = []

    @Published var isSampling = false
    @Published var sampleSecondsLeft = 0
    @Published var sampleDurationSeconds = BLEConstants.defaultTimedSampleDurationSeconds
    @Published var timedSampleReadings: [MethaneReading] = []
    @Published var lastTimedSample: MethaneTimedSample?

    private static let tubeAtInletKey = "k96.tubeAtInlet"
    private static let manualZeroKey = "k96.manualZero"
    private static let selectedModelDefaultsKey = "k96.selectedModel"

    private let sessionStore: SessionStore
    let k96Catalog: K96Catalog?
    /// Model state per device (serial when advertised, else the CoreBluetooth identifier). Kept across reconnects so a dropped
    /// link does not take a new zero in the middle of a power-on; a power cycle (counter going back) restarts the models.
    private var multiModels: [String: K96MultiModel] = [:]
    private var pendingRestore: Set<String> = []
    private var rawLogger: RawFrameLogger?
    private var lastAcceptedCnt: Double?

    private var centralManager: CBCentralManager!
    private var telemetryCharacteristic: CBCharacteristic?

    private var telemetryReadFallbackTimer: Timer?
    private var signalWatchdogTimer: Timer?
    private var connectionDurationTimer: Timer?
    private var connectionStartDate: Date?
    private var timedSampleTimer: Timer?
    private var timedSampleStartedAt: Date?
    private var lastTelemetryUpdateAt: Date?
    private var isScreenshotDemoMode = false

    private var activeDeviceIdByPeripheral: [UUID: String] = [:]
    private var connectionStartDatesByDeviceId: [String: Date] = [:]
    private var connectionTimersByDeviceId: [String: Timer] = [:]
    private var cumulativeDurationsByDeviceId: [String: TimeInterval] = [:]

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        let defaults = UserDefaults.standard
        tubeAtInlet = defaults.object(forKey: Self.tubeAtInletKey) as? Bool ?? true
        manualZero = defaults.bool(forKey: Self.manualZeroKey)
        selectedModelKey = defaults.string(forKey: Self.selectedModelDefaultsKey) ?? Self.automaticModelKey
        var loadError: String?
        do {
            let catalog = try K96Catalog()
            k96Catalog = catalog
            if !catalog.loadErrors.isEmpty { loadError = "some models were skipped: " + catalog.loadErrors.joined(separator: "; ") }
        } catch {
            k96Catalog = nil
            loadError = "\(error)"
        }
        super.init()
        modelLoadError = loadError
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        invalidateAllTimers()
    }

    /// Every model of the bundled config, in config order.
    var availableModels: [K96ModelSpec] { k96Catalog?.models.map(\.spec) ?? [] }

    /// The config's recommended model for a tube position.
    func recommendedModelKey(tubeAtInlet inlet: Bool) -> String {
        k96Catalog?.recommendedKey(tubeAtInlet: inlet) ?? (inlet ? "AIMNet_1.7" : "C5")
    }

    var recommendedModelKey: String { recommendedModelKey(tubeAtInlet: tubeAtInlet) }

    /// The model whose reading is shown and recorded.
    var displayedModelKey: String {
        if selectedModelKey != Self.automaticModelKey, k96Catalog?.model(selectedModelKey) != nil { return selectedModelKey }
        return recommendedModelKey
    }

    var displayedModelSpec: K96ModelSpec? { k96Catalog?.model(displayedModelKey)?.spec }

    var displayedModelLabel: String {
        let k = displayedModelKey
        let place = (displayedModelSpec?.isInletModel ?? false) ? "tube at inlet" : "old tube position"
        return selectedModelKey == Self.automaticModelKey ? "\(k) (recommended, \(place))" : "\(k) (\(place))"
    }

    /// True when the displayed model was trained for a different tube position than the one configured.
    var displayedModelMismatchesTube: Bool { (displayedModelSpec?.isInletModel ?? tubeAtInlet) != tubeAtInlet }

    var methanePPMData: [Double] { ppmSeriesByModel[displayedModelKey] ?? [] }
    var methanePPMRawData: [Double] { ppmRawSeriesByModel[displayedModelKey] ?? [] }

    /// Models computed on every frame: the displayed one, the recommendation for the tube position, and AIMNet_1.7
    /// (an inlet model with the physical water term, so the cross-model reliability notes are the same as in the Python UI).
    private var activeModelKeys: [String] {
        var keys = [displayedModelKey, recommendedModelKey]
        if k96Catalog?.model("AIMNet_1.7") != nil { keys.append("AIMNet_1.7") }
        return keys
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

    /// Manual zero mode: let the next frame that meets the stability criteria start the one-time zero.
    func startZeroNow() {
        guard let key = currentDeviceKey, let mm = multiModels[key] else { return }
        if mm.zeroNow() {
            statusMessage = "Zero requested: it starts at the next stable sample."
        } else {
            statusMessage = "A zero already exists for this power-on - not changed."
        }
        refreshModelStatus()
    }

    func clearLiveTelemetry() {
        methaneTimestamps.removeAll()
        methaneRawData.removeAll()
        ppmSeriesByModel = [:]
        ppmRawSeriesByModel = [:]
        f1Data.removeAll()
        f2Data.removeAll()
        f3Data.removeAll()
        pressureHPaData.removeAll()
        t1CData.removeAll()
        ntc1CData.removeAll()
        dieCData.removeAll()
        gasCData.removeAll()
        humidityRHData.removeAll()
        opticalH2OData.removeAll()
        opticalCO2Data.removeAll()

        h2sPrimaryData.removeAll()
        h2sSecondaryData.removeAll()
        h2sTimestamps.removeAll()

        liveReadings.removeAll()
        latestReading = nil
        latestFrame = nil
        latestModelOutput = nil
        latestModelOutputs = [:]
        modelStatus = MethaneModelStatus()

        detectedDeviceType = .unknown
        latestDeviceTime = nil
        latestH2SPrimary = nil
        latestH2SSecondary = nil
        latestPayloadDeviceName = nil
        latestRawPayload = ""
        latestRawFields = []

        lastTelemetryUpdateAt = nil
        lastAcceptedCnt = nil
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

    /// Stable key for the connected device: hardware serial when advertised, else the CoreBluetooth identifier.
    private var currentDeviceKey: String? {
        guard let p = connectedPeripheral else { return isScreenshotDemoMode ? "demo" : nil }
        return resolveDeviceId(for: p) ?? p.identifier.uuidString
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
        lastTelemetryUpdateAt = Date()
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

    private func startSessionIfNeeded(for peripheral: CBPeripheral) {
        let deviceId = resolveDeviceId(for: peripheral) ?? peripheral.identifier.uuidString
        let deviceName = peripheral.name ?? "Sensor"
        Task { @MainActor in
            if sessionStore.activeSession == nil {
                sessionStore.startSession(deviceId: deviceId, deviceName: deviceName)
            } else {
                sessionStore.updateActiveSessionDevice(deviceId: deviceId, deviceName: deviceName)
            }
        }
    }

    private func appendCapped<T>(_ value: T, into array: inout [T], cap: Int = BLEManager.seriesCap) {
        array.append(value)
        if array.count > cap {
            array.removeFirst(array.count - cap)
        }
    }

    // MARK: - Methane (K96) frames

    private func multiModel(for key: String) -> K96MultiModel? {
        guard let k96Catalog, !k96Catalog.models.isEmpty else { return nil }
        if let mm = multiModels[key] { return mm }
        let mm = K96MultiModel(catalog: k96Catalog, active: activeModelKeys)
        mm.setZeroMode(manual: manualZero)
        multiModels[key] = mm
        pendingRestore.insert(key)
        return mm
    }

    private func refreshRecommendedOutput() {
        latestModelOutput = latestModelOutputs[displayedModelKey]
    }

    /// Switch the computed models after a change of model or tube position. A model switched on mid power-on is rebuilt
    /// by replaying the frames of the power-on, so its reading and zero are exactly as if it had run from the start.
    private func applyActiveModels() {
        let keys = activeModelKeys
        let deviceKey = currentDeviceKey
        let n = methaneTimestamps.count
        for (k, mm) in multiModels {
            let built = mm.setActive(keys, keepLast: k == deviceKey ? max(n, 1) : 1)
            guard k == deviceKey else { continue }
            for (model, outs) in built {
                let tail = Array(outs.suffix(n))
                let pad = Array(repeating: Double.nan, count: max(0, n - tail.count))
                ppmSeriesByModel[model] = pad + tail.map(\.ppm)
                ppmRawSeriesByModel[model] = pad + tail.map(\.ppmRaw)
                if let last = outs.last { latestModelOutputs[model] = last }
            }
        }
        for model in Array(ppmSeriesByModel.keys) where !keys.contains(model) {
            ppmSeriesByModel[model] = nil
            ppmRawSeriesByModel[model] = nil
            latestModelOutputs[model] = nil
        }
        refreshRecommendedOutput()
    }

    private func refreshModelStatus() {
        guard let key = currentDeviceKey, let mm = multiModels[key] else {
            modelStatus = MethaneModelStatus()
            return
        }
        modelStatus = MethaneModelStatus(
            ready: mm.isReady,
            zeroed: mm.isZeroed,
            holding: mm.isHolding,
            zeroCounter: mm.zeroCount,
            detail: mm.readyDetail,
            powerOn: mm.powerOnCount
        )
    }

    private func processMethaneFrame(_ frame: K96Frame, at timestamp: Date) {
        if detectedDeviceType != .methane {
            h2sPrimaryData.removeAll()
            h2sSecondaryData.removeAll()
            h2sTimestamps.removeAll()
            latestH2SPrimary = nil
            latestH2SSecondary = nil
        }
        detectedDeviceType = .methane
        latestDeviceTime = Int(frame.cnt)
        latestFrame = frame
        lastTelemetryUpdateAt = timestamp

        var outputs: [String: K96Output] = [:]
        if let key = currentDeviceKey, let mm = multiModel(for: key) {
            if pendingRestore.remove(key) != nil, let logger = rawLogger {
                let candidates = RawFrameLogger.recentFiles(deviceName: logger.deviceName, excluding: logger.url)
                let (n, used) = K96Restore.restorePowerOn(mm, candidates: candidates, firstCnt: frame.cnt)
                if n > 0 {
                    statusMessage = "Methane model restored: \(n) frames of the current power-on replayed from \(used.count) file(s) (same zero)."
                }
            }
            outputs = mm.push(frame)
            refreshModelStatus()
        }
        latestModelOutputs = outputs
        refreshRecommendedOutput()
        let out = latestModelOutput

        appendCapped(timestamp, into: &methaneTimestamps)
        appendCapped(frame.CH4, into: &methaneRawData)
        var series = ppmSeriesByModel, rawSeries = ppmRawSeriesByModel
        for (model, o) in outputs {
            var s = series[model] ?? Array(repeating: .nan, count: methaneTimestamps.count - 1)
            appendCapped(o.ppm, into: &s)
            series[model] = s
            var r = rawSeries[model] ?? Array(repeating: .nan, count: methaneTimestamps.count - 1)
            appendCapped(o.ppmRaw, into: &r)
            rawSeries[model] = r
        }
        ppmSeriesByModel = series
        ppmRawSeriesByModel = rawSeries
        appendCapped(frame.f1, into: &f1Data)
        appendCapped(frame.f2, into: &f2Data)
        appendCapped(frame.f3, into: &f3Data)
        appendCapped(frame.pressureHPa, into: &pressureHPaData)
        appendCapped(frame.temperature1C, into: &t1CData)
        appendCapped(frame.ntc1C, into: &ntc1CData)
        appendCapped(frame.dieC, into: &dieCData)
        appendCapped(frame.gasC, into: &gasCData)
        appendCapped(frame.humidityRH, into: &humidityRHData)
        appendCapped(frame.H2O, into: &opticalH2OData)
        appendCapped(frame.CO2, into: &opticalCO2Data)

        let reading = MethaneReading(frame: frame, output: out, modelKey: out == nil ? nil : displayedModelKey, timestamp: timestamp)
        appendCapped(reading, into: &liveReadings, cap: 300)
        if isSampling {
            appendCapped(reading, into: &timedSampleReadings, cap: 6000)
        }
        latestReading = reading
        if !isScreenshotDemoMode {
            Task { @MainActor in sessionStore.append(reading: reading) }
        }

        if connectionState != .streaming {
            transition(to: .streaming, message: "Receiving telemetry.")
        }
    }

    // MARK: - H2S frames

    private func parseH2SPayload(_ fields: [String]) -> H2SPayload? {
        // exactly `time,primary,secondary`; a fragment of a methane frame is never taken for an H2S frame
        guard fields.count == 3, detectedDeviceType != .methane else { return nil }
        guard
            let deviceTime = Int(fields[0]) ?? Double(fields[0]).flatMap({ $0.isFinite && abs($0) < 1e15 ? Int($0) : nil }),
            let primaryPPB = Double(fields[1]),
            let secondaryPPB = Double(fields[2])
        else {
            return nil
        }
        return H2SPayload(deviceTime: deviceTime, primaryPPB: primaryPPB, secondaryPPB: secondaryPPB)
    }

    private func processH2SPayload(_ payload: H2SPayload, at timestamp: Date) {
        if detectedDeviceType != .h2s {
            let wasSampling = isSampling
            clearMethaneSeries()
            if wasSampling { cancelTimedSample() }
        }

        detectedDeviceType = .h2s
        latestDeviceTime = payload.deviceTime
        latestH2SPrimary = payload.primaryPPB
        latestH2SSecondary = payload.secondaryPPB

        appendCapped(payload.primaryPPB, into: &h2sPrimaryData)
        appendCapped(payload.secondaryPPB, into: &h2sSecondaryData)
        appendCapped(timestamp, into: &h2sTimestamps)
        lastTelemetryUpdateAt = timestamp

        if connectionState != .streaming {
            transition(to: .streaming, message: "Receiving H2S telemetry.")
        }
    }

    private func clearMethaneSeries() {
        methaneTimestamps.removeAll()
        methaneRawData.removeAll()
        ppmSeriesByModel = [:]
        ppmRawSeriesByModel = [:]
        f1Data.removeAll(); f2Data.removeAll(); f3Data.removeAll()
        pressureHPaData.removeAll()
        t1CData.removeAll(); ntc1CData.removeAll(); dieCData.removeAll(); gasCData.removeAll()
        humidityRHData.removeAll()
        opticalH2OData.removeAll(); opticalCO2Data.removeAll()
        liveReadings.removeAll()
        latestReading = nil
        latestFrame = nil
        latestModelOutput = nil
        latestModelOutputs = [:]
        timedSampleReadings.removeAll()
    }

    // MARK: - Payload decoding

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
        // "start" / "end" are frame markers, not a device name
        if first.rangeOfCharacter(from: .letters) != nil, !["start", "end"].contains(first.lowercased()) {
            return (first, Array(fields.dropFirst()))
        }
        return (nil, fields)
    }

    private func handlePayload(_ payload: String, at timestamp: Date) {
        let fields = parseCSVFields(payload)
        latestRawPayload = payload
        latestRawFields = fields
        let normalized = splitDevicePrefix(from: fields)
        if let name = normalized.deviceName { latestPayloadDeviceName = name }
        let payloadFields = normalized.payloadFields
        guard !payloadFields.isEmpty else { return }

        if let frame = K96Frame.parseStrict(tokens: payloadFields) {
            // A frame read again (start-up read, or the 1-s read fallback polling a 1.2-s device) is not a new sample:
            // the model's filters count samples, so a repeat would stretch its time constants.
            if let last = lastAcceptedCnt, frame.cnt == last { return }
            lastAcceptedCnt = frame.cnt
            logRaw(payloadFields, at: timestamp)
            processMethaneFrame(frame, at: timestamp)
            return
        }
        logRaw(payloadFields, at: timestamp)
        if let h2sPayload = parseH2SPayload(payloadFields) {
            processH2SPayload(h2sPayload, at: timestamp)
        }
        // anything else (a truncated or split frame) is shown in the raw payload panel and logged, never used as a reading
    }

    private func logRaw(_ tokens: [String], at timestamp: Date) {
        guard !isScreenshotDemoMode else { return }
        if rawLogger == nil {
            let name = latestPayloadDeviceName ?? connectedPeripheral?.name ?? "AIMNet"
            rawLogger = RawFrameLogger(deviceName: name, startedAt: timestamp)
            currentRawLogURL = rawLogger?.url
        }
        rawLogger?.append(tokens: tokens, at: timestamp)
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

    // MARK: - Screenshot demo

    func loadScreenshotDemoData(preferredDeviceType: String?) {
        isScreenshotDemoMode = true
        clearLiveTelemetry()
        bluetoothState = .poweredOn
        connectionState = .streaming
        connectionDurationSec = 742
        statusMessage = "Receiving live telemetry."
        latestPayloadDeviceName = preferredDeviceType == "h2s" ? "AIMNet H2S fsb002" : "AIMNet fsb001"

        if preferredDeviceType == "h2s" {
            let baseDate = Date().addingTimeInterval(-12 * 60)
            for index in 0..<96 {
                let time = baseDate.addingTimeInterval(Double(index) * 7.5)
                let progress = Double(index) / 95.0
                let sensor1 = 28_000 + sin(progress * .pi * 2.1) * 2_400 + progress * 11_000
                let sensor2Peak = 10_000 + sin(min(progress, 0.45) / 0.45 * .pi) * 6_200
                let sensor2 = progress < 0.5 ? sensor2Peak : 16_000 - (progress - 0.5) * 12_000
                processH2SPayload(
                    H2SPayload(deviceTime: 24_000 + index, primaryPPB: max(0, sensor1), secondaryPPB: max(8_800, sensor2)),
                    at: time
                )
            }
            latestRawPayload = "AIMNet H2S fsb002,24095,39880,10120"
            latestRawFields = ["AIMNet H2S fsb002", "24095", "39880", "10120"]
        } else {
            // A methane-free nitrogen cold start that settles, is zeroed, and then sees a small methane pulse.
            let frames = 900
            let baseDate = Date().addingTimeInterval(-Double(frames) * K96Constants.dtS)
            var lastTokens: [String] = []
            for k in 0..<frames {
                let t = Double(k) * K96Constants.dtS
                let temp = 26.0 - 3.0 * exp(-t / 300)
                let pulse = (t > 900 && t < 1020) ? 12.0 : 0
                let wobble = sin(Double(k) / 7) * 1.5
                let values: [Double] = [
                    16 + floor(t), -800 + wobble * 4, -12, -165, 9848, temp * 100 + 10, temp * 100, 0, (temp - 1) * 100, 0,
                    (temp + 1) * 100, 0, 42404 + wobble * 3, 40367 + 26 * (temp - 26) - 2 * pulse + wobble, 41787,
                ]
                let frame = K96Frame(values: values.map { $0.rounded() })
                lastTokens = [String(Int(frame.cnt)), "start"] + frame.values[1...10].map { String(Int($0)) } + ["end"] + frame.values[11...14].map { String(Int($0)) }
                lastAcceptedCnt = frame.cnt
                processMethaneFrame(frame, at: baseDate.addingTimeInterval(t))
            }
            latestRawFields = ["AIMNet fsb001"] + lastTokens
            latestRawPayload = latestRawFields.joined(separator: ",")
            let sampleReadings = Array(liveReadings.suffix(30))
            lastTimedSample = MethaneTimedSample(
                startedAt: sampleReadings.first?.timestamp ?? Date(),
                endedAt: sampleReadings.last?.timestamp ?? Date(),
                targetDurationSec: 30,
                readings: sampleReadings
            )
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if isScreenshotDemoMode {
            bluetoothState = .poweredOn
            return
        }
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
        rawLogger?.close()
        rawLogger = nil
        currentRawLogURL = nil

        startConnectionDurationTimer()
        startSignalWatchdog()
        startSessionIfNeeded(for: peripheral)

        if let deviceId = resolveDeviceId(for: peripheral) {
            activeDeviceIdByPeripheral[peripheral.identifier] = deviceId
            beginTimerTracking(forDeviceId: deviceId)
        }
        if let key = currentDeviceKey, multiModels[key] != nil {
            statusMessage = "Methane model continues the current power-on (same zero) after reconnecting."
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
        rawLogger?.close()

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
            guard let session = sessionStore.endSession() else { return }
            do {
                let exportedURL = try sessionStore.exportCSVOnDisconnect(session: session)
                statusMessage = "Disconnected. CSV saved: \(exportedURL.lastPathComponent)"
            } catch {
                statusMessage = "Disconnected. Auto CSV export failed: \(error.localizedDescription)"
            }
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

        let payload = decodePayloadString(data)
        guard !payload.isEmpty else { return }
        handlePayload(payload, at: Date())
    }
}
