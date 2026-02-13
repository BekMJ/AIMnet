import CoreBluetooth
import SwiftUI
import UIKit

struct DeviceListView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var showBluetoothAlert = false
    @State private var bluetoothAlertMessage = ""
    @State private var lastBluetoothState: CBManagerState = .unknown

    var body: some View {
        List {
            Section("Bluetooth") {
                HStack {
                    Text("State")
                    Spacer()
                    Text(bluetoothStateLabel)
                        .foregroundStyle(bluetoothStateColor)
                }
                HStack {
                    Text("Connection")
                    Spacer()
                    Text(bleManager.connectionState.rawValue.capitalized)
                }
                Text(bleManager.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let connected = bleManager.connectedPeripheral {
                Section("Connected Device") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connected.name ?? "Unnamed sensor")
                            .font(.headline)
                        Text(connected.identifier.uuidString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let serial = bleManager.deviceSerial {
                            Text("Serial: \(serial)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let firmware = bleManager.firmwareRevision {
                            Text("Firmware: \(firmware)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Disconnect", role: .destructive) {
                        bleManager.disconnect()
                    }
                }
            }

            Section("Nearby Methane Sensors") {
                if bleManager.discoveredPeripherals.isEmpty {
                    Text(bleManager.isScanning ? "Scanning..." : "No devices found yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peripheral.name ?? "Unnamed sensor")
                                .font(.headline)
                            Text(peripheral.identifier.uuidString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let advSerial = bleManager.advertisementSerials[peripheral.identifier] {
                                Text("ADV Serial: \(advSerial)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let info = bleManager.advertisedInfoByPeripheral[peripheral.identifier],
                               let major = info.versionMajor,
                               let minor = info.versionMinor {
                                Text("ADV FW: v\(major).\(minor)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Connect") {
                            bleManager.connect(peripheral)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            bleManager.connectionState == .connecting ||
                            (bleManager.connectedPeripheral != nil &&
                                bleManager.connectedPeripheral?.identifier != peripheral.identifier)
                        )
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Methane Sensors")
        .onReceive(bleManager.$bluetoothState) { state in
            if (state == .poweredOff || state == .unauthorized) &&
                !showBluetoothAlert &&
                lastBluetoothState != state {
                if state == .poweredOff {
                    bluetoothAlertMessage = "Bluetooth is currently off. Turn Bluetooth on in Control Center or Settings to scan and connect methane sensors."
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(bleManager.isScanning ? "Stop Scan" : "Scan") {
                    if bleManager.bluetoothState == .poweredOff {
                        bluetoothAlertMessage = "Bluetooth is currently off. Turn Bluetooth on in Control Center or Settings to scan and connect methane sensors."
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
                .disabled(bleManager.bluetoothState != .poweredOn)
            }
        }
    }

    private var bluetoothStateLabel: String {
        switch bleManager.bluetoothState {
        case .poweredOn:
            return "Powered On"
        case .poweredOff:
            return "Powered Off"
        case .unauthorized:
            return "Unauthorized"
        case .unsupported:
            return "Unsupported"
        case .resetting:
            return "Resetting"
        case .unknown:
            fallthrough
        @unknown default:
            return "Unknown"
        }
    }

    private var bluetoothStateColor: Color {
        bleManager.bluetoothState == .poweredOn ? .green : .orange
    }
}
