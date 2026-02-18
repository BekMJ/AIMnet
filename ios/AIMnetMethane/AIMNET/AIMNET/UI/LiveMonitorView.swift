import Charts
import Foundation
import SwiftUI

private struct ChartPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
}

struct LiveMonitorView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var sessionStore: SessionStore

    @State private var exportMessage: String?

    var body: some View {
        ZStack {
            FuturisticBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    rawPayloadCard

                    switch bleManager.detectedDeviceType {
                    case .methane:
                        methaneMetricsCard
                        methaneChartsCard
                        timedSampleCard
                    case .h2s:
                        h2sMetricsCard
                        h2sChartsCard
                    case .unknown:
                        awaitingTelemetryCard
                    }

                    sessionCard
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Live Monitor")
        .overlay(alignment: .bottom) {
            if let exportMessage {
                FuturisticToast(message: exportMessage)
                    .padding(.bottom, 10)
            }
        }
    }

    private var statusCard: some View {
        FuturisticPanel("Connection Status", icon: "wave.3.right.circle.fill") {
            HStack {
                Text("State")
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                StatusChip(
                    text: bleManager.connectionState.rawValue,
                    color: connectionStateColor
                )
            }

            HStack {
                Text("Detected Device")
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                StatusChip(
                    text: bleManager.detectedDeviceType.rawValue,
                    color: deviceTypeColor
                )
            }

            if let payloadDevice = bleManager.latestPayloadDeviceName, !payloadDevice.isEmpty {
                HStack {
                    Text("Payload Device")
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(payloadDevice)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }

            HStack {
                Text("Connected Time")
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(durationLabel(bleManager.connectionDurationSec))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            Text(bleManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var rawPayloadCard: some View {
        FuturisticPanel("Raw Telemetry Payload", icon: "text.alignleft") {
            if bleManager.latestRawPayload.isEmpty {
                Text("No payload received yet.")
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                Text(bleManager.latestRawPayload)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .overlay(.white.opacity(0.2))

                ForEach(Array(bleManager.latestRawFields.enumerated()), id: \.offset) { index, value in
                    HStack(spacing: 10) {
                        Text("[\(index)]")
                            .font(.caption.monospaced())
                            .foregroundStyle(FuturisticPalette.cyan)
                            .frame(width: 40, alignment: .leading)
                        Text(value)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var methaneMetricsCard: some View {
        FuturisticPanel("Methane Raw Fields", icon: "flame.fill") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                FuturisticMetricTile(
                    title: "Device Time",
                    value: bleManager.latestDeviceTime.map(String.init) ?? "--",
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "CH4 Signal",
                    value: metricValue(bleManager.latestCH4Signal),
                    accent: FuturisticPalette.success
                )
                FuturisticMetricTile(
                    title: "H2O Sensor 1",
                    value: metricValue(bleManager.latestH2OSensor1),
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "H2O Sensor 2",
                    value: metricValue(bleManager.latestH2OSensor2),
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "CO2 Sensor",
                    value: metricValue(bleManager.latestCO2Sensor),
                    accent: FuturisticPalette.warning
                )
                FuturisticMetricTile(
                    title: "Pressure (kPa)",
                    value: metricValue(bleManager.latestPressureKPa, format: "%.2f"),
                    accent: FuturisticPalette.purple
                )
                FuturisticMetricTile(
                    title: "Temp 1 (C)",
                    value: metricValue(bleManager.latestTemperature1C, format: "%.2f"),
                    accent: FuturisticPalette.magenta
                )
                FuturisticMetricTile(
                    title: "Temp 2 (C)",
                    value: metricValue(bleManager.latestTemperature2C, format: "%.2f"),
                    accent: FuturisticPalette.magenta
                )
                FuturisticMetricTile(
                    title: "Temp 3 (C)",
                    value: metricValue(bleManager.latestTemperature3C, format: "%.2f"),
                    accent: FuturisticPalette.magenta
                )
                FuturisticMetricTile(
                    title: "Temp 4 (C)",
                    value: metricValue(bleManager.latestTemperature4C, format: "%.2f"),
                    accent: FuturisticPalette.magenta
                )
                FuturisticMetricTile(
                    title: "Humidity (%RH)",
                    value: metricValue(bleManager.latestHumidityRH, format: "%.2f"),
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "H2O Signal",
                    value: metricValue(bleManager.latestH2OSignal),
                    accent: FuturisticPalette.purple
                )
                FuturisticMetricTile(
                    title: "CO2 Signal",
                    value: metricValue(bleManager.latestCO2Signal),
                    accent: FuturisticPalette.warning
                )
            }
        }
    }

    private var methaneChartsCard: some View {
        VStack(spacing: 12) {
            chartPanel(
                title: "CH4 Signal (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.methaneRawData,
                timestamps: bleManager.methaneTimestamps,
                tint: FuturisticPalette.success,
                height: 220
            )

            chartPanel(
                title: "Pressure (kPa)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.pressureKPaData,
                timestamps: bleManager.pressureTimestamps,
                tint: FuturisticPalette.purple,
                height: 170
            )

            chartPanel(
                title: "Temperature 1 (C)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.temperatureCData,
                timestamps: bleManager.temperatureTimestamps,
                tint: FuturisticPalette.magenta,
                height: 170
            )

            chartPanel(
                title: "Temperature 2 (C)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.temperature2CData,
                timestamps: bleManager.temperatureTimestamps,
                tint: FuturisticPalette.magenta,
                height: 170
            )

            chartPanel(
                title: "Temperature 3 (C)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.temperature3CData,
                timestamps: bleManager.temperatureTimestamps,
                tint: FuturisticPalette.magenta,
                height: 170
            )

            chartPanel(
                title: "Temperature 4 (C)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.temperature4CData,
                timestamps: bleManager.temperatureTimestamps,
                tint: FuturisticPalette.magenta,
                height: 170
            )

            chartPanel(
                title: "Humidity (%RH)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.humidityRHData,
                timestamps: bleManager.humidityTimestamps,
                tint: FuturisticPalette.cyan,
                height: 170
            )

            chartPanel(
                title: "H2O Sensor 1 (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.waterData,
                timestamps: bleManager.waterTimestamps,
                tint: FuturisticPalette.cyan,
                height: 170
            )

            chartPanel(
                title: "H2O Sensor 2 (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.waterSecondaryData,
                timestamps: bleManager.waterTimestamps,
                tint: FuturisticPalette.cyan,
                height: 170
            )

            chartPanel(
                title: "CO2 Sensor (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.co2Data,
                timestamps: bleManager.co2Timestamps,
                tint: FuturisticPalette.warning,
                height: 170
            )

            chartPanel(
                title: "H2O Signal (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.h2oSignalData,
                timestamps: bleManager.methaneTimestamps,
                tint: FuturisticPalette.purple,
                height: 170
            )

            chartPanel(
                title: "CO2 Signal (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.co2SignalData,
                timestamps: bleManager.methaneTimestamps,
                tint: FuturisticPalette.warning,
                height: 170
            )
        }
    }

    private var h2sMetricsCard: some View {
        FuturisticPanel("H2S Raw Fields", icon: "aqi.medium") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                FuturisticMetricTile(
                    title: "Device Time",
                    value: bleManager.latestDeviceTime.map(String.init) ?? "--",
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "H2S Sensor 1",
                    value: metricValue(bleManager.latestH2SPrimary),
                    accent: FuturisticPalette.warning
                )
                FuturisticMetricTile(
                    title: "H2S Sensor 2",
                    value: metricValue(bleManager.latestH2SSecondary),
                    accent: FuturisticPalette.magenta
                )
            }
        }
    }

    private var h2sChartsCard: some View {
        VStack(spacing: 12) {
            chartPanel(
                title: "H2S Sensor 1 (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.h2sPrimaryData,
                timestamps: bleManager.h2sTimestamps,
                tint: FuturisticPalette.warning,
                height: 170
            )

            chartPanel(
                title: "H2S Sensor 2 (Raw)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.h2sSecondaryData,
                timestamps: bleManager.h2sTimestamps,
                tint: FuturisticPalette.magenta,
                height: 170
            )
        }
    }

    private var awaitingTelemetryCard: some View {
        FuturisticPanel("Telemetry", icon: "waveform") {
            Text("Waiting for first payload to determine whether this is a methane or H2S device.")
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timedSampleCard: some View {
        FuturisticPanel("Timed Sampling", icon: "timer.circle.fill") {
            if bleManager.connectedPeripheral == nil {
                Text("Connect a methane device to start timed sampling.")
                    .foregroundStyle(.white.opacity(0.72))
            } else if bleManager.detectedDeviceType == .h2s {
                Text("Timed methane sampling is disabled for H2S devices.")
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                NavigationLink {
                    TimedSampleView(bleManager: bleManager)
                } label: {
                    Label("Open Timed Sample Screen", systemImage: "waveform.path.ecg.rectangle")
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.cyan))

                if bleManager.isSampling {
                    Text("Active sample: \(bleManager.sampleSecondsLeft)s remaining")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                } else if let sample = bleManager.lastTimedSample {
                    Text("Last sample: \(sample.readings.count) points, avg raw \(String(format: "%.2f", sample.averagePPM))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private var sessionCard: some View {
        FuturisticPanel("Session", icon: "internaldrive.fill") {
            if let active = sessionStore.activeSession {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active device: \(active.deviceName)")
                        .foregroundStyle(.white)
                    Text("Readings buffered: \(active.readings.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Button("End Session") {
                    _ = sessionStore.endSession()
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.warning))
            } else {
                Text("No active session.")
                    .foregroundStyle(.white.opacity(0.72))
            }

            if let latest = sessionStore.recentSessions.first {
                Divider()
                    .overlay(.white.opacity(0.2))

                Text("Last saved session: \(latest.deviceName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))

                HStack {
                    Button("Export CSV") {
                        export(session: latest, format: .csv)
                    }
                    .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.success))

                    Button("Export JSON") {
                        export(session: latest, format: .json)
                    }
                    .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.purple))
                }
            }
        }
    }

    private func chartPanel(
        title: String,
        icon: String,
        values: [Double],
        timestamps: [Date],
        tint: Color,
        height: CGFloat
    ) -> some View {
        let points = chartPoints(values: values, timestamps: timestamps)
        let yDomain = autoYDomain(for: points)
        return FuturisticPanel(title, icon: icon) {
            if points.isEmpty {
                Text("No data yet.")
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                    .lineStyle(.init(lineWidth: 2))

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint.opacity(0.3), tint.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.12))
                        AxisTick()
                            .foregroundStyle(.white.opacity(0.5))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.12))
                        AxisTick()
                            .foregroundStyle(.white.opacity(0.5))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .chartYScale(domain: yDomain)
                .frame(height: height)
            }
        }
    }

    private func chartPoints(
        values: [Double],
        timestamps: [Date],
        limit: Int = 180
    ) -> [ChartPoint] {
        let count = min(values.count, timestamps.count)
        guard count > 0 else { return [] }

        let start = max(0, count - limit)
        return (start..<count).map { index in
            ChartPoint(
                id: index,
                timestamp: timestamps[index],
                value: values[index]
            )
        }
    }

    private func autoYDomain(for points: [ChartPoint]) -> ClosedRange<Double> {
        guard let minValue = points.map(\.value).min(),
              let maxValue = points.map(\.value).max() else {
            return 0...1
        }

        if minValue == maxValue {
            let padding = max(abs(minValue) * 0.02, 1)
            return (minValue - padding)...(maxValue + padding)
        }

        let span = maxValue - minValue
        let padding = max(span * 0.10, 0.01)
        return (minValue - padding)...(maxValue + padding)
    }

    private func metricValue(_ value: Double?, format: String = "%.0f") -> String {
        guard let value else { return "--" }
        return String(format: format, value)
    }

    private var connectionStateColor: Color {
        switch bleManager.connectionState {
        case .streaming:
            return FuturisticPalette.success
        case .failed, .disconnected, .signalTimeout:
            return FuturisticPalette.danger
        case .connecting, .scanning:
            return FuturisticPalette.warning
        case .idle:
            return FuturisticPalette.cyan
        }
    }

    private var deviceTypeColor: Color {
        switch bleManager.detectedDeviceType {
        case .methane:
            return FuturisticPalette.success
        case .h2s:
            return FuturisticPalette.warning
        case .unknown:
            return FuturisticPalette.cyan
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
}
