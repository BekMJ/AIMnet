import Foundation

struct MethaneReading: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    /// Optical CH4 counts from the sensor (falls when methane rises).
    let rawValue: Double
    /// Methane in ppm from the K96 model (display rule: max(0, x), values below 0.5 shown as 0).
    /// Sessions recorded before the model was added stored the raw counts here.
    let ppm: Double
    /// NTC1 (the model's temperature input), °C.
    let temperatureC: Double?
    let humidityRH: Double?

    // Added with the K96 model; optional so older saved sessions still load.
    var frame: K96Frame?
    var modelKey: String?
    /// Unclipped model reading (can be negative).
    var ppmRaw: Double?
    var zeroed: Bool?
    var modelState: String?
    /// 0 ok, 1 caution, 2 unreliable.
    var reliability: Int?
    var reliabilityReason: String?
    var expectedAbsErrPPM: Double?

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

    init(frame: K96Frame, output: K96Output?, modelKey: String?, timestamp: Date) {
        self.init(
            timestamp: timestamp,
            rawValue: frame.CH4,
            ppm: output?.ppm ?? .nan,
            temperatureC: frame.ntc1C,
            humidityRH: frame.humidityRH
        )
        self.frame = frame
        self.modelKey = modelKey
        if let output {
            ppmRaw = output.ppmRaw
            zeroed = output.zeroed
            modelState = output.state
            reliability = output.reliability
            reliabilityReason = output.reliabilityReason
            expectedAbsErrPPM = output.expectedAbsErrPPM.isNaN ? nil : output.expectedAbsErrPPM
        }
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

    private var finitePPM: [Double] { readings.map(\.ppm).filter(\.isFinite) }

    var averagePPM: Double {
        let v = finitePPM
        guard !v.isEmpty else { return 0 }
        return v.reduce(0, +) / Double(v.count)
    }

    var minPPM: Double { finitePPM.min() ?? 0 }
    var maxPPM: Double { finitePPM.max() ?? 0 }

    /// True when every reading came from a zeroed model with reliability 0.
    var allReliable: Bool { !readings.isEmpty && readings.allSatisfy { $0.zeroed == true && $0.reliability == 0 } }
}

/// CSV / JSON writers shared by session and timed-sample exports.
enum MethaneExport {
    static let csvHeader = (["timestamp", "model", "ch4_ppm", "ch4_ppm_raw", "zeroed", "model_state", "reliability",
                             "reliability_reason", "expected_abs_err_ppm"] + K96Frame.fieldNames).joined(separator: ",")

    static func csv(readings: [MethaneReading]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [csvHeader]
        lines.reserveCapacity(readings.count + 1)
        for r in readings {
            var cols: [String] = [
                formatter.string(from: r.timestamp),
                r.modelKey ?? "",
                num(r.ppm),
                num(r.ppmRaw),
                r.zeroed.map { $0 ? "1" : "0" } ?? "",
                r.modelState ?? "",
                r.reliability.map(String.init) ?? "",
                quote(r.reliabilityReason ?? ""),
                num(r.expectedAbsErrPPM),
            ]
            if let f = r.frame {
                cols += f.values.map { String(Int($0)) }
            } else {
                // sessions recorded before the K96 model: only the CH4 counts were kept
                var v = Array(repeating: "", count: 15)
                v[13] = num(r.rawValue)
                cols += v
            }
            lines.append(cols.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    private static func num(_ x: Double?) -> String {
        guard let x, x.isFinite else { return "" }
        return String(x)
    }

    private static func quote(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
