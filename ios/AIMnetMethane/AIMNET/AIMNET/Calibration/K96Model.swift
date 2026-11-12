import Foundation

// Swift port of the K96 methane real-time baseline pipeline (`k96/k96_rt.py`, AIMNet_realtime package of 2026-10-27).
//
// Every model listed in `k96_config.json` (a copy of the package's `k96/config.json`) can run: the state-model family
// (r33, C2-C16, AIMNet_1 ... AIMNet_2.4) and the pooled linear family (AIMNet_3.0-3.2 `lin`, AIMNet_3.3 `lin_ens`).
// Loading a model that needs a feature or option this port does not implement throws, so a new model cannot silently
// compute something different from Python. Equivalence with Python is checked by `Tools/K96Golden`.
//
// Every output uses only the current and earlier frames of the current power-on. One zero per power-on, taken
// once after warm-up and never changed. The CH4 reading is never a model input.

// MARK: - Constants and run-time settings

nonisolated enum K96Constants {
    static let gain = 2.0          // counts per ppm
    static let ambientCH4 = 2.0    // ppm of methane in room air (air-fraction truth)
    static let dtS = 1.222         // sample interval the filters were trained with (s)
    static let benchN2: (Double, Double) = (-1300.0, -400.0)
    static let benchAir: (Double, Double) = (-250.0, 800.0)
    static let opticsFrac = 0.75
    static let tEnv: (Double, Double) = (22.0, 33.0)
    static let rateMax = 0.5
    static let tRangeMax = 3.0
    static let genuineN2s = ["X_N2_TEMP_FLOW", "X_AIMNet fsb001 data 2026-10-15_16-25-29", "X_AIMNet fsb001 data 2026-10-15_18-36-50"]
    static let benchDefault = ["S1006", "S1007", "S1008", "S1009", "S1011"]
}

/// Values of `rt_final_r33.env` that the real-time code reads (unset keys use the Python defaults).
nonisolated struct K96RuntimeSettings {
    var tau = 55
    var tsFast = 200
    var fastLags = [0, 5, 10, 20, 40, 80, 160]
    var calTwinS = 300.0
    var calDT = 0.5
    var calS = 20.0
    var d1EarlyS: Double? = 6
    var detectS1 = 90.0
    var stateAir = 2
    var warmModel = true
    var warmFromT1 = true
    var calDefault = true
    var defaultOwnBench = true
    var defaultT0 = true
    var zsPPM = 60.0
    var ftDP = 2.0
    var ftMinutes = 90.0

    static let r33 = K96RuntimeSettings()
}

// MARK: - Model files

nonisolated struct K96LinearModel: Decodable {
    let X: [String]
    let coef: [Double]
    let icpt0: Double
    let sess_icpt: [String: Double]

    func dot(_ F: [String: Double]) -> Double {
        var s = 0.0
        for (c, v) in zip(X, coef) { s += F[c]! * v }
        return s + icpt0
    }
}

nonisolated struct K96S2: Decodable {
    let b: Double
    let lag: Int
    let pre: Bool
    let ashift: Double
    let ashift_n2only: Bool
    let cal_s: Double
    let gclip: [Double]?
    let gref: Double
    let nosat: Bool
}

/// State-model file (`models_*.json` with bench / n2shift / airshift models).
nonisolated struct K96ModelFile: Decodable {
    struct DefaultConstant: Decodable { let bench_T0_C: [String: Double] }
    let version: String
    let gain_counts_per_ppm: Double
    let models: [String: K96LinearModel]
    let warmup_model: K96LinearModel?
    let default_constant: DefaultConstant
    let s2: K96S2?
}

/// Pooled linear baseline file (`models_lin3x.json`): either one model (`names` / `coef`) or the 3.3 ensemble (A / B / C).
nonisolated struct K96LinFile: Decodable {
    struct Part: Decodable { let names: [String]; let coef: [Double]; let gq_span: Int? }
    struct PumpB: Decodable { let SP: Int; let LAG: Int; let G0: Double; let CPH: Double; let iP: Int; let iG: Int; let iD: Int }
    let names: [String]?
    let coef: [Double]?
    let water_spans: [String: Int]?
    let A: Part?
    let B: PumpB?
    let C: Part?
    let weights: [Double]?
}

nonisolated struct K96ExpectedError: Decodable {
    let key: String?
    let hours_edges: [Double]
    let median_abs_err_ppm: [Double]
    let beyond_8h_ppm: Double
    let rng_edges: [Double]?
    let median_abs_err_ppm_rng: [Double]?
    let beyond_rng_ppm: Double?
    let flow_transient_add_ppm: Double
    let pre_zero_abs_err_ppm: Double?
    let pre_zero_by_state: [String: Double]?
    let zero_offset_add_ppm: Double?
    let zero_offset_thr_ppm: Double?
}

/// One entry of `k96_config.json` (the package's `k96/config.json`).
nonisolated struct K96ModelSpec: Decodable, Identifiable {
    var key: String
    var label: String
    var json: String
    var type: String?
    var baseJson: String?
    var expectedErrJson: String?
    var show: Bool
    var n2s: [String]
    var bench: [String]
    var prezeroExcl: [String]
    var forceState: String?
    var geo: Double
    var geoReplace: [String]
    var tlag: Int
    var tlagStates: [String]
    var wphys: Double
    var wphysStates: [String]
    var wphysTau: Int
    var wphysZN2: Bool
    var wphysZN2States: [String]?
    var geoReplace2: [String]
    var geoReplace2States: [String]
    var geoIeTw: Int
    var wphysTauDry: Int
    var wphysDryLevel: Double
    var wphysDryAfgate: Double
    var wphysDryAfterZero: Bool

    var id: String { key }
    /// Trained for the sample tube at the device inlet (installation flag geo = 1).
    var isInletModel: Bool { geo > 0 }

    enum CodingKeys: String, CodingKey {
        case key, label, json, type, show, n2s, bench, geo, tlag, wphys
        case baseJson = "base_json", expectedErrJson = "expected_err_json", prezeroExcl = "prezero_excl", forceState = "force_state"
        case geoReplace = "geo_replace", tlagStates = "tlag_states", wphysStates = "wphys_states", wphysTau = "wphys_tau"
        case wphysZN2 = "wphys_zn2", wphysZN2States = "wphys_zn2_states", geoReplace2 = "geo_replace2"
        case geoReplace2States = "geo_replace2_states", geoIeTw = "geo_ie_tw", wphysTauDry = "wphys_tau_dry"
        case wphysDryLevel = "wphys_dry_level", wphysDryAfgate = "wphys_dry_afgate", wphysDryAfterZero = "wphys_dry_afterzero"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        json = try c.decode(String.self, forKey: .json)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        baseJson = try c.decodeIfPresent(String.self, forKey: .baseJson)
        expectedErrJson = try c.decodeIfPresent(String.self, forKey: .expectedErrJson)
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? true
        let n2 = try c.decodeIfPresent([String].self, forKey: .n2s) ?? []
        n2s = n2.isEmpty ? K96Constants.genuineN2s : n2
        let b = try c.decodeIfPresent([String].self, forKey: .bench) ?? []
        bench = b.isEmpty ? K96Constants.benchDefault : b
        prezeroExcl = try c.decodeIfPresent([String].self, forKey: .prezeroExcl) ?? []
        forceState = try c.decodeIfPresent(String.self, forKey: .forceState)
        geo = try c.decodeIfPresent(Double.self, forKey: .geo) ?? 0
        geoReplace = try c.decodeIfPresent([String].self, forKey: .geoReplace) ?? []
        tlag = try c.decodeIfPresent(Int.self, forKey: .tlag) ?? 0
        tlagStates = try c.decodeIfPresent([String].self, forKey: .tlagStates) ?? []
        wphys = try c.decodeIfPresent(Double.self, forKey: .wphys) ?? 0
        wphysStates = try c.decodeIfPresent([String].self, forKey: .wphysStates) ?? []
        let tau = try c.decodeIfPresent(Int.self, forKey: .wphysTau) ?? 35
        wphysTau = tau == 0 ? 35 : tau
        wphysZN2 = try c.decodeIfPresent(Bool.self, forKey: .wphysZN2) ?? false
        wphysZN2States = try c.decodeIfPresent([String].self, forKey: .wphysZN2States)
        geoReplace2 = try c.decodeIfPresent([String].self, forKey: .geoReplace2) ?? []
        geoReplace2States = try c.decodeIfPresent([String].self, forKey: .geoReplace2States) ?? []
        geoIeTw = try c.decodeIfPresent(Int.self, forKey: .geoIeTw) ?? 0
        wphysTauDry = try c.decodeIfPresent(Int.self, forKey: .wphysTauDry) ?? 0
        wphysDryLevel = try c.decodeIfPresent(Double.self, forKey: .wphysDryLevel) ?? 1e9
        wphysDryAfgate = try c.decodeIfPresent(Double.self, forKey: .wphysDryAfgate) ?? 0
        wphysDryAfterZero = try c.decodeIfPresent(Bool.self, forKey: .wphysDryAfterZero) ?? false
    }
}

