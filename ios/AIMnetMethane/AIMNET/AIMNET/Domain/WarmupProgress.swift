import Foundation

/// How far the K96 warm-up is from the one-time zero, for the live screen.
///
/// The zero starts at the first frame where all of these hold (k96_rt.Stream):
///   - at least 5 min of frames since power-on,
///   - NTC1 changed by less than 0.5 C over 5 min,
///   - optical H2O changed by less than 150 counts over 2 min,
///   - f2 changed by less than 20 counts over 2 min,
/// and it is then the median of the next 20 s.
struct WarmupProgress: Equatable {
    enum Phase: Equatable {
        case warmingUp
        /// Manual zero mode: the sensor is stable and waits for "Start zero now".
        case waitingForManualZero
        /// The 20-s zero window is running.
        case zeroing
    }

    struct Check: Equatable, Identifiable {
        let id: String
        let title: String
        let value: Double
        let limit: Double
        let format: String

        var met: Bool { value < limit }
        var fraction: Double { value <= limit ? 1 : max(0, min(1, limit / value)) }
        var valueText: String { value.isFinite ? String(format: format, value) : "--" }
        var limitText: String { String(format: format, limit) }
    }

    var phase: Phase
    var secondsSincePowerOn: Double
    /// Part of the 5-min minimum already done, 0...1.
    var timeFraction: Double
    var checks: [Check]
    /// Overall progress 0...1; never goes back within one power-on.
    var fraction: Double
    /// Rough time left until the zero is set, as a range (nil while it cannot be estimated).
    var etaSeconds: ClosedRange<Double>?

    /// "about 3–7 min", "under a minute", or nil.
    var etaText: String? {
        guard let eta = etaSeconds else { return nil }
        let lo = Int((eta.lowerBound / 60).rounded(.up)), hi = Int((eta.upperBound / 60).rounded(.up))
        if hi <= 1 { return "under a minute" }
        if lo == hi { return "about \(hi) min" }
        return "about \(max(lo, 1))–\(hi) min"
    }
}

/// Builds `WarmupProgress` from the model's stability numbers, frame by frame, and estimates the time left.
///
/// Time estimate: the 5-min temperature change is fitted as an exponential decay over the last 4 min once it is falling.
/// On the recorded warm-ups in AIMNet_realtime/test the temperature settles more slowly near the end than an
/// exponential predicts, so the fitted time is the low end of the range and twice it the high end.
struct WarmupEstimator {
    static let minFrames = Int(K96RuntimeSettings.r33.calTwinS / K96Constants.dtS)
    static let zeroWindowS = K96RuntimeSettings.r33.calS
    private static let fitWindowS = 240.0
    private static let minFitSpanS = 90.0

    private var powerOnID: String?
    private var history: [(t: Double, dT: Double)] = []
    private var best = 0.0

    mutating func reset() {
        powerOnID = nil
        history.removeAll()
        best = 0
    }

    /// `feed` adds the current numbers to the fit (once per frame); a status refresh without a new frame passes false.
    mutating func update(powerOnID id: String, status: MethaneModelStatus, zeroing: Bool, feed: Bool) -> WarmupProgress? {
        if id != powerOnID {
            reset()
            powerOnID = id
        }
        let d = status.detail
        guard !status.zeroed, let dT = d["dT_5min"] else { return nil }
        let t = (d["min_since_start"] ?? 0) * 60
        if feed {
            history.append((t, dT))
            history.removeAll { t - $0.t > Self.fitWindowS || $0.t > t }
        }

        let checks = [
            WarmupProgress.Check(id: "T", title: "Temperature change / 5 min (C)", value: dT, limit: K96RuntimeSettings.r33.calDT, format: "%.2f"),
            WarmupProgress.Check(id: "H2O", title: "Water channel change / 2 min", value: d["dH2O_2min"] ?? .nan, limit: 150, format: "%.0f"),
            WarmupProgress.Check(id: "f2", title: "CO2 channel (f2) change / 2 min", value: d["df2_2min"] ?? .nan, limit: 20, format: "%.0f"),
        ]
        let timeFraction = min(1, Double(status.frames) / Double(Self.minFrames))

        let phase: WarmupProgress.Phase
        if zeroing {
            phase = .zeroing
        } else if status.holding && status.ready {
            phase = .waitingForManualZero
        } else {
            phase = .warmingUp
        }

        var fraction = ([timeFraction] + checks.map(\.fraction)).min() ?? 0
        if phase != .warmingUp { fraction = 1 }
        best = max(best, fraction)

        var eta: ClosedRange<Double>?
        switch phase {
        case .zeroing:
            eta = 0...Self.zeroWindowS
        case .waitingForManualZero:
            eta = nil
        case .warmingUp:
            let timeLeft = max(0, Double(Self.minFrames - status.frames)) * K96Constants.dtS
            let othersMet = checks.dropFirst().allSatisfy(\.met)
            if dT < K96RuntimeSettings.r33.calDT {
                eta = othersMet ? (timeLeft + Self.zeroWindowS)...(timeLeft + Self.zeroWindowS) : nil
            } else if let tempLeft = temperatureTimeLeft(dT: dT), othersMet || timeLeft < tempLeft {
                eta = (max(timeLeft, tempLeft) + Self.zeroWindowS)...(max(timeLeft, 2 * tempLeft) + Self.zeroWindowS)
            }
        }

        return WarmupProgress(
            phase: phase,
            secondsSincePowerOn: t,
            timeFraction: timeFraction,
            checks: checks,
            fraction: best,
            etaSeconds: eta
        )
    }

    /// Seconds until the 5-min temperature change falls below the limit, from an exponential fit of its recent decay.
    private func temperatureTimeLeft(dT: Double) -> Double? {
        let pts = history.filter { $0.dT > 0.02 }.map { (x: $0.t, y: log($0.dT)) }
        guard pts.count >= 20, let first = pts.first, let last = pts.last, last.x - first.x >= Self.minFitSpanS else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
        let sxx = pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = pts.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +) / sxx
        guard slope < 0 else { return nil }
        let left = log(dT / K96RuntimeSettings.r33.calDT) / -slope
        return left.isFinite && left < 3 * 3600 ? left : nil
    }
}
