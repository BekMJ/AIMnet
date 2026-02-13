# AIMnet Methane iPad App Skeleton

This folder contains a SwiftUI + CoreBluetooth methane-monitoring app skeleton.

## Included
- BLE scan/connect/notify/read-fallback manager.
- Manufacturer-data serial parsing, DIS serial resolution, and per-device connection timing.
- Bluetooth off/unauthorized alerts with Settings deep-link.
- Timed methane sampling mode alongside continuous monitoring.
- Raw methane to ppm conversion using a configurable linear calibration profile.
- Local session buffering and CSV/JSON export.
- iPad-oriented split view UI (device list + live monitor).
- Bluetooth permission and background mode `Info.plist` template.

## How to Run
1. Create a new iOS App target in Xcode (SwiftUI, iPad compatible).
2. Add all files under this folder into the target.
3. Merge the keys from `Config/Info.plist` into your target `Info.plist`.
4. Build on a physical iPad (CoreBluetooth does not work on most simulators).

## Validation
Use `ValidationChecklist.md` to run scan/connect/stream/disconnect/export checks.
