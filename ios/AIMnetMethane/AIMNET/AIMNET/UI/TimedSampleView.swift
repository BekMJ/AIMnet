import Foundation
import SwiftUI

struct TimedSampleView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("timedSampleDurationSeconds") private var selectedDuration = BLEConstants.defaultTimedSampleDurationSeconds
    @State private var exportMessage: String?
    @State private var exportedCSVURL: URL?
    @State private var exportedJSONURL: URL?

    var body: some View {
        ZStack {
            FuturisticBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controlsCard
                    liveCard
                    latestSampleCard
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Timed Methane Sample")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let exportMessage {
                FuturisticToast(message: exportMessage)
                    .padding(.bottom, 10)
            }
        }
    }

    private var controlsCard: some View {
        FuturisticPanel("Sample Controls", icon: "slider.horizontal.3") {
            if bleManager.detectedDeviceType == .h2s {
                Text("Timed methane sampling is unavailable for H2S devices.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Stepper(value: $selectedDuration, in: 5...600, step: 5) {
                Text("Duration: \(selectedDuration)s")
                    .foregroundStyle(.white)
            }
            .disabled(bleManager.isSampling)
            .tint(FuturisticPalette.cyan)

            if bleManager.isSampling {
                ProgressView(
                    value: Double(bleManager.sampleDurationSeconds - bleManager.sampleSecondsLeft),
                    total: max(1, Double(bleManager.sampleDurationSeconds))
                )
                .tint(FuturisticPalette.cyan)

                Text("Sampling: \(bleManager.sampleSecondsLeft)s left")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))

                Button("Stop Sample") {
                    bleManager.stopTimedSample()
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.danger))
            } else {
                Button("Start \(selectedDuration)s Sample") {
                    bleManager.startTimedSample(durationSec: selectedDuration)
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.success))
                .disabled(bleManager.connectedPeripheral == nil || bleManager.detectedDeviceType == .h2s)
            }
        }
    }

    private var liveCard: some View {
        FuturisticPanel("Live Telemetry During Sample", icon: "waveform.path.ecg") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FuturisticMetricTile(
                    title: "Current CH4 (ppm)",
                    value: bleManager.latestModelOutput.map { String(format: "%.1f", $0.ppm) } ?? "--",
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "Optical CH4",
                    value: bleManager.latestFrame.map { String(format: "%.0f", $0.CH4) } ?? "--",
                    accent: FuturisticPalette.purple
                )
                FuturisticMetricTile(
                    title: "NTC1 (C)",
                    value: bleManager.latestFrame.map { String(format: "%.2f", $0.ntc1C) } ?? "--",
                    accent: FuturisticPalette.magenta
                )
                FuturisticMetricTile(
                    title: "Reliability",
                    value: bleManager.latestModelOutput.map { ["ok", "caution", "unreliable"][min(max($0.reliability, 0), 2)] } ?? "--",
                    accent: FuturisticPalette.cyan
                )
            }

            Text("Sample points captured: \(bleManager.timedSampleReadings.count)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var latestSampleCard: some View {
        FuturisticPanel("Latest Timed Sample", icon: "clock.arrow.circlepath") {
            if let sample = bleManager.lastTimedSample {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow(
                        title: "Duration",
                        value: "\(Int(sample.durationSeconds))s (target \(sample.targetDurationSec)s)"
                    )
                    detailRow(title: "Readings", value: "\(sample.readings.count)")
                    detailRow(title: "Average CH4 (ppm)", value: String(format: "%.1f", sample.averagePPM))
                    detailRow(
                        title: "Min / Max (ppm)",
                        value: "\(String(format: "%.1f", sample.minPPM)) / \(String(format: "%.1f", sample.maxPPM))"
                    )
                    if !sample.allReliable {
                        Text("Some readings were not zeroed or not at reliability 0 - read with care.")
                            .font(.caption)
                            .foregroundStyle(FuturisticPalette.warning)
                    }
                }

                HStack {
                    Button("Export CSV") {
                        exportCSV(sample: sample)
                    }
                    .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.success))

                    Button("Export JSON") {
                        exportJSON(sample: sample)
                    }
                    .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.purple))
                }

                HStack {
                    if let exportedCSVURL {
                        ShareLink(item: exportedCSVURL) {
                            Label("Share CSV", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.cyan))
                    }
                    if let exportedJSONURL {
                        ShareLink(item: exportedJSONURL) {
                            Label("Share JSON", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.magenta))
                    }
                }
            } else {
                Text("No completed timed sample yet.")
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    private func exportCSV(sample: MethaneTimedSample) {
        let csv = MethaneExport.csv(readings: sample.readings)
        let url = exportDirectory().appendingPathComponent("timed_sample_\(sample.id.uuidString).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportedCSVURL = url
            exportMessage = "CSV exported: \(url.lastPathComponent)"
        } catch {
            exportMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func exportJSON(sample: MethaneTimedSample) {
        let encoder = MethaneExport.jsonEncoder()
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AIMnetMethaneTimedSamples",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
