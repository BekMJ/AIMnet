import Foundation

/// Writes every received telemetry line to `Documents/AIMnetMethane/Raw/<device> data <yyyy-MM-dd_HH-mm-ss>.csv`,
/// in the same format as the AIMNet Python UI's raw logger (no header; each row = local time to the second, then the
/// device tokens without the device-name prefix). These files can be run through `k96/run_file.py` unchanged, and the
/// app replays them to restore the methane model after a relaunch in the middle of a power-on.
nonisolated final class RawFrameLogger {
    let deviceName: String
    let url: URL
    private var handle: FileHandle?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AIMnetMethane/Raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func safeName(_ deviceName: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return deviceName.components(separatedBy: bad).joined(separator: "_")
    }

    init(deviceName: String, startedAt: Date = Date()) {
        self.deviceName = deviceName
        let dir = Self.directory()
        let stem = "\(Self.safeName(deviceName)) data \(Self.stampFormatter.string(from: startedAt))"
        var candidate = dir.appendingPathComponent(stem + ".csv")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) (\(n)).csv")
            n += 1
        }
        url = candidate
    }

    deinit { try? handle?.close() }

    func append(tokens: [String], at date: Date = Date()) {
        let line = ([Self.timeFormatter.string(from: date)] + tokens).joined(separator: ",") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // a full disk must not stop the live display; the next line tries again
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// Earlier raw files of this device written in the last `within` seconds, newest first.
    static func recentFiles(deviceName: String, excluding: URL?, within: TimeInterval = 24 * 3600) -> [URL] {
        let prefix = "\(safeName(deviceName)) data "
        let dir = directory()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let now = Date()
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "csv" && $0.standardizedFileURL != excluding?.standardizedFileURL }
            .compactMap { u -> (URL, Date)? in
                guard let d = try? u.resourceValues(forKeys: Set(keys)).contentModificationDate, now.timeIntervalSince(d) < within else { return nil }
                return (u, d)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// K96 frames of a raw file (same rule as `k96_rt.raw_frames`).
    static func frames(in url: URL) -> [K96Frame] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            K96Frame.parse(tokens: line.replacingOccurrences(of: "\0", with: "").split(separator: ",").map(String.init))
        }
    }
}

nonisolated enum K96Restore {
    /// Port of `k96_rt.restore_power_on`: after an app relaunch in the middle of a power-on, replay the frames of the CURRENT
    /// power-on from this device's earlier raw files (newest first), so the models keep the same zero and state.
    /// Returns the number of frames replayed and the files used.
    @discardableResult
    static func restorePowerOn(_ mm: K96MultiModel, candidates: [URL], firstCnt: Double, maxGapS: Double = 900) -> (Int, [URL]) {
        var chain: [(URL, ArraySlice<K96Frame>)] = []
        var next = firstCnt
        for p in candidates {
            let fr = RawFrameLogger.frames(in: p)
            guard let last = fr.last, last.cnt <= next, next - last.cnt <= maxGapS else { break }
            var k = fr.count - 1
            while k > 0 && fr[k - 1].cnt <= fr[k].cnt { k -= 1 }
            chain.insert((p, fr[k...]), at: 0)
            if k > 0 || fr[0].cnt < 60.0 { break }
            next = fr[0].cnt
        }
        var n = 0
        for (_, frames) in chain {
            for f in frames { _ = mm.push(f); n += 1 }
        }
        return (n, chain.map(\.0))
    }
}
