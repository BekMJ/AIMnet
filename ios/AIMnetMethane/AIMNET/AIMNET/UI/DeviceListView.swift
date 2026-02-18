import CoreBluetooth
import SwiftUI
import UIKit

struct DeviceListView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var showBluetoothAlert = false
    @State private var bluetoothAlertMessage = ""
    @State private var lastBluetoothState: CBManagerState = .unknown

    var body: some View {
        ZStack {
            FuturisticBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nearbySensorsPanel
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Sensors")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
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
                } label: {
                    Label(
                        bleManager.isScanning ? "Stop Scan" : "Scan",
                        systemImage: bleManager.isScanning ? "stop.circle.fill" : "dot.radiowaves.left.and.right"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                }
                .tint(bleManager.isScanning ? FuturisticPalette.warning : FuturisticPalette.cyan)
                .disabled(bleManager.bluetoothState != .poweredOn)
            }
        }
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
}
