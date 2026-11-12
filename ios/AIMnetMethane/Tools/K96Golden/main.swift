// Golden check for the Swift K96 port: runs the app's model code on each fixture's raw frames and compares every
// output with the reference Python outputs (`*.expected.csv`, made by make_golden.py).
//
//   ./run.sh                      (compiles this file with the app's Calibration sources and runs it)
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: k96golden <models dir> <fixtures dir>")
    exit(2)
}
let modelsDir = URL(fileURLWithPath: args[1])
let fixturesDir = URL(fileURLWithPath: args[2])
let specs = [K96ModelSpec.aimnet17, K96ModelSpec.c5]
let loaded = try specs.map { try K96LoadedModel(spec: $0, directory: modelsDir) }

func fmt(_ x: Double) -> String { x.isNaN ? "nan" : String(x) }

func parseCSVLine(_ line: String) -> [String] {
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

let files = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path).filter { $0.hasSuffix(".raw.csv") }.sorted()
var allOK = true
for f in files {
    let name = String(f.dropLast(".raw.csv".count))
    let raw = try String(contentsOf: fixturesDir.appendingPathComponent(f), encoding: .utf8)
    let expLines = try String(contentsOf: fixturesDir.appendingPathComponent(name + ".expected.csv"), encoding: .utf8)
        .split(whereSeparator: \.isNewline).dropFirst().map { parseCSVLine(String($0)) }
    let mm = K96MultiModel(models: loaded)
    var row = 0, rows = 0, worst = 0.0, mismatches = 0, firstBad = ""
    for line in raw.split(whereSeparator: \.isNewline) {
        guard let fr = K96Frame.parse(tokens: line.split(separator: ",").map(String.init)) else { continue }
        rows += 1
        let outs = mm.push(fr)
        for (k, o) in outs.enumerated() {
            guard row < expLines.count else { mismatches += 1; break }
            let e = expLines[row]; row += 1
            let model = specs[k].key
            let d = abs((Double(e[3]) ?? .nan) - o.ppmRaw)
            if d.isFinite { worst = max(worst, d) }
            let ok = e[0] == model
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
            if !ok {
                mismatches += 1
                if firstBad.isEmpty {
                    firstBad = "row \(row) model \(model)\n  python: \(e)\n  swift:  [\(model), \(o.cnt), \(o.ppm), \(o.ppmRaw), \(o.zeroed), \(o.state), \(fmt(o.zeroOffsetPPM)), \(o.flowTransient), \(o.bmeSuspect), \(o.zeroSuspect), \(fmt(o.expectedAbsErrPPM)), \(o.opticsInvalid), \(o.tempRateCPer5Min), \(o.reliability), \(o.reliabilityReason)]"
                }
            }
        }
    }
    if row != expLines.count { mismatches += 1; firstBad += "\n  row count: swift \(row), python \(expLines.count)" }
    let states = Set(expLines.map { $0[5] }).sorted().joined(separator: "/")
    print("\(name): \(rows) frames, states \(states), max |swift - python| ppm_raw = \(String(format: "%.2e", worst)), mismatching rows \(mismatches)")
    if mismatches > 0 { allOK = false; print(firstBad) }
}
print(allOK ? "ALL EQUAL" : "DIFFERENCES FOUND")
exit(allOK ? 0 : 1)