nonisolated struct K96Config: Decodable {
    let env_file: String
    let expected_err_json: String
    let models: [K96ModelSpec]
    let recommended: [String: String]
    let installation_inlet_tube: Int?
    let default_shown: [String]?
    let env_override: [String: String]?
}

nonisolated enum K96ModelError: Error, CustomStringConvertible {
    case missingResource(String)
    case unsupportedFeature(model: String, feature: String)
    case badModel(String)

    var description: String {
        switch self {
        case .missingResource(let name): return "K96 model resource missing: \(name)"
        case .unsupportedFeature(let model, let feature): return "K96 model \(model) needs '\(feature)', which the iOS port does not implement"
        case .badModel(let why): return "K96 model invalid: \(why)"
        }
    }
}

/// Model file(s) + expected-error table of one config entry, loaded once and shared by every power-on.
nonisolated final class K96LoadedModel {
    let spec: K96ModelSpec
    /// State-model file (for `lin` / `lin_ens` entries: the base model that gives the zero and the information columns).
    let file: K96ModelFile
    let lin: K96LinFile?
    let expectedError: K96ExpectedError?

    init(spec: K96ModelSpec, file: K96ModelFile, lin: K96LinFile?, expectedError: K96ExpectedError?) throws {
        self.spec = spec
        self.file = file
        self.lin = lin
        self.expectedError = expectedError
        try validate()
    }

    var isLinear: Bool { spec.type == "lin" || spec.type == "lin_ens" }

    private func validate() throws {
        guard file.gain_counts_per_ppm == K96Constants.gain else { throw K96ModelError.badModel("\(spec.key): gain \(file.gain_counts_per_ppm) != 2") }
        for st in ["bench", "n2shift", "airshift"] where file.models[st] == nil {
            throw K96ModelError.badModel("\(spec.key): state model '\(st)' missing")
        }
        let all = Array(file.models.values) + (file.warmup_model.map { [$0] } ?? [])
        for m in all {
            guard m.X.count == m.coef.count else { throw K96ModelError.badModel("\(spec.key): X / coef length mismatch") }
            for c in m.X where !K96Stream.isSupported(feature: c) {
                throw K96ModelError.unsupportedFeature(model: spec.key, feature: c)
            }
        }
        if let f = spec.forceState, f != "bench" { throw K96ModelError.unsupportedFeature(model: spec.key, feature: "force_state \(f)") }
        switch spec.type {
        case nil:
            break
        case "lin":
            guard let lin, let names = lin.names, let coef = lin.coef, names.count == coef.count else {
                throw K96ModelError.badModel("\(spec.key): lin file needs names / coef")
            }
            for n in names where !K96LinStream.linFeatures.contains(n) { throw K96ModelError.unsupportedFeature(model: spec.key, feature: n) }
        case "lin_ens":
            guard let lin, let a = lin.A, let c = lin.C, lin.B != nil, a.names.count == a.coef.count, c.names.count == c.coef.count else {
                throw K96ModelError.badModel("\(spec.key): lin_ens file needs A / B / C")
            }
            for n in a.names where !K96LinStream.linFeatures.contains(n) { throw K96ModelError.unsupportedFeature(model: spec.key, feature: n) }
            for n in c.names where !(a.names.contains(n) || n == "gDq" || n == "gGq") { throw K96ModelError.unsupportedFeature(model: spec.key, feature: n) }
        default:
            throw K96ModelError.unsupportedFeature(model: spec.key, feature: "type \(spec.type!)")
        }
    }
}

/// Every model of `k96_config.json`, loaded from a folder or the app bundle.
nonisolated final class K96Catalog {
    let config: K96Config
    /// Loaded models in config order. Models that failed to load are left out and listed in `loadErrors`.
    let models: [K96LoadedModel]
    let loadErrors: [String]

    var keys: [String] { models.map(\.spec.key) }
    func model(_ key: String) -> K96LoadedModel? { models.first { $0.spec.key == key } }

    /// Recommended model for the installation (config 'recommended': "1" = tube at the inlet, "0" = old position).
    func recommendedKey(tubeAtInlet: Bool) -> String? {
        let k = config.recommended[tubeAtInlet ? "1" : "0"]
        return k.flatMap { model($0) != nil ? $0 : nil }
    }

    convenience init(bundle: Bundle = .main) throws {
        try self.init { name in
            let base = (name as NSString).deletingPathExtension
            guard let u = bundle.url(forResource: base, withExtension: "json") else { throw K96ModelError.missingResource(name) }
            return u
        }
    }

    convenience init(directory: URL) throws {
        try self.init { directory.appendingPathComponent($0) }
    }

    /// `locate` maps a file name (as written in config.json, folder part dropped) to its URL.
    init(locate: (String) throws -> URL) throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        func load<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try decoder.decode(T.self, from: Data(contentsOf: try locate((path as NSString).lastPathComponent)))
        }
        let config = try load(K96Config.self, "k96_config.json")
        guard config.env_file == "rt_final_r33.env", (config.env_override ?? [:]).isEmpty else {
            throw K96ModelError.badModel("only the rt_final_r33.env run-time settings are ported (config uses \(config.env_file))")
        }
        self.config = config
        var stateFiles: [String: K96ModelFile] = [:]
        var expFiles: [String: K96ExpectedError] = [:]
        var loaded: [K96LoadedModel] = []
        var errors: [String] = []
        for spec in config.models {
            do {
                let statePath = spec.type == nil ? spec.json : (spec.baseJson ?? "")
                let file = try stateFiles[statePath] ?? load(K96ModelFile.self, statePath)
                stateFiles[statePath] = file
                let lin: K96LinFile? = try spec.type.map { _ in try load(K96LinFile.self, spec.json) }
                let expPath = spec.expectedErrJson ?? config.expected_err_json
                let exp = try expFiles[expPath] ?? load(K96ExpectedError.self, expPath)
                expFiles[expPath] = exp
                loaded.append(try K96LoadedModel(spec: spec, file: file, lin: lin, expectedError: exp))
            } catch {
                errors.append("\(spec.key): \(error)")
            }
        }
        models = loaded
        loadErrors = errors
    }
}

// MARK: - Output

nonisolated struct K96Output: Hashable {
    var cnt: Double
    /// Displayed value: max(0, x), values below 0.5 ppm shown as 0.
    var ppm: Double
    /// Unclipped reading (can be negative).
    var ppmRaw: Double
    var zeroed: Bool
    /// bench (cold start) / n2shift (hot restart) / airshift (shifted room air).
    var state: String
    var zeroOffsetPPM: Double
    var flowTransient: Bool
    var bmeSuspect: Bool
    var zeroSuspect: Bool
    var expectedAbsErrPPM: Double
    var opticsInvalid: Bool
    var tempRateCPer5Min: Double
    /// 0 ok, 1 caution, 2 unreliable (information only; the reading is never changed).
    var reliability: Int
    var reliabilityReason: String
}

// MARK: - Small helpers (same arithmetic as Python / numpy)

nonisolated struct K96EMA {
    let a: Double
    var y: Double?
    init(span: Int) { a = 2.0 / (Double(span) + 1.0) }
    mutating func callAsFunction(_ x: Double) -> Double {
        if let y0 = y { y = y0 + a * (x - y0) } else { y = x }
        return y!
    }
}

/// Asymmetric EMA (k96_rt.AEMA): slow span while the input rises (cell drying), normal span otherwise.
nonisolated struct K96AEMA {
    let aw: Double, ad: Double, lv: Double
    var y: Double?
    init(spanWet: Int, spanDry: Int, level: Double) {
        aw = 2.0 / (Double(spanWet) + 1.0); ad = 2.0 / (Double(spanDry) + 1.0); lv = level
    }
    mutating func callAsFunction(_ x: Double, gate: Bool = true) -> Double {
        if let y0 = y { y = y0 + ((x > y0 && y0 < lv && gate) ? ad : aw) * (x - y0) } else { y = x }
        return y!
    }
}

