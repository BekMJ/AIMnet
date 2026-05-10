import Combine
import Foundation

enum SessionExportFormat: String, CaseIterable {
    case json
    case csv

    var fileExtension: String {
        rawValue
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var activeSession: MethaneMonitoringSession?
    @Published private(set) var recentSessions: [MethaneMonitoringSession] = []

    private let maxStoredSessions: Int
    private let indexURL: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(maxStoredSessions: Int = 25) {
        self.maxStoredSessions = maxStoredSessions
        let storageDirectory = Self.appStorageDirectory()
        self.indexURL = storageDirectory.appendingPathComponent("sessionIndex.json")
        loadSessionIndex()
    }

    func startSession(deviceId: String, deviceName: String) {
        if activeSession != nil {
            _ = endSession()
        }
        activeSession = MethaneMonitoringSession(
            deviceId: deviceId,
            deviceName: deviceName
        )
    }

    func updateActiveSessionDevice(deviceId: String, deviceName: String) {
        guard var session = activeSession else { return }
        session.deviceId = deviceId
        session.deviceName = deviceName
        activeSession = session
    }

    func append(reading: MethaneReading) {
        guard var session = activeSession else { return }
        session.readings.append(reading)
        activeSession = session
    }

    @discardableResult
    func endSession() -> MethaneMonitoringSession? {
        guard var session = activeSession else { return nil }
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        activeSession = nil
        recentSessions.insert(session, at: 0)
        trimStoredSessions()
        persistSessionIndex()
        return session
    }

    func clearHistory() {
        recentSessions.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
    }

    func loadScreenshotDemoData() {
        let baseDate = Date().addingTimeInterval(-12 * 60)
        let readings = (0..<120).map { index in
            let phase = Double(index) / 9.0
            return MethaneReading(
                timestamp: baseDate.addingTimeInterval(Double(index) * 6),
                rawValue: 1820 + sin(phase) * 85 + Double(index % 11) * 5,
                ppm: 1820 + sin(phase) * 85 + Double(index % 11) * 5,
                temperatureC: 24.4 + sin(phase / 2) * 0.6,
                humidityRH: 42.0 + cos(phase / 3) * 2.4
            )
        }
        recentSessions = [
            MethaneMonitoringSession(
                deviceId: "AIMNet-fsb001",
                deviceName: "AIMNet fsb001",
                startedAt: baseDate,
                endedAt: baseDate.addingTimeInterval(12 * 60),
                readings: readings
            )
        ]
    }

    func export(session: MethaneMonitoringSession, format: SessionExportFormat) throws -> URL {
        let directory = Self.shareExportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Int(session.startedAt.timeIntervalSince1970)
        let filename = "session_\(session.id.uuidString)_\(timestamp).\(format.fileExtension)"
        let fileURL = directory.appendingPathComponent(filename)

        switch format {
        case .json:
            let data = try encoder.encode(session)
            try data.write(to: fileURL, options: .atomic)
        case .csv:
            let csv = makeCSV(session: session)
            guard let data = csv.data(using: .utf8) else {
                throw NSError(
                    domain: "SessionStore",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode CSV as UTF-8."]
                )
            }
            try data.write(to: fileURL, options: .atomic)
        }

        return fileURL
    }

    func exportCSVOnDisconnect(session: MethaneMonitoringSession) throws -> URL {
        let directory = Self.appStorageDirectory().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let exportDate = session.endedAt ?? Date()
        let timestamp = Self.disconnectFilenameTimestamp(from: exportDate)
        let baseName = "session_\(timestamp)"
        let fileURL = Self.uniqueFileURL(
            in: directory,
            baseName: baseName,
            fileExtension: SessionExportFormat.csv.fileExtension
        )

        let csv = makeCSV(session: session)
        guard let data = csv.data(using: .utf8) else {
            throw NSError(
                domain: "SessionStore",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Unable to encode disconnect CSV as UTF-8."]
            )
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func makeCSV(session: MethaneMonitoringSession) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("timestamp,rawValue,ppm,temperatureRaw,humidityRaw")

        for reading in session.readings {
            let timestamp = formatter.string(from: reading.timestamp)
            let temperature = reading.temperatureC.map { String($0) } ?? ""
            let humidity = reading.humidityRH.map { String($0) } ?? ""
            lines.append(
                "\(timestamp),\(reading.rawValue),\(reading.ppm),\(temperature),\(humidity)"
            )
        }

        return lines.joined(separator: "\n")
    }

    private func trimStoredSessions() {
        if recentSessions.count > maxStoredSessions {
            recentSessions = Array(recentSessions.prefix(maxStoredSessions))
        }
    }

    private func loadSessionIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let decoded = try? decoder.decode([MethaneMonitoringSession].self, from: data) {
            recentSessions = decoded
            trimStoredSessions()
        }
    }

    private func persistSessionIndex() {
        guard let data = try? encoder.encode(recentSessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func appStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("AIMnetMethane", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func shareExportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMnetMethaneShareExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func disconnectFilenameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func uniqueFileURL(
        in directory: URL,
        baseName: String,
        fileExtension: String
    ) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "_\(attempt)"
            let filename = "\(baseName)\(suffix).\(fileExtension)"
            let candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }
}
