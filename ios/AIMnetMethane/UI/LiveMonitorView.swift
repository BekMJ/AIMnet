import Foundation
import SwiftUI

struct LiveMonitorView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var sessionStore: SessionStore

    @State private var exportMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                telemetryCards
                timedSampleCard
                sessionCard
                readingsCard
            }
            .padding()
        }
        .navigationTitle("Live Monitor")
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

    private var statusCard: some View {
        GroupBox("Connection Status") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("State")
                    Spacer()
                    Text(bleManager.connectionState.rawValue.capitalized)
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Connected Time")
                    Spacer()
                    Text(durationLabel(bleManager.connectionDurationSec))
                        .monospacedDigit()
                }
                if bleManager.connectionState == .preparing {
                    ProgressView(
                        value: Double(bleManager.preparationTotalSeconds - bleManager.preparationSecondsLeft),
                        total: max(1, Double(bleManager.preparationTotalSeconds))
                    )
                    Text("Warmup: \(bleManager.preparationSecondsLeft)s remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(bleManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var telemetryCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "Methane (PPM)",
                value: bleManager.latestReading.map { String(format: "%.2f", $0.ppm) } ?? "--"
            )
            metricCard(
                title: "Methane Raw",
                value: bleManager.latestReading.map { String(format: "%.0f", $0.rawValue) } ?? "--"
            )
            metricCard(
                title: "Temperature",
                value: bleManager.temperatureData.last.map { String(format: "%.2f C", $0) } ?? "--"
            )
            metricCard(
                title: "Humidity",
                value: bleManager.humidityData.last.map { String(format: "%.2f %%", $0) } ?? "--"
            )
            metricCard(
                title: "Battery",
                value: bleManager.batteryLevel.map { "\($0)%" } ?? "--"
            )
            metricCard(
                title: "Samples",
                value: "\(bleManager.methanePPMData.count)"
            )
        }
    }

    private var timedSampleCard: some View {
        GroupBox("Timed Sampling Mode") {
            VStack(alignment: .leading, spacing: 8) {
                if bleManager.connectedPeripheral == nil {
                    Text("Connect a device to start timed methane samples.")
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink("Open Timed Sample Screen") {
                        TimedSampleView(bleManager: bleManager)
                    }
                    .buttonStyle(.borderedProminent)

                    if bleManager.isSampling {
                        Text("Active sample: \(bleManager.sampleSecondsLeft)s remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let sample = bleManager.lastTimedSample {
                        Text(
                            "Last sample: \(sample.readings.count) points, avg \(String(format: "%.2f", sample.averagePPM)) ppm"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        GroupBox(title) {
            HStack {
                Spacer()
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private var sessionCard: some View {
        GroupBox("Session") {
            VStack(alignment: .leading, spacing: 10) {
                if let active = sessionStore.activeSession {
                    Text("Active device: \(active.deviceName)")
                    Text("Readings buffered: \(active.readings.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("End Session") {
                        _ = sessionStore.endSession()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("No active session.")
                        .foregroundStyle(.secondary)
                }

                if let latest = sessionStore.recentSessions.first {
                    Divider()
                    Text("Last saved session: \(latest.deviceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export CSV") {
                            export(session: latest, format: .csv)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Export JSON") {
                            export(session: latest, format: .json)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var readingsCard: some View {
        GroupBox("Recent Readings") {
            let recent = Array(bleManager.liveReadings.suffix(25).reversed())
            if recent.isEmpty {
                Text("No methane readings yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { reading in
                    HStack {
                        Text(timeLabel(reading.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f ppm", reading.ppm))
                            .monospacedDigit()
                        Text("(raw \(String(format: "%.0f", reading.rawValue)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func export(session: MethaneMonitoringSession, format: SessionExportFormat) {
        do {
            let url = try sessionStore.export(session: session, format: format)
            exportMessage = "Exported \(format.rawValue.uppercased()) to \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
