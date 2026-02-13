# Methane BLE Validation Checklist

## Packet Parsing (Simulator or Unit Harness)
- Feed deterministic test frames for methane raw values and verify `ppm(fromRaw:)` output.
- Feed signed temperature bytes (little-endian) and verify Celsius conversion.
- Feed humidity bytes (little-endian) and verify percent RH conversion.
- Feed battery level byte and verify 0-100 clamping.

## BLE Device Flow
- Start scan and confirm nearby sensor appears in `DeviceListView`.
- Turn Bluetooth off/on and confirm alert behavior and recovery state.
- Connect to device and verify state transitions: `connecting -> preparing -> streaming`.
- Confirm methane readings populate `liveReadings`, `methaneRawData`, and `methanePPMData`.
- Disable notifications on firmware side (or block updates) and verify read fallback continues updates.
- Trigger disconnect and confirm state moves to `disconnected` with session closed.
- If battery <= threshold, verify one low-battery local notification is posted.

## Timed Sample Mode
- Open timed sample screen from `LiveMonitorView`.
- Start sample while connected and confirm countdown decrements each second.
- Confirm sample captures readings and generates min/max/avg ppm summary on completion.
- Export timed sample CSV/JSON and verify share links open generated files.

## Local Storage and Export
- Verify active session starts on connect and increments reading count as values arrive.
- End session and confirm it appears in recent sessions.
- Export CSV and JSON and verify files are written under Documents/AIMnetMethane/Exports.
- Reopen app and verify recent sessions restore from `sessionIndex.json`.
