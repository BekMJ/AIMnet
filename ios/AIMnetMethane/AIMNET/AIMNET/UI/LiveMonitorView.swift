import Charts
import Foundation
import SwiftUI
import UIKit

private struct ChartPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
}

nonisolated private enum H2SDisplayCalibration {
    static let sensor1RawAt25PPM = 40_000.0
    static let sensor2RawAt25PPM = 10_000.0
    static let referencePPM = 25.0

    static func sensor1PPM(fromRaw raw: Double) -> Double {
        max(0, raw * referencePPM / sensor1RawAt25PPM)
    }

    static func sensor2PPM(fromRaw raw: Double) -> Double {
        max(0, raw * referencePPM / sensor2RawAt25PPM)
    }
}

struct LiveMonitorView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var sessionStore: SessionStore
    var initialScrollAnchor: String? = nil

    @State private var exportMessage: String?
    @State private var pendingShareExport: ShareExport?

    var body: some View {
        ZStack {
            FuturisticBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard
                            .id("status")
                        rawPayloadCard
                            .id("raw")

                        switch bleManager.detectedDeviceType {
                        case .methane:
                            methaneModelCard
                                .id("methaneModel")
                            methaneSetupCard
                                .id("methaneSetup")
                            methaneMetricsCard
                                .id("methaneMetrics")
                            methaneChartsCard
                                .id("methaneCharts")
                            timedSampleCard
                                .id("timedSample")
                        case .h2s:
                            h2sMetricsCard
                                .id("h2sMetrics")
                            h2sChartsCard
                                .id("h2sCharts")
                        case .unknown:
                            awaitingTelemetryCard
                                .id("telemetry")
                        }

                        sessionCard
                            .id("session")
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    guard let initialScrollAnchor else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        proxy.scrollTo(initialScrollAnchor, anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("Live Monitor")
        .overlay(alignment: .bottom) {
            if let exportMessage {
                FuturisticToast(message: exportMessage)
                    .padding(.bottom, 10)
            }
        }
        .sheet(item: $pendingShareExport) { export in
            ActivityView(activityItems: [export.url])
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

    private var methaneModelCard: some View {
        let out = bleManager.latestModelOutput
        let status = bleManager.modelStatus
        return FuturisticPanel("Methane (K96 model)", icon: "flame.fill") {
            if let error = bleManager.modelLoadError {
                Text("Methane model not loaded: \(error)")
                    .font(.caption)
                    .foregroundStyle(FuturisticPalette.danger)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(out.map { String(format: "%.1f", $0.ppm) } ?? "--")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(reliabilityColor(out?.reliability))
                    Text("ppm CH4 · \(bleManager.displayedModelLabel)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                StatusChip(text: readinessText(out: out, status: status), color: reliabilityColor(out?.reliability))
            }

            if let out {
                Text(out.reliabilityReason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    FuturisticMetricTile(
                        title: "Not clipped (ppm)",
                        value: String(format: "%.1f", out.ppmRaw),
                        accent: FuturisticPalette.cyan
                    )
                    FuturisticMetricTile(
                        title: "Expected error (ppm)",
                        value: out.expectedAbsErrPPM.isNaN ? "--" : String(format: "±%.1f", out.expectedAbsErrPPM),
                        accent: FuturisticPalette.purple
                    )
                    FuturisticMetricTile(
                        title: "Detector state",
                        value: stateLabel(out.state),
                        accent: FuturisticPalette.magenta
                    )
                    FuturisticMetricTile(
                        title: "Zero",
                        value: status.zeroed ? "at \(Int(status.zeroCounter ?? 0)) s" : (status.holding ? "waiting" : "not yet"),
                        accent: FuturisticPalette.success
                    )
                }
                Text("Readings below 0.5 ppm show as 0; small concentrations show only in the not-clipped value. One zero per power-on, taken after warm-up and never changed.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for the first methane frame.")
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var methaneSetupCard: some View {
        FuturisticPanel("Methane Model Setup", icon: "slider.horizontal.3") {
            NavigationLink {
                K96ModelPickerView(bleManager: bleManager)
            } label: {
                HStack {
                    Text("Model")
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(bleManager.selectedModelKey == BLEManager.automaticModelKey ? "Auto (\(bleManager.displayedModelKey))" : bleManager.displayedModelKey)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if bleManager.displayedModelMismatchesTube {
                Text("\(bleManager.displayedModelKey) was trained for the tube \(bleManager.tubeAtInlet ? "at the old position" : "at the device inlet"), but the setting below says \(bleManager.tubeAtInlet ? "at the device inlet" : "old position"). Its reading can be off by tens to hundreds of ppm.")
                    .font(.caption)
                    .foregroundStyle(FuturisticPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Sample tube", selection: $bleManager.tubeAtInlet) {
                Text("At device inlet").tag(true)
                Text("Old position").tag(false)
            }
            .pickerStyle(.segmented)
            Text("Must match the real installation: with the wrong setting the reading can be off by tens to hundreds of ppm. If unsure, use Old position.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Manual zero", isOn: $bleManager.manualZero)
                .tint(FuturisticPalette.cyan)
                .foregroundStyle(.white)
            if bleManager.manualZero {
                Button("Start zero now") {
                    bleManager.startZeroNow()
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.success))
                .disabled(!bleManager.modelStatus.ready || bleManager.modelStatus.zeroed)
                Text("Start the zero with the pump already at the speed you will use, in gas without methane, and do not change the pump speed afterwards.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            let d = bleManager.modelStatus.detail
            if !d.isEmpty && !bleManager.modelStatus.zeroed {
                Text(String(format: "Stability: dT %.2f C / 5 min (< 0.5), dH2O %.0f / 2 min (< 150), df2 %.0f / 2 min (< 20), %.1f min since power-on (>= 5)",
                            d["dT_5min"] ?? .nan, d["dH2O_2min"] ?? .nan, d["df2_2min"] ?? .nan, d["min_since_start"] ?? .nan))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var methaneMetricsCard: some View {
        let f = bleManager.latestFrame
        return FuturisticPanel("Methane Sensor Channels", icon: "list.bullet.rectangle") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                FuturisticMetricTile(title: "Device counter (s)", value: metricValue(f?.cnt), accent: FuturisticPalette.cyan)
                FuturisticMetricTile(title: "Optical CH4", value: metricValue(f?.CH4), accent: FuturisticPalette.success)
                FuturisticMetricTile(title: "Optical H2O", value: metricValue(f?.H2O), accent: FuturisticPalette.cyan)
                FuturisticMetricTile(title: "Optical CO2", value: metricValue(f?.CO2), accent: FuturisticPalette.warning)
                FuturisticMetricTile(title: "NTC1 (C)", value: metricValue(f?.ntc1C, format: "%.2f"), accent: FuturisticPalette.magenta)
                FuturisticMetricTile(title: "Gas temp T3 (C)", value: metricValue(f?.gasC, format: "%.2f"), accent: FuturisticPalette.magenta)
                FuturisticMetricTile(title: "Die temp T2 (C)", value: metricValue(f?.dieC, format: "%.2f"), accent: FuturisticPalette.magenta)
                FuturisticMetricTile(title: "T1 (C)", value: metricValue(f?.temperature1C, format: "%.2f"), accent: FuturisticPalette.magenta)
                FuturisticMetricTile(title: "Pressure (hPa)", value: metricValue(f?.pressureHPa, format: "%.1f"), accent: FuturisticPalette.purple)
                FuturisticMetricTile(title: "Humidity (%RH)", value: metricValue(f?.humidityRH, format: "%.2f"), accent: FuturisticPalette.cyan)
                FuturisticMetricTile(title: "Firmware f1", value: metricValue(f?.f1), accent: FuturisticPalette.purple)
                FuturisticMetricTile(title: "Firmware f2 (CO2 ch.)", value: metricValue(f?.f2), accent: FuturisticPalette.warning)
                FuturisticMetricTile(title: "Firmware f3 (water)", value: metricValue(f?.f3), accent: FuturisticPalette.cyan)
            }
        }
    }

    private var methaneChartsCard: some View {
        let ts = bleManager.methaneTimestamps
        return VStack(spacing: 12) {
            chartPanel(title: "CH4 (ppm, \(bleManager.displayedModelKey))", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.methanePPMData, timestamps: ts, tint: FuturisticPalette.success, height: 220)
            chartPanel(title: "CH4 not clipped (ppm)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.methanePPMRawData, timestamps: ts, tint: FuturisticPalette.cyan, height: 170)
            chartPanel(title: "Optical CH4 (counts)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.methaneRawData, timestamps: ts, tint: FuturisticPalette.success, height: 170)
            chartPanel(title: "NTC1 (C)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.ntc1CData, timestamps: ts, tint: FuturisticPalette.magenta, height: 170)
            chartPanel(title: "Gas temperature T3 (C)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.gasCData, timestamps: ts, tint: FuturisticPalette.magenta, height: 170)
            chartPanel(title: "Die temperature T2 (C)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.dieCData, timestamps: ts, tint: FuturisticPalette.magenta, height: 170)
            chartPanel(title: "Pressure (hPa)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.pressureHPaData, timestamps: ts, tint: FuturisticPalette.purple, height: 170)
            chartPanel(title: "Humidity (%RH)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.humidityRHData, timestamps: ts, tint: FuturisticPalette.cyan, height: 170)
            chartPanel(title: "Optical H2O (counts)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.opticalH2OData, timestamps: ts, tint: FuturisticPalette.cyan, height: 170)
            chartPanel(title: "Optical CO2 (counts)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.opticalCO2Data, timestamps: ts, tint: FuturisticPalette.warning, height: 170)
            chartPanel(title: "Firmware f2 (CO2 channel)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.f2Data, timestamps: ts, tint: FuturisticPalette.warning, height: 170)
            chartPanel(title: "Firmware f3 (water)", icon: "chart.line.uptrend.xyaxis",
                       values: bleManager.f3Data, timestamps: ts, tint: FuturisticPalette.cyan, height: 170)
        }
    }

    private func reliabilityColor(_ level: Int?) -> Color {
        switch level {
        case 0: return FuturisticPalette.success
        case 1: return FuturisticPalette.warning
        case 2: return FuturisticPalette.danger
        default: return FuturisticPalette.cyan
        }
    }

    private func readinessText(out: K96Output?, status: MethaneModelStatus) -> String {
        guard let out else { return "NO DATA" }
        if !out.zeroed {
            if status.holding { return status.ready ? "READY - START ZERO" : "NOT READY" }
            return status.ready ? "ZEROING" : "WARMING UP"
        }
        switch out.reliability {
        case 0: return "READY"
        case 1: return "CAUTION"
        default: return "NOT USABLE"
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "bench": return "cold start"
        case "n2shift": return "hot restart"
        case "airshift": return "shifted air"
        default: return state
        }
    }

    private var h2sMetricsCard: some View {
        FuturisticPanel("H2S Estimated PPM", icon: "aqi.medium") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                FuturisticMetricTile(
                    title: "Device Time",
                    value: bleManager.latestDeviceTime.map(String.init) ?? "--",
                    accent: FuturisticPalette.cyan
                )
                FuturisticMetricTile(
                    title: "H2S Sensor 1 PPM",
                    value: metricValue(
                        bleManager.latestH2SPrimary.map(H2SDisplayCalibration.sensor1PPM),
                        format: "%.2f"
                    ),
                    accent: FuturisticPalette.warning
                )
                FuturisticMetricTile(
                    title: "H2S Sensor 2 PPM",
                    value: metricValue(
                        bleManager.latestH2SSecondary.map(H2SDisplayCalibration.sensor2PPM),
                        format: "%.2f"
                    ),
                    accent: FuturisticPalette.magenta
                )
            }
        }
    }

    private var h2sChartsCard: some View {
        VStack(spacing: 12) {
            chartPanel(
                title: "H2S Sensor 1 (PPM)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.h2sPrimaryData.map(H2SDisplayCalibration.sensor1PPM),
                timestamps: bleManager.h2sTimestamps,
                tint: FuturisticPalette.warning,
                height: 170
            )

            chartPanel(
                title: "H2S Sensor 2 (PPM)",
                icon: "chart.line.uptrend.xyaxis",
                values: bleManager.h2sSecondaryData.map(H2SDisplayCalibration.sensor2PPM),
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
                    Text("Last sample: \(sample.readings.count) points, average \(String(format: "%.1f", sample.averagePPM)) ppm")
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
                    Text("Readings buffered: \(sessionStore.activeReadingCount)")
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

            if let rawURL = bleManager.currentRawLogURL {
                Button("Share raw log (for k96/run_file.py)") {
                    pendingShareExport = ShareExport(url: rawURL)
                }
                .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.cyan))
            }

            if let latest = sessionStore.recentSessions.first {
                Divider()
                    .overlay(.white.opacity(0.2))

                Text("Last saved session: \(latest.deviceName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))

                HStack {
                    Button("Share CSV") {
                        share(session: latest, format: .csv)
                    }
                    .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.success))

                    Button("Share JSON") {
                        share(session: latest, format: .json)
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
                .chartPlotStyle { plotArea in
                    plotArea
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
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

    private func share(session: MethaneMonitoringSession, format: SessionExportFormat) {
        do {
            let url = try sessionStore.export(session: session, format: format)
            pendingShareExport = ShareExport(url: url)
            exportMessage = "Choose where to share \(url.lastPathComponent)"
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

private struct ShareExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