/// k96_rt.AFGate: true within W minutes after the real-time air fraction dropped by more than 0.3.
nonisolated struct K96AFGate {
    let n: Int
    var buf: [Double] = []
    var lvl = 450.0
    var dq: [(Int, Double)] = []
    var head = 0
    var i = 0
    init(minutes: Double) { n = max(Int(minutes * 60 / 1.222), 1) }
    mutating func callAsFunction(_ f2: Double, active: Bool) -> Bool {
        if f2 > 300 {
            buf.append(f2)
            if buf.count > 100 { buf.removeFirst(buf.count - 100) }
            if buf.count >= 50 { lvl = K96Math.median(buf) }
        }
        let af = min(max(f2 / lvl, 0.0), 1.0)
        if !active { return false }
        while dq.count > head && dq[dq.count - 1].1 <= af { dq.removeLast() }
        dq.append((i, af))
        while dq[head].0 <= i - n { head += 1 }
        if head > 4096 { dq.removeFirst(head); head = 0 }
        i += 1
        return (dq[head].1 - af) > 0.3
    }
}

nonisolated enum K96Math {
    static func median(_ v: [Double]) -> Double {
        if v.isEmpty { return .nan }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// numpy.searchsorted(edges, x, side='right')
    static func searchsortedRight(_ edges: [Double], _ x: Double) -> Int {
        var i = 0
        while i < edges.count && edges[i] <= x { i += 1 }
        return i
    }

    /// Python round(x, 1)
    static func round1(_ x: Double) -> Double { (x * 10).rounded(.toNearestOrEven) / 10 }

    /// numpy.polyfit(x, y, 1) evaluated at x0
    static func linearFitValue(x: [Double], y: [Double], at x0: Double) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (a, b) in zip(x, y) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx) }
        let slope = sxx == 0 ? 0 : sxy / sxx
        return my + slope * (x0 - mx)
    }
}

/// Monotonic-queue running max / min over the last `window` values (k96_rt R1608).
nonisolated struct K96RunningRange {
    let window: Int
    private var i = 0
    private var maxQ: [(Int, Double)] = []
    private var minQ: [(Int, Double)] = []
    private var maxHead = 0
    private var minHead = 0
    init(window: Int) { self.window = window }

    mutating func push(_ v: Double) {
        i += 1
        let lo = i - window
        while maxQ.count > maxHead && maxQ[maxQ.count - 1].1 <= v { maxQ.removeLast() }
        maxQ.append((i, v))
        while minQ.count > minHead && minQ[minQ.count - 1].1 >= v { minQ.removeLast() }
        minQ.append((i, v))
        while maxQ[maxHead].0 <= lo { maxHead += 1 }
        while minQ[minHead].0 <= lo { minHead += 1 }
        if maxHead > 1024 { maxQ.removeFirst(maxHead); maxHead = 0 }
        if minHead > 1024 { minQ.removeFirst(minHead); minHead = 0 }
    }
    var range: Double { maxQ[maxHead].1 - minQ[minHead].1 }
}

/// Fixed-capacity FIFO (Python deque(maxlen=n)).
nonisolated struct K96Ring<T> {
    let capacity: Int
    private(set) var items: [T] = []
    private var head = 0
    init(capacity: Int) { self.capacity = capacity }
    var count: Int { items.count - head }
    var first: T? { count > 0 ? items[head] : nil }
    var last: T? { count > 0 ? items[items.count - 1] : nil }
    var elements: ArraySlice<T> { items[head...] }
    mutating func append(_ x: T) {
        items.append(x)
        if count > capacity { head += 1 }
        if head > 4096 { items.removeFirst(head); head = 0 }
    }
    mutating func popFirst() { head += 1; if head > 4096 { items.removeFirst(head); head = 0 } }
    mutating func replace(with xs: [T]) { items = xs; head = 0 }
}

// MARK: - Start-up state detector (k96_rt.detect)

nonisolated struct K96Detection {
    /// true = shifted state, false = within bench range, nil = undecided
    let shifted: Bool?
    let reason: String
    let gas: String?
}

nonisolated enum K96Detector {
    static func detect(_ rows: [K96Frame], uptoS: Double) -> K96Detection {
        let c0 = rows[0].cnt
        let w = rows.filter { $0.cnt < c0 + uptoS }
        if w.count < 5 { return K96Detection(shifted: nil, reason: "too few rows", gas: nil) }
        let f1 = w.map(\.f1)
        let f2 = K96Math.median(w.map(\.f2))
        let gas = f2 < 60 ? "N2" : (f2 > 300 ? "air" : "mix")
        let sat = Double(f1.filter { $0 >= 32767 }.count) / Double(f1.count)
        let unsat = f1.filter { $0 < 32767 }
        let f1m = unsat.isEmpty ? Double.nan : K96Math.median(unsat)
        if sat > 0.5 { return K96Detection(shifted: true, reason: "D1 f1 saturated", gas: gas) }
        let tOn = K96Math.median(w.map(\.cnt))
        let airHi = tOn < 150 ? 1050.0 : (tOn < 600 ? 850.0 : 650.0)
        var tr = Double.nan
        if w.count > 60 {
            let n = f1.count
            let a = Array(f1[0..<(n / 3)])
            let bCount = (n + 2) / 3          // Python f1[-len(f1) // 3:] keeps ceil(n / 3) values
            let b = Array(f1[(n - bCount)...])
            tr = K96Math.median(b) - K96Math.median(a)
        }
        if gas == "N2" && !(K96Constants.benchN2.0 <= f1m && f1m <= K96Constants.benchN2.1) {
            return K96Detection(shifted: true, reason: "D2 f1 outside bench N2 range", gas: gas)
        }
        if gas == "air" && !(K96Constants.benchAir.0 <= f1m && f1m <= airHi) {
            return K96Detection(shifted: true, reason: "D2 f1 outside bench air range", gas: gas)
        }
        if gas == "air" && f1m < -100 { return K96Detection(shifted: true, reason: "D5 f1 negative in air", gas: gas) }
        if gas == "air" && tr.isFinite && tr > 150 { return K96Detection(shifted: true, reason: "D4 f1 rising in air", gas: gas) }
        if gas == "mix" { return K96Detection(shifted: nil, reason: "gas state mixed in the window, retry later", gas: gas) }
        return K96Detection(shifted: false, reason: "f1 within bench range", gas: gas)
    }
}

// MARK: - Stream protocol

/// One model for one power-on (k96_rt.Stream / LinStream / LinEnsStream).
nonisolated protocol K96ModelStream: AnyObject {
    func push(_ r: K96Frame) -> K96Output
    var hold: Bool { get set }
    var zeroStartIndex: Int? { get }
    var zeroCounter: Double? { get }
    var zeroValue: Double? { get }
    var ready: Bool { get }
    var readyDetail: [String: Double] { get }
    // used by the cross-model reliability notes (K96MultiModel)
    var geo: Double { get }
    var wphysZN2: Bool { get }
    var f2AtZeroStart: Double? { get }
    var switchCnt: Double? { get }
    var switchNow: Double { get }
}

// MARK: - State models (k96_rt.Stream)

