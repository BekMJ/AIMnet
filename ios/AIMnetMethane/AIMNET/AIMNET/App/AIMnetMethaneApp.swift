import SwiftUI

@main
struct AIMnetMethaneApp: App {
    @StateObject private var sessionStore: SessionStore
    @StateObject private var bleManager: BLEManager
    private let screenshotScene: String?

    init() {
        let store = SessionStore()
        let manager = BLEManager(sessionStore: store)
        let environment = ProcessInfo.processInfo.environment
        screenshotScene = environment["AIMNET_SCREENSHOT_SCENE"]
        if environment["AIMNET_SCREENSHOT_DEMO"] != nil {
            store.loadScreenshotDemoData()
            manager.loadScreenshotDemoData(
                preferredDeviceType: environment["AIMNET_SCREENSHOT_DEVICE_TYPE"]
            )
        }
        _sessionStore = StateObject(wrappedValue: store)
        _bleManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            if let screenshotScene {
                ScreenshotSceneView(
                    scene: screenshotScene,
                    bleManager: bleManager,
                    sessionStore: sessionStore
                )
                .preferredColorScheme(.dark)
                .tint(FuturisticPalette.cyan)
            } else {
                NavigationSplitView {
                    DeviceListView(
                        bleManager: bleManager,
                        sessionStore: sessionStore
                    )
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
                } detail: {
                    NavigationStack {
                        LiveMonitorView(
                            bleManager: bleManager,
                            sessionStore: sessionStore
                        )
                    }
                }
                .preferredColorScheme(.dark)
                .tint(FuturisticPalette.cyan)
            }
        }
    }
}

private struct ScreenshotSceneView: View {
    let scene: String
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        if scene == "ipad-overview" {
            NavigationSplitView {
                DeviceListView(
                    bleManager: bleManager,
                    sessionStore: sessionStore,
                    initialPrivacyExpanded: false
                )
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            } detail: {
                NavigationStack {
                    LiveMonitorView(
                        bleManager: bleManager,
                        sessionStore: sessionStore,
                        initialScrollAnchor: "status"
                    )
                }
            }
        } else if scene == "sensors-privacy" {
            NavigationStack {
                DeviceListView(
                    bleManager: bleManager,
                    sessionStore: sessionStore,
                    initialPrivacyExpanded: true
                )
            }
        } else if scene == "sensors" {
            NavigationStack {
                DeviceListView(
                    bleManager: bleManager,
                    sessionStore: sessionStore,
                    initialPrivacyExpanded: false
                )
            }
        } else {
            NavigationStack {
                LiveMonitorView(
                    bleManager: bleManager,
                    sessionStore: sessionStore,
                    initialScrollAnchor: anchor(for: scene)
                )
            }
        }
    }

    private func anchor(for scene: String) -> String? {
        switch scene {
        case "live-status":
            return "status"
        case "raw-payload":
            return "raw"
        case "methane-metrics":
            return "methaneMetrics"
        case "methane-charts":
            return "methaneCharts"
        case "timed-sample":
            return "timedSample"
        case "h2s-metrics":
            return "h2sMetrics"
        case "h2s-charts":
            return "h2sCharts"
        case "session":
            return "session"
        default:
            return nil
        }
    }
}
