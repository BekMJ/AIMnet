// Golden check for the Swift K96 port: runs the app's model code on each fixture's raw frames and compares every
// output of every model with the reference Python outputs (`*.expected.csv`, made by make_golden.py).
//
// Two runs per fixture:
//   full   - every model active from the first frame (as the Python UI)
//   switch - only AIMNet_1.7 active, every other model switched on halfway through (rebuilt by replaying the frames
//            of the power-on, as when the user picks another model in the app); compared from the switch on
//
//   ./run.sh /path/to/AIMNet_realtime/k96
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: k96golden <models dir> <fixtures dir>")
    exit(2)
}
let catalog = try K96Catalog(directory: URL(fileURLWithPath: args[1]))
if !catalog.loadErrors.isEmpty { print("load errors:", catalog.loadErrors); exit(1) }
let fixturesDir = URL(fileURLWithPath: args[2])
let keys = catalog.keys

func fmt(_ x: Double) -> String { x.isNaN ? "nan" : String(x) }

func parseCSVLine<S: StringProtocol>(_ line: S) -> [String] {
    var out: [String] = []; var cur = ""; var q = false
    for ch in line {
        if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
    }
    out.append(cur)
    return out
}

func close(_ a: String, _ b: Double, tol: Double) -> Bool {
    let x = Double(a) ?? .nan
    if x.isNaN || b.isNaN { return x.isNaN && b.isNaN }
    return abs(x - b) <= tol
}

func matches(_ e: [String], _ model: String, _ o: K96Output) -> Bool {
    e[0] == model
        && close(e[1], o.cnt, tol: 0)
        && close(e[2], o.ppm, tol: 1e-6)
        && close(e[3], o.ppmRaw, tol: 1e-6)
        && Int(e[4]) == (o.zeroed ? 1 : 0)
        && e[5] == o.state
        && close(e[6], o.zeroOffsetPPM, tol: 1e-6)
        && Int(e[7]) == (o.flowTransient ? 1 : 0)
        && Int(e[8]) == (o.bmeSuspect ? 1 : 0)
        && Int(e[9]) == (o.zeroSuspect ? 1 : 0)
        && close(e[10], o.expectedAbsErrPPM, tol: 1e-6)
        && Int(e[11]) == (o.opticsInvalid ? 1 : 0)
        && close(e[12], o.tempRateCPer5Min, tol: 1e-6)
        && Int(e[13]) == o.reliability
        && e[14] == o.reliabilityReason
}

struct Meta: Decodable { let manual_zero_at: Int?; let models: [String] }

let files = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path).filter { $0.hasSuffix(".raw.csv") }.sorted()
var allOK = true
for f in files {
    let name = String(f.dropLast(".raw.csv".count))
    let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: fixturesDir.appendingPathComponent(name + ".meta.json")))
    guard meta.models == keys else { print("\(name): model list differs from k96_config.json"); allOK = false; continue }
    let frames = try String(contentsOf: fixturesDir.appendingPathComponent(f), encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .compactMap { K96Frame.parse(tokens: $0.split(separator: ",").map(String.init)) }
    let expText = try String(contentsOf: fixturesDir.appendingPathComponent(name + ".expected.csv"), encoding: .utf8)
    let expLines = expText.split(whereSeparator: \.isNewline).dropFirst().map { parseCSVLine($0) }
    guard expLines.count == frames.count * keys.count else {
        print("\(name): python rows \(expLines.count) != frames \(frames.count) x models \(keys.count)"); allOK = false; continue
    }

    for mode in ["full", "switch"] {
        let switchAt = frames.count / 2
        let mm = K96MultiModel(catalog: catalog, active: mode == "full" ? keys : ["AIMNet_1.7"])
        if meta.manual_zero_at != nil { mm.setZeroMode(manual: true) }
        var compared = 0, mismatches = 0, worst = 0.0, firstBad = ""
        var badByModel: [String: Int] = [:]
        let start = Date()
        for (j, fr) in frames.enumerated() {
            if mode == "switch" && j == switchAt { mm.setActive(keys) }
            if j == meta.manual_zero_at { mm.zeroNow() }
            let outs = mm.push(fr)
            for (k, model) in keys.enumerated() {
                guard let o = outs[model] else { continue }
                if mode == "switch" && j < switchAt && model != "AIMNet_1.7" { continue }
                let e = expLines[j * keys.count + k]
                compared += 1
                let d = abs((Double(e[3]) ?? .nan) - o.ppmRaw)
                if d.isFinite { worst = max(worst, d) }
                if !matches(e, model, o) {
                    mismatches += 1
                    badByModel[model, default: 0] += 1
                    if firstBad.isEmpty {
                        firstBad = "  frame \(j) model \(model)\n  python: \(e)\n  swift:  [\(model), \(o.cnt), \(o.ppm), \(o.ppmRaw), \(o.zeroed), \(o.state), \(fmt(o.zeroOffsetPPM)), \(o.flowTransient), \(o.bmeSuspect), \(o.zeroSuspect), \(fmt(o.expectedAbsErrPPM)), \(o.opticsInvalid), \(o.tempRateCPer5Min), \(o.reliability), \(o.reliabilityReason)]"
                    }
                }
            }
        }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(frames.count)
        let states = Set(expLines.map { $0[5] }).sorted().joined(separator: "/")
        print("\(name) [\(mode)]: \(frames.count) frames, \(compared) outputs, states \(states), max |swift - python| = \(String(format: "%.1e", worst)) ppm, mismatches \(mismatches), \(String(format: "%.2f", ms)) ms/frame")
        if mismatches > 0 {
            allOK = false
            print("  by model:", badByModel.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            print(firstBad)
        }
    }
}
print(allOK ? "ALL EQUAL" : "DIFFERENCES FOUND")
exit(allOK ? 0 : 1)