nonisolated final class K96Stream: K96ModelStream {
    private let spec: K96ModelSpec
    private let M: [String: K96LinearModel]
    private let W: K96LinearModel?
    private let T0b: [String: Double]
    private let s2: K96S2?
    private let expErr: K96ExpectedError?
    private let env: K96RuntimeSettings
    private let pzx: Set<String>
    private let cols: [String]
    private let colSet: Set<String>
    private let incTW: [Int]
    private let hingeCols: [(String, Double)]
    private let thingeCols: [(String, Double)]
    private let texpCols: [(String, Double)]
    private let geoFastCols: [(String, String)]
    private let geoSlowCols: [String]
    private let waterGroup: [String: [(String, Double)]]

    // feature state
    private var emaTL: K96EMA?
    private var TfL: Double?
    private var pTL: Double?
    private var ieL: [Int: Double] = [:]
    private var ilL: [Int: Double] = [:]
    private var FLag: [String: Double] = [:]
    private var emaWP: K96AEMA
    private var wpGate: K96AFGate?
    private var wpH: Double = .nan
    private var f2I0: Double?
    private var wpDZ: [String: Double]?
    private var wpD: [String: Double]?
    private var incE: [Int: Double] = [:]
    private var incL: [Int: Double] = [:]
    private var prevT: Double?
    private var TFirst: Double?
    private var emaH2O: K96EMA, emaF3: K96EMA, emaAH: K96EMA, emaDDie: K96EMA
    private var emaCO2 = K96EMA(span: 1800)
    private static let fch = ["H2O", "f3", "P", "NTC1", "die"]
    private var emaHP: [String: K96EMA]
    private var hp: [String: [Double]]
    private let hpKeep: Int

    // push state
    private var f2buf: [Double] = []
    private var lvl = 450.0
    private var hist: [String: [Double]] = ["H2O": [], "f2": [], "T": [], "P": [], "cnt": []]
    private var firstRows: [K96Frame] = []
    private let L: Int, L5: Int, histKeep: Int
    private var i = -1
    private var t0c: Double?
    private var cnt0 = 0.0
    private var T0 = 0.0
    private var decE: K96Detection?, decD60: K96Detection?, decD180: K96Detection?
    private(set) var i0: Int?
    private(set) var cntI0: Double?
    private var zbuf: [Double] = []
    private(set) var c1: Double?
    private var zeroAt: Int?
    var hold = false
    private(set) var ready = false
    private(set) var readyDetail: [String: Double] = [:]
    private var ghist: [Double] = []
    private var gcn: [Double] = []
    private var ashv: Double?
    private var bq: K96Ring<Double>
    private let bw: Int
    private var bqRange: K96RunningRange
    private var t3Run = 0, t1Run = 0, t2Run = 0
    private var t3Last: Double?, t1Last: Double?, t2Last: Double?
    private var t1bRun0 = 0.0, t2Run0 = 0.0, t1bRun2 = 0.0
    private var gq = K96Ring<(Double, Double)>(capacity: 100)
    private var zsPre: [Double] = []
    private var zsPost: [Double] = []
    private var zs = 0
    private var zo = Double.nan
    private var zoFrom = 1_000_000_000
    private var zsFrom = 1_000_000_000
    private var ftLast = -1e9
    private var ftP: K96Ring<Double>
    private var cnZero: Double?
    private var TMax = 0.0, TMin = 0.0
    private var gqZero: (Double, Double)?
    private var refRows: [(Double, Double)] = []
    private var refCO2: Double?, refH2O: Double?
    private var Tq = K96Ring<(Double, Double)>(capacity: Int.max)
    private var TqCn = -1e18
    private var gapLastCn: Double?
    private var dtq = K96Ring<Double>(capacity: 60)
    private var gapUntil = -1.0
    // R1927
    private var f2z: Double?
    private(set) var switchCnt: Double?
    private(set) var switchNow = 0.0
    private var f2Prev = 0.0

    var geo: Double { spec.geo }
    var wphysZN2: Bool { spec.wphysZN2 }
    var f2AtZeroStart: Double? { f2I0 }
    var zeroStartIndex: Int? { i0 }
    var zeroCounter: Double? { cntI0 }
    var zeroValue: Double? { c1 }

    static func isSupported(feature c: String) -> Bool {
        if ["NTC1", "P", "H2Ol", "f3l", "AHl", "co2rhp1800", "geo_NTC1slow", "geo2_NTC1slow",
            "geo_dDie", "geo_dDie_l", "geo_NTC1ie", "geo_Pslow"].contains(c) { return true }
        for p in ["NTC1ie", "NTC1il"] where c.hasPrefix(p) { return Int(c.dropFirst(6)) != nil }
        if c.hasPrefix("hinge") { return Double(c.dropFirst(5)) != nil }
        if c.hasPrefix("Thinge") { return Double(c.dropFirst(6)) != nil }
        if c.hasPrefix("Texp") { return Double(c.dropFirst(4)) != nil }
        if c.hasPrefix("fast_") {
            let p = c.split(separator: "_")
            return p.count == 4 && fch.contains(String(p[1])) && p[2] == "hp" && p[3].hasPrefix("l") && Int(p[3].dropFirst()) != nil
        }
        if c.hasPrefix("geo_fast_") { return false }
        if c.hasPrefix("geo_") { return isSupported(feature: "fast_" + c.dropFirst(4)) }
        return false
    }

    init(model: K96LoadedModel, env: K96RuntimeSettings = .r33) {
        spec = model.spec
        M = model.file.models
        W = model.file.warmup_model
        T0b = model.file.default_constant.bench_T0_C
        s2 = model.file.s2
        expErr = model.expectedError
        self.env = env
        pzx = Set(spec.prezeroExcl)
        let all = Array(M.values) + (W.map { [$0] } ?? [])
        cols = Array(Set(all.flatMap(\.X))).sorted()
        colSet = Set(cols)
        var tws = Set<Int>()
        for c in cols where c.hasPrefix("NTC1ie") || c.hasPrefix("NTC1il") { tws.insert(Int(c.dropFirst(6))!) }
        if spec.geoIeTw != 0 && colSet.contains("geo_NTC1ie") { tws.insert(spec.geoIeTw) }
        incTW = tws.sorted()
        for tw in incTW { incE[tw] = 0; incL[tw] = 0 }
        hingeCols = cols.filter { $0.hasPrefix("hinge") }.map { ($0, Double($0.dropFirst(5))!) }
        thingeCols = cols.filter { $0.hasPrefix("Thinge") }.map { ($0, Double($0.dropFirst(6))!) }
        texpCols = cols.filter { $0.hasPrefix("Texp") }.map { ($0, Double($0.dropFirst(4))!) }
        geoFastCols = cols.filter { $0.hasPrefix("geo_") }.map { ($0, "fast_" + $0.dropFirst(4)) }
        geoSlowCols = cols.filter { $0 == "geo_NTC1slow" || $0 == "geo2_NTC1slow" }
        var wg: [String: [(String, Double)]] = [:]
        for (st, m) in M {
            wg[st] = zip(m.X, m.coef).filter { $0.0 == "H2Ol" || $0.0 == "f3l" || $0.0 == "AHl" || $0.0.hasPrefix("hinge") }.map { ($0.0, $0.1) }
        }
        waterGroup = wg
        // plain EMA = AEMA with equal spans
        emaWP = spec.wphysTauDry != 0
            ? K96AEMA(spanWet: spec.wphysTau, spanDry: spec.wphysTauDry, level: spec.wphysDryLevel)
            : K96AEMA(spanWet: spec.wphysTau, spanDry: spec.wphysTau, level: 1e9)
        wpGate = (spec.wphysTauDry != 0 && spec.wphysDryAfgate != 0) ? K96AFGate(minutes: spec.wphysDryAfgate) : nil
        emaH2O = K96EMA(span: env.tau); emaF3 = K96EMA(span: env.tau); emaAH = K96EMA(span: env.tau); emaDDie = K96EMA(span: env.tau)
        emaHP = Dictionary(uniqueKeysWithValues: Self.fch.map { ($0, K96EMA(span: env.tsFast)) })
        hp = Dictionary(uniqueKeysWithValues: Self.fch.map { ($0, []) })
        hpKeep = (env.fastLags.max() ?? 0) + 1
        L = Int(120 / K96Constants.dtS)
        L5 = Int(env.calTwinS / K96Constants.dtS)
        histKeep = max(L, L5) + 1
        bw = max(Int(600 / 1.222), 2)
        bq = K96Ring(capacity: bw)
        bqRange = K96RunningRange(window: bw)
        ftP = K96Ring(capacity: Int(120 / 1.222) + 1)
    }

    // MARK: features (k96_rt.Stream.feats)

    private func feats(_ r: K96Frame) -> [String: Double] {
        var T = r.T1b / 100.0
        if spec.tlag != 0 && spec.geo > 0 && spec.tlagStates.isEmpty {
            // AIMNet_1.2: every temperature term sees the lagged temperature on inlet rows
            if emaTL == nil { emaTL = K96EMA(span: spec.tlag) }
            T = emaTL!(T)
        }
        if spec.tlag != 0 && spec.geo > 0 && !spec.tlagStates.isEmpty {
            if emaTL == nil {
                emaTL = K96EMA(span: spec.tlag); TfL = nil; pTL = nil
                for tw in incTW { ieL[tw] = 0; ilL[tw] = 0 }
            }
            let Tl = emaTL!(T)
            if TfL == nil { TfL = Tl }
            let dl = Tl - (pTL ?? Tl)
            pTL = Tl
            var FL: [String: Double] = ["NTC1": Tl]
            for tw in incTW {
                let we = exp(-max(r.cnt, 0.0) / Double(tw))
                ieL[tw]! += dl * we
                ilL[tw]! += dl * (1.0 - we)
                FL["NTC1ie\(tw)"] = TfL! + ieL[tw]!
                FL["NTC1il\(tw)"] = ilL[tw]!
            }
            for (c, x) in thingeCols { FL[c] = max(Tl - x, 0.0) }
            for (c, x) in texpCols { FL[c] = exp(min(max((Tl - 40.0) / x, -10), 5)) }
            for c in geoSlowCols { FL[c] = (Tl - 30.0) * spec.geo }
            FLag = FL
        }
        var F: [String: Double] = ["NTC1": T, "P": r.P / 10.0]
        F.reserveCapacity(cols.count + 16)
        if TFirst == nil { TFirst = T }
        if spec.wphys != 0 {
            if wpGate != nil {
                let g = wpGate!(r.f2, active: spec.wphysDryAfterZero ? (i0 != nil) : true)
                wpH = emaWP(r.H2O, gate: g)
            } else {
                wpH = emaWP(r.H2O)
            }
        }
        let hl = emaH2O(r.H2O)
        F["H2Ol"] = hl
        F["f3l"] = emaF3(r.f3)
        let T3 = r.T3 / 100.0
        let es = 6.112 * exp(17.62 * T3 / (243.12 + T3))
        F["AHl"] = emaAH(216.7 * (r.RH / 10000.0 * es) / (273.15 + T3))
        F["co2rhp1800"] = (r.CO2 - emaCO2(r.CO2)) / 100.0
        if prevT == nil { prevT = T }
        let dT = T - prevT!
        prevT = T
        for tw in incTW {
            let we = exp(-max(r.cnt, 0.0) / Double(tw))
            incE[tw]! += dT * we
            incL[tw]! += dT * (1.0 - we)
            F["NTC1ie\(tw)"] = TFirst! + incE[tw]!
            F["NTC1il\(tw)"] = incL[tw]!
        }
        for (c, x) in hingeCols { F[c] = max(hl - x, 0.0) }
        for (c, x) in thingeCols { F[c] = max(T - x, 0.0) }
        for (c, x) in texpCols { F[c] = exp(min(max((T - 40.0) / x, -10), 5)) }
        let raw: [String: Double] = ["H2O": r.H2O, "f3": r.f3, "P": r.P / 10.0, "NTC1": T, "die": r.T2 / 100.0]
        for c in Self.fch {
            let v = raw[c]!
            let h = v - emaHP[c]!(v)
            hp[c]!.append(h)
            if hp[c]!.count > hpKeep { hp[c]!.removeFirst() }
            let series = hp[c]!
            for lag in env.fastLags {
                F["fast_\(c)_hp_l\(lag)"] = lag == 0 ? h : (series.count > lag ? series[series.count - 1 - lag] : series[0])
            }
        }
        for (c, fastName) in geoFastCols { if let v = F[fastName] { F[c] = v * spec.geo } }
        for c in geoSlowCols { F[c] = (T - 30.0) * spec.geo }
        if colSet.contains("geo_dDie") || colSet.contains("geo_dDie_l") {
            let dd = r.T2 / 100.0 - T
            let ddl = emaDDie(dd)
            F["geo_dDie"] = dd * spec.geo
            F["geo_dDie_l"] = ddl * spec.geo
        }
        if colSet.contains("geo_NTC1ie") { F["geo_NTC1ie"] = (incE[spec.geoIeTw] ?? 0) * spec.geo }
        if colSet.contains("geo_Pslow") { F["geo_Pslow"] = (r.P / 10.0 - 980.0) * spec.geo }
        if !spec.geoReplace.isEmpty {
            for (k, v) in F where k.hasPrefix("fast_") {
                let ch = k.split(separator: "_")[1]
                if spec.geoReplace.contains(String(ch)) { F[k] = v * (1.0 - spec.geo) }
            }
        }
        return F
    }

    private func waterGroupValue(_ st: String, _ F: [String: Double]) -> Double {
        var s = 0.0
        for (c, v) in waterGroup[st] ?? [] { s += F[c]! * v }
        return s
    }

    private func defaultConstant(state st: String, model m: K96LinearModel) -> Double {
        var own: [String]
        if (st == "bench" || st == "airshift") && env.defaultOwnBench { own = spec.bench }
        else { own = st == "n2shift" ? spec.n2s : spec.bench }
        own = own.filter { !pzx.contains($0) }
        let v = own.compactMap { m.sess_icpt[$0] }
        let benchOwn = spec.bench.filter { !pzx.contains($0) }
        if env.defaultT0 && own == benchOwn && v.count >= 3 && cnt0 < 600 {
            let kk = own.filter { m.sess_icpt[$0] != nil && T0b[$0] != nil }
            let ic = kk.map { m.sess_icpt[$0]! }
            let t0 = kk.map { T0b[$0]! }
            let x0 = min(max(T0, t0.min()!), t0.max()!)
            return K96Math.linearFitValue(x: t0, y: ic, at: x0)
        }
        return v.isEmpty ? 0.0 : K96Math.median(v)
    }

    // MARK: push (k96_rt.Stream.push)

    func push(_ r: K96Frame) -> K96Output {
        i += 1
        let cn = r.cnt
        if t0c == nil { t0c = cn; cnt0 = cn; T0 = r.T1b / 100.0 }
        let t0c = self.t0c!
        let F = feats(r)
        if spec.wphys != 0 && wpD == nil {
            var d: [String: Double] = [:]
            for st in spec.wphysStates where M[st] != nil { d[st] = waterGroupValue(st, F) - spec.wphys * (wpH - 41000.0) }
            wpD = d
        }
        let v = r.f2
        if v > 300 {
            f2buf.append(v)
            if f2buf.count > 100 { f2buf.removeFirst(f2buf.count - 100) }
            if f2buf.count >= 50 { lvl = K96Math.median(f2buf) }
        }
        let af = min(max(v / lvl, 0.0), 1.0)
        if cn < t0c + 180.5 { firstRows.append(r) }
        if let early = env.d1EarlyS, decE == nil, cn >= t0c + early { decE = K96Detector.detect(firstRows, uptoS: early) }
        if decD60 == nil && cn >= t0c + env.detectS1 { decD60 = K96Detector.detect(firstRows, uptoS: env.detectS1) }
        if decD180 == nil && cn >= t0c + 180 { decD180 = K96Detector.detect(firstRows, uptoS: 180) }
        let hasN2 = M["n2shift"] != nil
        let forceBench = spec.forceState == "bench"
        var d1e = (decE?.reason.hasPrefix("D1") ?? false) && hasN2
        var stFirst = (hasN2 && ((decD60?.reason.hasPrefix("D1") ?? false) || d1e)) ? "n2shift" : "bench"
        if forceBench { d1e = false; stFirst = "bench" }
        let t1 = t0c + (d1e ? env.d1EarlyS! : env.detectS1)
        var state: String?
        var t2: Double
        if let d180 = decD180 {
            let dd = d180.shifted != nil ? d180 : decD60!
            if dd.reason.hasPrefix("D1") { state = "n2shift" }
            else if (env.stateAir == 1 || env.stateAir == 2) && dd.shifted == true && dd.gas == "air" { state = "airshift" }
            else { state = "bench" }
            t2 = d180.shifted != nil ? t0c + 180.0 : t1
        } else {
            state = nil
            t2 = t0c + 180.0
        }
        if forceBench && state != nil { state = "bench" }
        let st: String = cn < t1 ? "bench" : (cn < t2 ? stFirst : (state ?? "bench"))
        var Fm: [String: Double] = (!FLag.isEmpty && spec.tlagStates.contains(st)) ? F.merging(FLag) { _, b in b } : F
        if !spec.geoReplace2.isEmpty && spec.geo > 0 && spec.geoReplace2States.contains(st) {
            for (k, val) in Fm where k.hasPrefix("fast_") && spec.geoReplace2.contains(String(k.split(separator: "_")[1])) {
                Fm[k] = val * (1.0 - spec.geo)
            }
        }
        var base = M[st]!.dot(Fm)
        if spec.wphys != 0 && spec.geo > 0 && spec.wphysZN2 {
            if let i0, i > i0, let f2I0, (f2I0 < 300 || (spec.wphysZN2States != nil && !spec.wphysZN2States!.contains(st))) {
                if wpDZ == nil {
                    var d: [String: Double] = [:]
                    for s in spec.wphysStates where M[s] != nil { d[s] = waterGroupValue(s, F) - spec.wphys * (wpH - 41000.0) }
                    wpDZ = d
                }
                if let dz = wpDZ![st] { base = base - waterGroupValue(st, F) + spec.wphys * (wpH - 41000.0) + dz }
            }
        } else if spec.wphys != 0 && spec.geo > 0 && spec.wphysStates.contains(st) {
            base = base - waterGroupValue(st, F) + spec.wphys * (wpH - 41000.0) + wpD![st]!
        }
        let baseNoS2 = base
        var gNow = r.T3 / 100.0 - r.T1b / 100.0
        if let gc = s2?.gclip, gc.count == 2 { gNow = min(max(gNow, gc[0]), gc[1]) }
        ghist.append(gNow); gcn.append(cn)
        if ghist.count > 400 { ghist.removeFirst(); gcn.removeFirst() }
        let s2on = s2 != nil && cn >= t2 && !(s2!.nosat && st == "n2shift")
        var gl = 0.0
        if s2on, let s2 {
            gl = ghist[max(0, ghist.count - 1 - s2.lag)]
            base = base - K96Constants.gain * s2.b * gl
        }
        let tc = r.CH4 + K96Constants.gain * K96Constants.ambientCH4 * af
        let resid = tc - base
        for (k, x) in [("H2O", r.H2O), ("f2", r.f2), ("T", r.T1b / 100.0), ("P", r.P / 10.0), ("cnt", cn)] {
            hist[k]!.append(x)
            if hist[k]!.count > histKeep { hist[k]!.removeFirst() }
        }
        func lagd(_ k: String, _ lag: Int) -> Double {
            let h = hist[k]!
            return abs(h[h.count - 1] - (i >= lag ? h[h.count - 1 - lag] : h[0]))
        }
        let stable = lagd("H2O", L) < 150 && lagd("f2", L) < 20 && lagd("T", L5) < env.calDT && i >= L5
        ready = stable
        readyDetail = ["dT_5min": lagd("T", L5), "dH2O_2min": lagd("H2O", L), "df2_2min": lagd("f2", L), "min_since_start": (cn - t0c) / 60.0]
        if i0 == nil && stable && !hold { i0 = i; cntI0 = cn; f2I0 = r.f2 }
        var c = 0.0
        var conf = false
        if i0 != nil {
            if c1 == nil {
                if cn < cntI0! + env.calS { zbuf.append(resid) }
                else if zbuf.count >= 8 { c1 = K96Math.median(zbuf); zeroAt = i - 1 }
                else {
                    zbuf.append(resid)
                    if zbuf.count >= 8 { c1 = K96Math.median(zbuf); zeroAt = i }
                }
            }
            if let c1, i > zeroAt! {
                conf = true
                c = c1
                if s2on, let s2, s2.ashift != 0 {
                    if ashv == nil {
                        let gw = zip(gcn, ghist).filter { cn - s2.cal_s <= $0.0 && $0.0 < cn }.map(\.1)
                        let g0s = gw.isEmpty ? ghist[ghist.count - 1] : K96Math.median(gw)
                        ashv = (s2.ashift_n2only && r.f2 > 300) ? 0.0 : s2.ashift * K96Constants.gain * s2.b * (s2.gref - g0s)
                    }
                    c += ashv!
                }
            }
        }
        var outBase = base
        if !conf {
            outBase = baseNoS2
            let warm = env.warmFromT1 ? (st == "bench" && cn >= t1) : (state == "bench" && cn >= t2)
            if env.warmModel && warm, let W {
                outBase = W.dot(F)
                c = defaultConstant(state: "bench", model: W)
            } else if env.calDefault {
                c = defaultConstant(state: st, model: M[st]!)
            }
            if s2on, let s2, s2.pre { outBase = outBase - K96Constants.gain * s2.b * (gl - s2.gref) }
        }
        let raw = (outBase + c - r.CH4) / K96Constants.gain

        // ---- information only (readings unchanged) ----
        let t3 = r.T3, t1b = r.T1b, t2v = r.T2
        bq.append(t3)
        t3Run = (t3Last == t3) ? t3Run + 1 : 1
        t3Last = t3
        if t3Run == 1 { t1bRun0 = t1b }
        t1Run = (t1Last == t1b) ? t1Run + 1 : 1
        t1Last = t1b
        if t1Run == 1 { t2Run0 = t2v }
        t2Run = (t2Last == t2v) ? t2Run + 1 : 1
        t2Last = t2v
        if t2Run == 1 { t1bRun2 = t1b }
        gq.append(((t3 - t1b) / 100.0, (t2v - t1b) / 100.0))
        bqRange.push(t1b)
        let bme = bq.count >= bw && t3Run >= bw && bqRange.range > 30
        let bmeHold = bme || (t3Run >= bw / 2 && abs(t1b - t1bRun0) > 20)
        if !conf {
            zsPre.append(raw)
            if zsPre.count > 50 { zsPre.removeFirst(zsPre.count - 50) }
        } else if zsPost.count < 16 {
            zsPost.append(raw)
            if zsPost.count == 16 && zsPre.count >= 8 {
                zo = K96Math.round1(K96Math.median(zsPre) - K96Math.median(zsPost))
                zoFrom = i + 1
                if zo > env.zsPPM { zs = 1; zsFrom = i + 1 }
            }
        }
        let zsFlag = zs == 1 && i >= zsFrom
        ftP.append(r.P / 10.0)
        if abs(ftP.last! - ftP.first!) > env.ftDP { ftLast = cn }
        let ft = cn - ftLast < env.ftMinutes * 60.0
        var ee = Double.nan
        if !conf && cnZero == nil, let e = expErr {
            if let p = e.pre_zero_abs_err_ppm { ee = p }
            if let byState = e.pre_zero_by_state, cn >= t2, let state {
                ee = byState[state] ?? e.pre_zero_abs_err_ppm ?? .nan
            }
        }
        if conf {
            if cnZero == nil {
                cnZero = cn
                TMax = r.T1b / 100.0; TMin = TMax
                gqZero = (K96Math.median(gq.elements.map(\.0)), K96Math.median(gq.elements.map(\.1)))
            }
            let Tv = r.T1b / 100.0
            TMax = max(TMax, Tv); TMin = min(TMin, Tv)
            if let e = expErr {
                let medh = e.median_abs_err_ppm + [e.beyond_8h_ppm]
                var b = medh[min(K96Math.searchsortedRight(Array(e.hours_edges.dropFirst()), (cn - cnZero!) / 3600.0), medh.count - 1)]
                if e.key == "max_hours_rng", let rngE = e.rng_edges, let medR = e.median_abs_err_ppm_rng, let beyond = e.beyond_rng_ppm {
                    let medr = medR + [beyond]
                    b = max(b, medr[min(K96Math.searchsortedRight(Array(rngE.dropFirst()), TMax - TMin), medr.count - 1)])
                }
                ee = b + e.flow_transient_add_ppm * (ft ? 1 : 0)
                if let add = e.zero_offset_add_ppm, i >= zoFrom, abs(zo) > (e.zero_offset_thr_ppm ?? 30) { ee += add }
            }
        }
        if cn < t0c + 60.0 { refRows.append((r.CO2, r.H2O)) }
        if refCO2 == nil || cn < t0c + 60.0 {
            refCO2 = K96Math.median(refRows.map(\.0))
            refH2O = K96Math.median(refRows.map(\.1))
        }
        let optBad = r.CO2 < K96Constants.opticsFrac * refCO2! && r.H2O < K96Constants.opticsFrac * refH2O!
        let Tn = r.T1b / 100.0
        Tq.append((cn, Tn))
        if cn >= TqCn {
            while let f = Tq.first, f.0 < cn - 300.0 { Tq.popFirst() }
        } else {
            Tq.replace(with: Tq.elements.filter { $0.0 >= cn - 300.0 })
        }
        TqCn = cn
        let rate = cn - Tq.first!.0 >= 120.0 ? abs(Tn - Tq.first!.1) : 0.0
        let lc = gapLastCn
        gapLastCn = cn
        if let lc, cn - lc > 0, cn - lc <= 30.0 { dtq.append(cn - lc) }
        if let lc, cn - lc > 30.0 { gapUntil = cn + 120.0 }

        var rel: Int
        var why: String
        let tEnv = K96Constants.tEnv
        if optBad { rel = 2; why = "optics invalid (all optical channels low, e.g. condensation)" }
        else if !conf { rel = 2; why = "not zeroed yet (provisional)" + (st == "n2shift" ? "; hot-restart (+800) state: a warm nitrogen restart can read several hundred ppm too high until the zero" : "") }
        else if t1Run >= bw / 2 && abs(t2v - t2Run0) > 20 { rel = 2; why = "NTC1 unchanged for >= 5 min while the die temperature moved > 0.2 C: NTC1 may be stuck - every model reads wrong (tens to hundreds of ppm)" }
        else if t2Run >= bw / 2 && abs(t1b - t1bRun2) > 20 { rel = 2; why = "die temperature (T2) unchanged for >= 5 min while NTC1 moved > 0.2 C: sensor may be stuck - models using the die - NTC1 gradient (3.x) can read hundreds of ppm wrong" }
        else if bmeHold { rel = 2; why = "gas temperature (BME T3) unchanged for >= 5 min while NTC1 moved > 0.2 C: sensor may be stuck - models using the gas - NTC1 gradient (3.x, S2 term) can read hundreds of ppm wrong" }
        else if Tn < tEnv.0 - 4 || Tn > tEnv.1 + 7 { rel = 2; why = String(format: "temperature %.1f C far outside the trained 22-33 C", Tn) }
        else if cn < gapUntil { rel = 1; why = "data gap (frames missing for > 30 s) just before: the fast terms can show a short transient for ~1 min" }
        else if dtq.count >= 30 && K96Math.median(Array(dtq.elements)) > 2.5 { rel = 1; why = String(format: "sampling slower than in training (%.1f s per frame vs ~1.2 s): the time constants of the models are stretched", K96Math.median(Array(dtq.elements))) }
        else if rate > K96Constants.rateMax { rel = 1; why = String(format: "temperature changing %.2f C / 5 min", rate) }
        else if Tn < tEnv.0 || Tn > tEnv.1 { rel = 1; why = String(format: "temperature %.1f C outside the trained 22-33 C", Tn) }
        else if ft { rel = 1; why = "flow changed in the last 90 min" }
        else if conf, let gz = gqZero,
                max(abs(K96Math.median(gq.elements.map(\.0)) - gz.0), abs(K96Math.median(gq.elements.map(\.1)) - gz.1)) > 0.25 {
            rel = 1; why = "flow state differs from the zero (gas / die - NTC1 moved > 0.25 C): the pump speed probably changed - readings can be offset by about -15..+60 ppm (training files, R2364 / R2393)"
        }
        else if st == "airshift" { rel = 1; why = "detector: shifted air state (models less reliable here)" }
        else if cnZero != nil && (TMax - TMin) > K96Constants.tRangeMax { rel = 1; why = String(format: "temperature changed %.1f C since the zero", TMax - TMin) }
        else { rel = 0; why = "ok" }

        if conf && spec.geo > 0 {
            let f2v = r.f2
            if f2z == nil { f2z = f2v; switchCnt = nil; f2Prev = f2v }
            if f2z! >= 300 && f2v < 60 && f2Prev >= 60 { switchCnt = cn }
            f2Prev = f2v
            switchNow = cn
        }
        return K96Output(
            cnt: cn, ppm: Self.display(raw), ppmRaw: raw, zeroed: conf, state: st,
            zeroOffsetPPM: i >= zoFrom ? zo : .nan, flowTransient: ft, bmeSuspect: bme, zeroSuspect: zsFlag,
            expectedAbsErrPPM: ee.isNaN ? ee : K96Math.round1(ee), opticsInvalid: optBad,
            tempRateCPer5Min: (rate * 100).rounded(.toNearestOrEven) / 100,
            reliability: rel, reliabilityReason: why
        )
    }

    static func display(_ x: Double) -> Double {
        if x.isNaN { return .nan }
        let y = max(x, 0.0)
        return y < 0.5 ? 0.0 : y
    }
}

