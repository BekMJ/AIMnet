import Foundation

/// One K96 methane telemetry frame.
///
/// Field order follows the device frame and `k96_rt.py` (`COLS`):
/// `cnt, f1, f2, f3, P, T1, T1b, z, T2, RH, T3, flag, H2O, CH4, CO2`.
/// Raw device units are kept; the model divides where it needs to
/// (temperatures and RH are hundredths, pressure is tenths of hPa).
nonisolated struct K96Frame: Codable, Hashable {
    /// Device counter in seconds since power-on. Goes back on a power cycle.
    var cnt: Double
    /// Firmware value used by the start-up state detector (saturates at 32767 in the hot-restart state).
    var f1: Double
    /// Firmware CO2-channel value (about 450 in room air, below 60 in nitrogen).
    var f2: Double
    /// Firmware water value.
    var f3: Double
    /// Cell pressure, tenths of hPa.
    var P: Double
    var T1: Double
    /// NTC1, the main temperature input of every model (hundredths of °C).
    var T1b: Double
    var z: Double
    /// Die temperature (hundredths of °C).
    var T2: Double
    /// Relative humidity (hundredths of %).
    var RH: Double
    /// BME gas temperature (hundredths of °C).
    var T3: Double
    var flag: Double
    /// Optical H2O counts.
    var H2O: Double
    /// Optical CH4 counts (falls when methane rises).
    var CH4: Double
    /// Optical CO2 counts.
    var CO2: Double

    static let fieldNames = ["cnt", "f1", "f2", "f3", "P", "T1", "T1b", "z", "T2", "RH", "T3", "flag", "H2O", "CH4", "CO2"]

    var values: [Double] { [cnt, f1, f2, f3, P, T1, T1b, z, T2, RH, T3, flag, H2O, CH4, CO2] }

    init(values v: [Double]) {
        precondition(v.count == 15)
        cnt = v[0]; f1 = v[1]; f2 = v[2]; f3 = v[3]; P = v[4]; T1 = v[5]; T1b = v[6]; z = v[7]
        T2 = v[8]; RH = v[9]; T3 = v[10]; flag = v[11]; H2O = v[12]; CH4 = v[13]; CO2 = v[14]
    }

    var ntc1C: Double { T1b / 100.0 }
    var temperature1C: Double { T1 / 100.0 }
    var dieC: Double { T2 / 100.0 }
    var gasC: Double { T3 / 100.0 }
    var humidityRH: Double { RH / 100.0 }
    var pressureHPa: Double { P / 10.0 }

    /// Same rule as `k96_rt.parse_frame`: skip `start`, `end`, `-` and empty tokens and anything that
    /// is not a number, truncate numbers to integers, and use the LAST 15 values. Fewer than 15 -> nil.
    static func parse(tokens: [String]) -> K96Frame? {
        var vals: [Double] = []
        for raw in tokens {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "start" || t == "end" || t == "-" || t.isEmpty { continue }
            if let i = Int(t) {
                vals.append(Double(i))
            } else if let d = Double(t), d.isFinite, abs(d) < 1e15 {
                vals.append(Double(Int(d)))
            }
        }
        guard vals.count >= 15 else { return nil }
        return K96Frame(values: Array(vals.suffix(15)))
    }

    /// A methane frame as the firmware sends it: `cnt,start,<10 values>,end,<4 values>` (15 numbers).
    /// Requires the markers so that a truncated or split notification is never read as a frame.
    static func parseStrict(tokens: [String]) -> K96Frame? {
        let t = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let s = t.firstIndex(where: { $0.lowercased() == "start" }),
              let e = t.firstIndex(where: { $0.lowercased() == "end" }),
              s >= 1, e == s + 11, t.count == e + 5
        else { return nil }
        return parse(tokens: Array(t[(s - 1)...]))
    }
}
