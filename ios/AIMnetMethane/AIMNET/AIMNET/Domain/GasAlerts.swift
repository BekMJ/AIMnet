import Combine
import Foundation
import UIKit
import UserNotifications

/// Display calibration of the H2S device's raw channels (a single reference point at 25 ppm per sensor).
nonisolated enum H2SDisplayCalibration {
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

/// Gas alarms (methane, H2S) and the "warm-up done" notification.
///
/// An alarm starts after 2 readings in a row at or above the threshold and ends after 10 readings in a row below 80 % of
/// it, so noise around the threshold does not make it flicker. Each start vibrates the phone and posts a notification
/// (shown as a banner with sound also while the app is open). Methane is checked only once the model is zeroed and its
/// reading is not marked unreliable.
final class GasAlerts: NSObject, ObservableObject {
    enum Gas: String {
        case methane = "Methane"
        case h2s = "H2S"
    }

    private enum Keys {
        static let methaneEnabled = "alerts.methane.enabled"
        static let methaneThreshold = "alerts.methane.thresholdPPM"
        static let h2sEnabled = "alerts.h2s.enabled"
        static let h2sThreshold = "alerts.h2s.thresholdPPM"
        static let warmupNotify = "alerts.warmup.notify"
    }

    static let defaultMethaneThresholdPPM = 50.0
    static let defaultH2SThresholdPPM = 10.0
    private static let triggerCount = 2
    private static let clearCount = 10
    private static let clearRatio = 0.8

    @Published var methaneEnabled: Bool { didSet { save(methaneEnabled, Keys.methaneEnabled); if methaneEnabled { requestPermissionIfNeeded() } else { methane = AlarmState() } } }
    @Published var methaneThresholdPPM: Double { didSet { save(methaneThresholdPPM, Keys.methaneThreshold) } }
    @Published var h2sEnabled: Bool { didSet { save(h2sEnabled, Keys.h2sEnabled); if h2sEnabled { requestPermissionIfNeeded() } else { h2s = AlarmState() } } }
    @Published var h2sThresholdPPM: Double { didSet { save(h2sThresholdPPM, Keys.h2sThreshold) } }
    @Published var warmupNotify: Bool { didSet { save(warmupNotify, Keys.warmupNotify); if warmupNotify { requestPermissionIfNeeded() } } }

    struct AlarmState: Equatable {
        var active = false
        var since: Date?
        /// Highest reading while the alarm is on.
        var peakPPM = 0.0
        fileprivate var above = 0
        fileprivate var below = 0
    }

    @Published private(set) var methane = AlarmState()
    @Published private(set) var h2s = AlarmState()
    @Published private(set) var notificationsAllowed: Bool?

    /// Off in the screenshot demo: alarm states still update, but nothing is posted or vibrated.
    var postsNotifications = true

    override init() {
        let d = UserDefaults.standard
        methaneEnabled = d.object(forKey: Keys.methaneEnabled) as? Bool ?? true
        methaneThresholdPPM = d.object(forKey: Keys.methaneThreshold) as? Double ?? Self.defaultMethaneThresholdPPM
        h2sEnabled = d.object(forKey: Keys.h2sEnabled) as? Bool ?? true
        h2sThresholdPPM = d.object(forKey: Keys.h2sThreshold) as? Double ?? Self.defaultH2SThresholdPPM
        warmupNotify = d.object(forKey: Keys.warmupNotify) as? Bool ?? true
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorization(ask: false) }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - Permission

    /// Asks for notification permission the first time (when a sensor starts streaming or an alert is switched on).
    func requestPermissionIfNeeded() {
        guard postsNotifications else { return }
        Task { await refreshAuthorization(ask: true) }
    }

    private func refreshAuthorization(ask: Bool) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && ask {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        switch status {
        case .authorized, .provisional, .ephemeral: notificationsAllowed = true
        case .denied: notificationsAllowed = false
        default: notificationsAllowed = nil
        }
    }

    // MARK: - Checks

    /// - Parameter usable: false while the model is not zeroed or marks the reading unreliable; such readings are skipped.
    func checkMethane(ppm: Double, usable: Bool) {
        guard methaneEnabled, usable, ppm.isFinite else { return }
        update(&methane, gas: .methane, ppm: ppm, threshold: methaneThresholdPPM)
    }

    func checkH2S(ppm: Double) {
        guard h2sEnabled, ppm.isFinite else { return }
        update(&h2s, gas: .h2s, ppm: ppm, threshold: h2sThresholdPPM)
    }

    /// Clears both alarms (sensor disconnected or data cleared).
    func resetAlarms() {
        methane = AlarmState()
        h2s = AlarmState()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Gas.methane.rawValue, Gas.h2s.rawValue])
    }

    private func update(_ state: inout AlarmState, gas: Gas, ppm: Double, threshold: Double) {
        guard threshold > 0 else { return }
        if state.active {
            state.peakPPM = max(state.peakPPM, ppm)
            if ppm < threshold * Self.clearRatio {
                state.below += 1
                if state.below >= Self.clearCount { state = AlarmState() }
            } else {
                state.below = 0
            }
            return
        }
        guard ppm >= threshold else {
            state.above = 0
            return
        }
        state.above += 1
        guard state.above >= Self.triggerCount else { return }
        state = AlarmState(active: true, since: Date(), peakPPM: ppm)
        alert(
            id: gas.rawValue,
            title: "\(gas.rawValue) alarm",
            body: String(format: "%@ at %.1f ppm (alarm level %@ ppm).", gas.rawValue, ppm, Self.format(threshold))
        )
        haptic(.warning)
    }

    // MARK: - Warm-up

    /// Methane model zeroed: readings are final from now on.
    func notifyWarmupDone(deviceName: String) {
        guard warmupNotify else { return }
        alert(id: "warmup", title: "Methane readings ready", body: "\(deviceName) finished warming up and is zeroed.")
        haptic(.success)
    }

    /// Manual zero mode: the sensor is stable and waits for "Start zero now".
    func notifyReadyForManualZero(deviceName: String) {
        guard warmupNotify else { return }
        alert(id: "warmup", title: "Ready to zero", body: "\(deviceName) is stable. Open the app and tap Start zero now (in gas without methane).")
        haptic(.success)
    }

    // MARK: - Delivery

    private func alert(id: String, title: String, body: String) {
        guard postsNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // the same id replaces an older notification of the same kind instead of stacking them
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard postsNotifications, UIApplication.shared.applicationState == .active else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func format(_ ppm: Double) -> String {
        ppm == ppm.rounded() ? String(format: "%.0f", ppm) : String(format: "%.1f", ppm)
    }
}

extension GasAlerts: UNUserNotificationCenterDelegate {
    /// Show alerts as a banner with sound also while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