// MARK: - Pooled linear models (k96_rt.LinStream / LinEnsStream, AIMNet_3.x)

/// One pooled linear model of the methane-free baseline change since the zero. The zero timing, the provisional reading
/// before the zero and every information column come from the base state-model stream (AIMNet_2.1 for 3.0-3.3).
nonisolated final class K96LinStream: K96ModelStream {
    static let linFeatures: Set<String> = ["w", "ws", "T", "Th33", "Th38", "Th43", "P", "gG", "gD", "af", "Ts", "Tf", "Tq", "Tqs", "Tsl"]

    private let base: K96Stream
    private let names: [String]
    private let coef: [Double]
    private var emaH: K96EMA, emaHS: K96EMA
    private var emaTS = K96EMA(span: 2945)
    private var emaTQ = K96EMA(span: 400)
    private var f2buf: [Double] = []
    private var lvl = 450.0
    private var ref: [Double]?
    private var B0: Double?
    private var zc: Double?
    private var zq = K96Ring<(Double, Double)>(capacity: 48)
    // AIMNet_3.3 ensemble (A = names / coef above, B = fixed pump response, C = A + squared gradient terms)
    private struct Ens {
        let namesC: [String]
        let coefC: [Double]
        let B: K96LinFile.PumpB
        let w: [Double]
        var eGqD: K96EMA, eGqG: K96EMA
        var eP: K96EMA, eGG: K96EMA, eGD: K96EMA, eLag: K96EMA
        var refC: [Double]?
        var cref: Double?
    }
    private var ens: Ens?

    init(model: K96LoadedModel, env: K96RuntimeSettings = .r33) {
        base = K96Stream(model: model, env: env)
        let lin = model.lin!
        let spans = lin.water_spans ?? [:]
        emaH = K96EMA(span: spans["w"] ?? 35)
        emaHS = K96EMA(span: spans["ws"] ?? 100)
        if let a = lin.A, let c = lin.C, let b = lin.B {
            names = a.names; coef = a.coef
            let sp = c.gq_span ?? 200
            ens = Ens(namesC: c.names, coefC: c.coef, B: b, w: lin.weights ?? [1.0 / 3, 1.0 / 3, 1.0 / 3],
                      eGqD: K96EMA(span: sp), eGqG: K96EMA(span: sp),
                      eP: K96EMA(span: b.SP), eGG: K96EMA(span: b.SP), eGD: K96EMA(span: b.SP), eLag: K96EMA(span: b.LAG))
        } else {
            names = lin.names!; coef = lin.coef!
        }
    }

    var hold: Bool { get { base.hold } set { base.hold = newValue } }
    var zeroStartIndex: Int? { base.zeroStartIndex }
    var zeroCounter: Double? { base.zeroCounter }
    var zeroValue: Double? { base.zeroValue }
    var ready: Bool { base.ready }
    var readyDetail: [String: Double] { base.readyDetail }
    var geo: Double { base.geo }
    var wphysZN2: Bool { base.wphysZN2 }
    var f2AtZeroStart: Double? { base.f2AtZeroStart }
    var switchCnt: Double? { base.switchCnt }
    var switchNow: Double { base.switchNow }

    private func feats(_ r: K96Frame, af: Double) -> [String: Double] {
        let T = r.T1b / 100.0
        let He = emaH(r.H2O), Hs = emaHS(r.H2O), Ts = emaTS(T), Tq = emaTQ(T)
        return ["w": He, "ws": Hs, "T": T, "Th33": max(T - 33.0, 0.0), "Th38": max(T - 38.0, 0.0), "Th43": max(T - 43.0, 0.0),
                "P": r.P / 10.0, "gG": r.T3 / 100.0 - T, "gD": r.T2 / 100.0 - T, "af": af, "Ts": Ts, "Tf": T - Ts,
                "Tq": (T - 36.0) * (T - 36.0), "Tqs": (Tq - 36.0) * (Tq - 36.0), "Tsl": Tq]
    }

    func push(_ r: K96Frame) -> K96Output {
        var o = base.push(r)
        let cn = r.cnt, v = r.f2
        if v > 300 {
            f2buf.append(v)
            if f2buf.count > 100 { f2buf.removeFirst(f2buf.count - 100) }
            if f2buf.count >= 50 { lvl = K96Math.median(f2buf) }
        }
        let af = min(max(v / lvl, 0.0), 1.0)
        let F = feats(r, af: af)
        let x = names.map { F[$0]! }
        let raw = r.CH4
        zq.append((cn, raw + 4.0 * af))
        if var e = ens {
            let T = r.T1b / 100.0, gD = r.T2 / 100.0 - T, gG = r.T3 / 100.0 - T, P = r.P / 10.0
            let hD = gD - e.eGqD(gD), hG = gG - e.eGqG(gG)
            var FC = Dictionary(uniqueKeysWithValues: zip(names, x))
            FC["gDq"] = copysign(hD * hD, hD)
            FC["gGq"] = copysign(hG * hG, hG)
            let xc = e.namesC.map { FC[$0]! }
            let Ph = P - e.eP(P), gGh = gG - e.eGG(gG), gDh = gD - e.eGD(gD)
            let gate = min(abs(gDh) / e.B.G0, 1.0)
            let lag = e.eLag(Ph)
            let c = gate * (e.B.CPH * lag - (coef[e.B.iP] * Ph + coef[e.B.iG] * gGh + coef[e.B.iD] * gDh))
            if o.zeroed {
                if ref == nil {
                    ref = x; e.refC = xc; e.cref = c; zc = cn
                    let zw = zq.elements.filter { zc! - 20.0 <= $0.0 && $0.0 < zc! }.map(\.1)
                    B0 = zw.isEmpty ? raw + 4.0 * af : K96Math.median(zw)
                }
                var yA = 0.0
                for (k, (xi, ri)) in zip(coef, zip(x, ref!)) { yA += k * (xi - ri) }
                var yC = 0.0
                for (k, (xi, ri)) in zip(e.coefC, zip(xc, e.refC!)) { yC += k * (xi - ri) }
                let yh = e.w[0] * yA + e.w[1] * (yA + c - e.cref!) + e.w[2] * yC
                let rd = (B0! + yh - raw) / 2.0
                o.ppmRaw = rd; o.ppm = K96Stream.display(rd)
            }
            ens = e
        } else if o.zeroed {
            if ref == nil {
                ref = x; zc = cn
                let zw = zq.elements.filter { zc! - 20.0 <= $0.0 && $0.0 < zc! }.map(\.1)
                B0 = zw.isEmpty ? raw + 4.0 * af : K96Math.median(zw)
            }
            var yh = 0.0
            for (k, (xi, ri)) in zip(coef, zip(x, ref!)) { yh += k * (xi - ri) }
            let rd = (B0! + yh - raw) / 2.0
            o.ppmRaw = rd; o.ppm = K96Stream.display(rd)
        }
        return o
    }
}

