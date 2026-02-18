import Foundation

struct MethaneReading: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let rawValue: Double
    let ppm: Double
    let temperatureC: Double?
    let humidityRH: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        rawValue: Double,
        ppm: Double,
        temperatureC: Double? = nil,
        humidityRH: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawValue = rawValue
        self.ppm = ppm
        self.temperatureC = temperatureC
        self.humidityRH = humidityRH
    }
}

struct MethaneCalibrationProfile: Codable, Hashable {
    let slopeRawPerPPM: Double
    let interceptRaw: Double
    let minimumPPM: Double
    let maximumPPM: Double?

    static let defaultLinear = MethaneCalibrationProfile(
        slopeRawPerPPM: 1.0,
        interceptRaw: 0.0,
        minimumPPM: 0.0,
        maximumPPM: nil
    )

    func ppm(fromRaw rawValue: Double) -> Double {
        guard slopeRawPerPPM > 0 else { return minimumPPM }
        let estimated = (rawValue - interceptRaw) / slopeRawPerPPM
        let clampedLow = max(minimumPPM, estimated)
        if let maximumPPM {
            return min(maximumPPM, clampedLow)
        }
        return clampedLow
    }
}

struct MethaneMonitoringSession: Identifiable, Codable, Hashable {
    let id: UUID
    var deviceId: String
    var deviceName: String
    var startedAt: Date
    var endedAt: Date?
    var readings: [MethaneReading]

    init(
        id: UUID = UUID(),
        deviceId: String,
        deviceName: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        readings: [MethaneReading] = []
    ) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.readings = readings
    }

    var durationSeconds: TimeInterval {
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt))
    }
}

struct MethaneTimedSample: Identifiable, Codable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let targetDurationSec: Int
    let readings: [MethaneReading]

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        targetDurationSec: Int,
        readings: [MethaneReading]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.targetDurationSec = targetDurationSec
        self.readings = readings
    }

    var durationSeconds: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var averagePPM: Double {
        guard !readings.isEmpty else { return 0 }
        let sum = readings.reduce(0.0) { $0 + $1.ppm }
        return sum / Double(readings.count)
    }

    var minPPM: Double {
        readings.map(\.ppm).min() ?? 0
    }

    var maxPPM: Double {
        readings.map(\.ppm).max() ?? 0
    }
}
