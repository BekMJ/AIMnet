import SwiftUI
import UIKit

/// Alarm levels for methane and H2S, and the warm-up notification.
struct AlertSettingsView: View {
    @ObservedObject var alerts: GasAlerts

    var body: some View {
        ZStack {
            FuturisticBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if alerts.notificationsAllowed == false {
                        FuturisticPanel("Notifications Off", icon: "bell.slash.fill") {
                            Text("iOS notifications are off for this app. Alarms still show on screen while the app is open, but not when the phone is locked.")
                                .font(.caption)
                                .foregroundStyle(FuturisticPalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(NeonButtonStyle(tint: FuturisticPalette.warning))
                        }
                    }

                    alarmPanel(
                        title: "Methane Alarm",
                        icon: "flame.fill",
                        enabled: $alerts.methaneEnabled,
                        threshold: $alerts.methaneThresholdPPM,
                        presets: [10, 50, 100, 500],
                        defaultValue: GasAlerts.defaultMethaneThresholdPPM,
                        note: "Checked only after warm-up (once the model is zeroed) and not on readings marked unreliable."
                    )

                    alarmPanel(
                        title: "H2S Alarm",
                        icon: "aqi.medium",
                        enabled: $alerts.h2sEnabled,
                        threshold: $alerts.h2sThresholdPPM,
                        presets: [5, 10, 15, 20],
                        defaultValue: GasAlerts.defaultH2SThresholdPPM,
                        note: "Uses the higher of the two H2S sensors. The H2S values are estimates from one reference point; for worker safety follow your site's limits and a certified detector."
                    )

                    FuturisticPanel("Warm-up", icon: "thermometer.medium") {
                        Toggle("Notify when methane readings are ready", isOn: $alerts.warmupNotify)
                            .tint(FuturisticPalette.cyan)
                            .foregroundStyle(.white)
                        Text("Sent once per power-on when the sensor has warmed up and taken its zero (in manual zero mode: when it is stable and ready for Start zero now).")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("An alarm starts after 2 readings in a row at or above the level, vibrates the phone and sends a notification with sound. It ends after 10 readings in a row below 80 % of the level.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Alarms")
    }

    private func alarmPanel(
        title: String,
        icon: String,
        enabled: Binding<Bool>,
        threshold: Binding<Double>,
        presets: [Double],
        defaultValue: Double,
        note: String
    ) -> some View {
        FuturisticPanel(title, icon: icon) {
            Toggle("Alarm on", isOn: enabled)
                .tint(FuturisticPalette.cyan)
                .foregroundStyle(.white)
            if enabled.wrappedValue {
                HStack {
                    Text("Alarm level")
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    TextField("ppm", value: threshold, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(maxWidth: 100)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                    Text("ppm")
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { p in
                        Button(GasAlerts.format(p)) { threshold.wrappedValue = p }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(threshold.wrappedValue == p ? FuturisticPalette.cyan.opacity(0.35) : .white.opacity(0.08)))
                            .foregroundStyle(.white)
                            .buttonStyle(.plain)
                    }
                    Spacer()
                }
                if threshold.wrappedValue <= 0 {
                    Text("Enter a level above 0 ppm; the alarm is inactive until then.")
                        .font(.caption2)
                        .foregroundStyle(FuturisticPalette.warning)
                }
                Text(note + " Default \(GasAlerts.format(defaultValue)) ppm.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
