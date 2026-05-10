import CoreBluetooth
import SwiftUI
import UIKit

struct DeviceListView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var sessionStore: SessionStore
    var initialPrivacyExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var showBluetoothAlert = false
    @State private var bluetoothAlertMessage = ""
    @State private var lastBluetoothState: CBManagerState = .unknown
    @State private var showPrivacyLinks: Bool

    init(
        bleManager: BLEManager,
        sessionStore: SessionStore,
        initialPrivacyExpanded: Bool = false
    ) {
        self.bleManager = bleManager
        self.sessionStore = sessionStore
        self.initialPrivacyExpanded = initialPrivacyExpanded
        _showPrivacyLinks = State(initialValue: initialPrivacyExpanded)
    }

    var body: some View {
        ZStack {
            FuturisticBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bluetoothScanButton
                    if horizontalSizeClass == .compact {
                        liveMonitorNavigationButton
                    }
                    nearbySensorsPanel
                    privacyAndSupportPanel
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Sensors")
        .onReceive(bleManager.$bluetoothState) { state in
            if (state == .poweredOff || state == .unauthorized) &&
                !showBluetoothAlert &&
                lastBluetoothState != state {
                if state == .poweredOff {
                    bluetoothAlertMessage = "Bluetooth is currently off. Turn Bluetooth on in Control Center or Settings to scan and connect sensors."
                } else {
                    bluetoothAlertMessage = "Bluetooth access is denied. Enable Bluetooth permission for this app in Settings."
                }
                showBluetoothAlert = true
            }

            if (state == .poweredOn || state == .resetting) && showBluetoothAlert {
                showBluetoothAlert = false
            }
            lastBluetoothState = state
        }
        .alert("Bluetooth Required", isPresented: $showBluetoothAlert) {
            if bleManager.bluetoothState == .unauthorized {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(bluetoothAlertMessage)
        }
    }

    private var liveMonitorNavigationButton: some View {
        NavigationLink {
            LiveMonitorView(
                bleManager: bleManager,
                sessionStore: sessionStore
            )
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(FuturisticPalette.success.opacity(0.20))
                        .frame(width: 46, height: 46)

                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Live Monitor")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(liveMonitorSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FuturisticPalette.success.opacity(0.46),
                                FuturisticPalette.cyan.opacity(0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(FuturisticPalette.success.opacity(0.86), lineWidth: 1.2)
            )
            .shadow(color: FuturisticPalette.success.opacity(0.26), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Live Monitor")
        .accessibilityHint(liveMonitorSubtitle)
    }

    private var bluetoothScanButton: some View {
        Button(action: handleScanButtonTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(scanButtonTint.opacity(0.20))
                        .frame(width: 46, height: 46)

                    if bleManager.isScanning {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: scanButtonIcon)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(scanButtonTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(scanButtonSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                scanButtonTint.opacity(0.55),
                                FuturisticPalette.purple.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(scanButtonTint.opacity(0.95), lineWidth: 1.2)
            )
            .shadow(color: scanButtonTint.opacity(bleManager.isScanning ? 0.48 : 0.30), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!scanButtonIsEnabled)
        .opacity(scanButtonIsEnabled ? 1.0 : 0.62)
        .accessibilityLabel(scanButtonTitle)
        .accessibilityHint(scanButtonSubtitle)
    }

    private var nearbySensorsPanel: some View {
        FuturisticPanel("Nearby Sensors", icon: "antenna.radiowaves.left.and.right") {
            if bleManager.discoveredPeripherals.isEmpty {
                HStack(spacing: 10) {
                    if bleManager.isScanning {
                        ProgressView()
                            .tint(FuturisticPalette.cyan)
                    }
                    Text(bleManager.isScanning ? "Scanning for sensor signatures..." : "No devices found yet.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(8)
            } else {
                VStack(spacing: 10) {
                    ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        sensorRow(peripheral)
                    }
                }
            }
        }
    }

    private var privacyAndSupportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showPrivacyLinks.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FuturisticPalette.cyan)

                    Text("Privacy & Support")
                        .font(.caption.weight(.semibold))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.75))

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .rotationEffect(.degrees(showPrivacyLinks ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(FuturisticPalette.cyan.opacity(0.34), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showPrivacyLinks {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Readings stay on this device unless you choose to share an export.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    linkButton(
                        title: "Privacy Policy",
                        subtitle: AppLinks.privacyPolicy.absoluteString,
                        icon: "lock.shield.fill",
                        url: AppLinks.privacyPolicy
                    )

                    linkButton(
                        title: "Support",
                        subtitle: AppLinks.support.absoluteString,
                        icon: "questionmark.circle.fill",
                        url: AppLinks.support
                    )
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(FuturisticPalette.purple.opacity(0.34), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func linkButton(title: String, subtitle: String, icon: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FuturisticPalette.cyan)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.70))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sensorRow(_ peripheral: CBPeripheral) -> some View {
        let isConnected = bleManager.connectedPeripheral?.identifier == peripheral.identifier

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peripheral.name ?? "Unnamed sensor")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(peripheral.identifier.uuidString)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))

                if let advSerial = bleManager.advertisementSerials[peripheral.identifier] {
                    Text("ADV Serial: \(advSerial)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }

                if let info = bleManager.advertisedInfoByPeripheral[peripheral.identifier],
                   let major = info.versionMajor,
                   let minor = info.versionMinor {
                    Text("ADV FW: v\(major).\(minor)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }

                if isConnected {
                    StatusChip(text: "Connected", color: FuturisticPalette.success)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    bleManager.disconnect()
                } else {
                    bleManager.connect(peripheral)
                }
            }
            .buttonStyle(NeonButtonStyle(tint: isConnected ? FuturisticPalette.danger : FuturisticPalette.success))
            .disabled(
                bleManager.connectionState == .connecting ||
                    (!isConnected && bleManager.connectedPeripheral != nil &&
                        bleManager.connectedPeripheral?.identifier != peripheral.identifier)
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FuturisticPalette.cyan.opacity(0.30), lineWidth: 1)
        )
    }

    private var scanButtonIsEnabled: Bool {
        switch bleManager.bluetoothState {
        case .poweredOn, .poweredOff, .unauthorized:
            return true
        case .unknown, .resetting, .unsupported:
            return false
        @unknown default:
            return false
        }
    }

    private var scanButtonIcon: String {
        switch bleManager.bluetoothState {
        case .poweredOff, .unauthorized:
            return "bluetooth.slash"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        default:
            return bleManager.isScanning ? "stop.circle.fill" : "dot.radiowaves.left.and.right"
        }
    }

    private var scanButtonTint: Color {
        if bleManager.isScanning {
            return FuturisticPalette.warning
        }

        switch bleManager.bluetoothState {
        case .poweredOff, .unauthorized, .unsupported:
            return FuturisticPalette.danger
        default:
            return FuturisticPalette.cyan
        }
    }

    private var scanButtonTitle: String {
        if bleManager.isScanning {
            return "Stop Bluetooth Scan"
        }

        switch bleManager.bluetoothState {
        case .poweredOff:
            return "Bluetooth Is Off"
        case .unauthorized:
            return "Bluetooth Permission Needed"
        case .unsupported:
            return "Bluetooth Unavailable"
        case .unknown, .resetting:
            return "Bluetooth Starting..."
        default:
            return "Scan Bluetooth Sensors"
        }
    }

    private var scanButtonSubtitle: String {
        if bleManager.isScanning {
            return "Searching nearby AIMNet sensors"
        }

        switch bleManager.bluetoothState {
        case .poweredOff:
            return "Tap for steps to turn Bluetooth on"
        case .unauthorized:
            return "Tap to open permission instructions"
        case .unsupported:
            return "This device cannot scan sensors"
        case .unknown, .resetting:
            return "Waiting for Bluetooth status"
        default:
            return "Tap to discover nearby BLE devices"
        }
    }

    private var liveMonitorSubtitle: String {
        switch bleManager.connectionState {
        case .streaming:
            return "View connection status, telemetry, graphs, and exports"
        case .connecting:
            return "Connecting sensor; monitor will update automatically"
        default:
            return "View telemetry display and session exports"
        }
    }

    private func handleScanButtonTap() {
        if bleManager.bluetoothState == .poweredOff {
            bluetoothAlertMessage = "Bluetooth is currently off. Turn Bluetooth on in Control Center or Settings to scan and connect sensors."
            showBluetoothAlert = true
        } else if bleManager.bluetoothState == .unauthorized {
            bluetoothAlertMessage = "Bluetooth access is denied. Enable Bluetooth permission for this app in Settings."
            showBluetoothAlert = true
        } else if bleManager.isScanning {
            bleManager.stopScanning()
        } else {
            bleManager.startScanning()
        }
    }
}

private enum AppLinks {
    static let privacyPolicy = URL(string: "https://nexlusense.com/aimnet-privacy-policy")!
    static let support = URL(string: "https://nexlusense.com")!
}
