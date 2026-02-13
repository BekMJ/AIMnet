import Foundation
import SwiftUI

struct TimedSampleView: View {
    @ObservedObject var bleManager: BLEManager

    @AppStorage("timedSampleDurationSeconds") private var selectedDuration = BLEConstants.defaultTimedSampleDurationSeconds
    @State private var exportMessage: String?
    @State private var exportedCSVURL: URL?
    @State private var exportedJSONURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlsCard
                liveCard
                latestSampleCard
            }
            .padding()
        }
        .navigationTitle("Timed Methane Sample")
        .overlay(alignment: .bottom) {
            if let exportMessage {
                Text(exportMessage)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var controlsCard: some View {
        GroupBox("Sample Controls") {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: $selectedDuration, in: 5...600, step: 5) {
                    Text("Duration: \(selectedDuration)s")
                }
                .disabled(bleManager.isSampling)

                if bleManager.isPreparingBaseline {
                    Text("Warmup in progress: \(bleManager.preparationSecondsLeft)s remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if bleManager.isSampling {
                    ProgressView(
                        value: Double(bleManager.sampleDurationSeconds - bleManager.sampleSecondsLeft),
                        total: max(1, Double(bleManager.sampleDurationSeconds))
                    )
                    Text("Sampling: \(bleManager.sampleSecondsLeft)s left")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Stop Sample", role: .destructive) {
                        bleManager.stopTimedSample()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start \(selectedDuration)s Sample") {
                        bleManager.startTimedSample(durationSec: selectedDuration)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bleManager.connectedPeripheral == nil || bleManager.isPreparingBaseline)
                }
            }
        }
    }

    private var liveCard: some View {
        GroupBox("Live Telemetry During Sample") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current ppm: \(bleManager.latestReading.map { String(format: "%.2f", $0.ppm) } ?? "--")")
                Text("Current raw: \(bleManager.latestReading.map { String(format: "%.0f", $0.rawValue) } ?? "--")")
                Text("Temperature: \(bleManager.temperatureData.last.map { String(format: "%.2f C", $0) } ?? "--")")
                Text("Humidity: \(bleManager.humidityData.last.map { String(format: "%.2f %%", $0) } ?? "--")")
                Text("Sample points captured: \(bleManager.timedSampleReadings.count)")
            }
            .font(.caption)
        }
    }

    private var latestSampleCard: some View {
        GroupBox("Latest Timed Sample") {
            if let sample = bleManager.lastTimedSample {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Duration: \(Int(sample.durationSeconds))s (target \(sample.targetDurationSec)s)")
                        .font(.caption)
                    Text("Readings: \(sample.readings.count)")
                        .font(.caption)
                    Text("Average ppm: \(String(format: "%.2f", sample.averagePPM))")
                        .font(.caption)
                    Text("Min/Max ppm: \(String(format: "%.2f", sample.minPPM)) / \(String(format: "%.2f", sample.maxPPM))")
                        .font(.caption)

                    HStack {
                        Button("Export CSV") {
                            exportCSV(sample: sample)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Export JSON") {
                            exportJSON(sample: sample)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let exportedCSVURL {
                        ShareLink(item: exportedCSVURL) {
                            Text("Share CSV")
                        }
                    }
                    if let exportedJSONURL {
                        ShareLink(item: exportedJSONURL) {
                            Text("Share JSON")
                        }
                    }
                }
            } else {
                Text("No completed timed sample yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exportCSV(sample: MethaneTimedSample) {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("timestamp,rawValue,ppm,temperatureC,humidityRH,batteryPercent")
        for reading in sample.readings {
            let timestamp = formatter.string(from: reading.timestamp)
            let temperature = reading.temperatureC.map { String($0) } ?? ""
            let humidity = reading.humidityRH.map { String($0) } ?? ""
            let battery = reading.batteryPercent.map { String($0) } ?? ""
            lines.append("\(timestamp),\(reading.rawValue),\(reading.ppm),\(temperature),\(humidity),\(battery)")
        }

        let url = exportDirectory().appendingPathComponent("timed_sample_\(sample.id.uuidString).csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportedCSVURL = url
            exportMessage = "CSV exported: \(url.lastPathComponent)"
        } catch {
            exportMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func exportJSON(sample: MethaneTimedSample) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = exportDirectory().appendingPathComponent("timed_sample_\(sample.id.uuidString).json")

        do {
            let data = try encoder.encode(sample)
            try data.write(to: url, options: .atomic)
            exportedJSONURL = url
            exportMessage = "JSON exported: \(url.lastPathComponent)"
        } catch {
            exportMessage = "JSON export failed: \(error.localizedDescription)"
        }
    }

    private func exportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIMnetMethaneTimedSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