nonisolated func makeK96Stream(_ model: K96LoadedModel) -> K96ModelStream {
    model.isLinear ? K96LinStream(model: model) : K96Stream(model: model)
}

// MARK: - Several models for one device (k96_rt.MultiModel)

/// Runs the active models on each frame. A new power-on (device counter going back) restarts every model with a new zero;
/// a Bluetooth reconnect without a power cycle continues the same models (same zero).
///
/// The frames of the current power-on are kept (120 bytes each), so a model can be switched on at any time: it is built by
/// replaying those frames and then has exactly the state and zero it would have had from the start.
nonisolated final class K96MultiModel {
    let catalog: K96Catalog
    private(set) var activeKeys: [String] = []
    private var streams: [String: K96ModelStream] = [:]
    private var frames: [Double] = []
    /// (frame index, hold) changes of the manual-zero hold in this power-on, replayed with the frames.
    private var holdEvents: [(Int, Bool)] = []
    private var lastCnt: Double?
    private(set) var powerOnCount = 0
    private(set) var manualZero = false

    init(catalog: K96Catalog, active: [String]) {
        self.catalog = catalog
        activeKeys = catalog.keys.filter { active.contains($0) }
    }

    private var anyStream: K96ModelStream? { activeKeys.first.flatMap { streams[$0] } }
    var isZeroed: Bool { anyStream?.zeroValue != nil }
    var isReady: Bool { anyStream?.ready ?? false }
    var isHolding: Bool { anyStream.map { $0.hold && $0.zeroStartIndex == nil } ?? false }
    /// The 20-s zero window has started but the zero is not set yet.
    var isZeroing: Bool { anyStream.map { $0.zeroStartIndex != nil && $0.zeroValue == nil } ?? false }
    var readyDetail: [String: Double] { anyStream?.readyDetail ?? [:] }
    var zeroCount: Double? { anyStream?.zeroCounter }
    var framesInPowerOn: Int { frames.count / 15 }

    /// Manual mode holds the zero until `zeroNow()`; applies to streams that have not started their zero yet.
    func setZeroMode(manual: Bool) {
        manualZero = manual
        guard !streams.isEmpty, !streams.values.contains(where: { $0.zeroStartIndex != nil }) else { return }
        for s in streams.values { s.hold = manual }
        holdEvents.append((framesInPowerOn, manual))
    }

    /// Manual zero mode: release the hold so the next stable frame starts the one-time 20-s zero window.
    @discardableResult
    func zeroNow() -> Bool {
        guard !streams.isEmpty, !streams.values.contains(where: { $0.zeroStartIndex != nil }) else { return false }
        for s in streams.values { s.hold = false }
        holdEvents.append((framesInPowerOn, false))
        return true
    }

    /// Switch models on (replaying this power-on's frames) or off. Returns, for each newly built model, its outputs for the
    /// last `keepLast` frames of the replay (oldest first; the cross-model reliability notes are not added to these).
    @discardableResult
    func setActive(_ keys: [String], keepLast: Int = 1) -> [String: [K96Output]] {
        let wanted = catalog.keys.filter { keys.contains($0) }
        var last: [String: [K96Output]] = [:]
        for k in wanted where streams[k] == nil && !frames.isEmpty {
            guard let model = catalog.model(k) else { continue }
            let s = makeK96Stream(model)
            var ev = 0
            let n = framesInPowerOn
            var kept: [K96Output] = []
            kept.reserveCapacity(min(keepLast, n))
            for j in 0..<n {
                while ev < holdEvents.count && holdEvents[ev].0 == j { s.hold = holdEvents[ev].1; ev += 1 }
                let o = s.push(K96Frame(values: Array(frames[(j * 15)..<(j * 15 + 15)])))
                if j >= n - keepLast { kept.append(o) }
            }
            last[k] = kept
            while ev < holdEvents.count { s.hold = holdEvents[ev].1; ev += 1 }
            streams[k] = s
        }
        for k in streams.keys where !wanted.contains(k) { streams[k] = nil }
        activeKeys = wanted
        return last
    }

    /// Outputs of the active models, keyed by model key.
    func push(_ r: K96Frame) -> [String: K96Output] {
        if streams.isEmpty || (lastCnt != nil && r.cnt < lastCnt!) {
            streams = [:]
            for k in activeKeys { if let m = catalog.model(k) { streams[k] = makeK96Stream(m) } }
            for s in streams.values { s.hold = manualZero }
            frames = []
            holdEvents = [(0, manualZero)]
            powerOnCount += 1
        }
        lastCnt = r.cnt
        let ordered = activeKeys.compactMap { k in streams[k].map { (k, $0) } }
        var out: [String: K96Output] = [:]
        for (k, s) in ordered { out[k] = s.push(r) }
        frames.append(contentsOf: r.values)
        // R1758: inlet + room-air zero classified as a cold start -> no water correction (text only)
        for (k, s) in ordered {
            if s.geo > 0 && s.wphysZN2, let f = s.f2AtZeroStart, f >= 300, let o = out[k], o.zeroed, o.state == "bench" {
                for j in out.keys where !out[j]!.reliabilityReason.contains("humidity changes") {
                    out[j]!.reliabilityReason += "; inlet zero taken in room air in the cold-start state: humidity changes may read as methane (no water correction)"
                }
                break
            }
        }
        // R1927: inlet + room-air zero, then the gas switched to N2 in the last 90 min (level / text only)
        for (_, s) in ordered {
            if s.geo > 0, let sw = s.switchCnt, s.switchNow - sw < 5400 {
                for j in out.keys where out[j]!.reliability < 2 && !out[j]!.reliabilityReason.contains("gas switched") {
                    out[j]!.reliability = max(out[j]!.reliability, 1)
                    out[j]!.reliabilityReason = (out[j]!.reliabilityReason != "ok" ? out[j]!.reliabilityReason + "; " : "")
                        + "gas switched from room air (zero) to N2 in the last 90 min: inlet models can read +30..+80 ppm too high (AIMNet_1.7 / 2.1) or down to -30 ppm too low for ~30 min (2.3 / 2.4)"
                }
                break
            }
        }
        return out
    }
}
