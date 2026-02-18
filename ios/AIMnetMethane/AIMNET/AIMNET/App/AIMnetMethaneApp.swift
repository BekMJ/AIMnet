import SwiftUI

@main
struct AIMnetMethaneApp: App {
    @StateObject private var sessionStore: SessionStore
    @StateObject private var bleManager: BLEManager

    init() {
        let store = SessionStore()
        _sessionStore = StateObject(wrappedValue: store)
        _bleManager = StateObject(wrappedValue: BLEManager(sessionStore: store))
    }

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                DeviceListView(bleManager: bleManager)
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
