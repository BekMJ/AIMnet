# AIMnet Methane iPad App Skeleton

This folder contains a SwiftUI + CoreBluetooth methane-monitoring app skeleton.

## Included
- BLE scan/connect/notify/read-fallback manager.
- Manufacturer-data serial parsing, DIS serial resolution, and per-device connection timing.
- Bluetooth off/unauthorized alerts with Settings deep-link.
- Timed methane sampling mode alongside continuous monitoring.
- Methane ppm from the K96 real-time models (Swift port of `k96/k96_rt.py` from the AIMNet_realtime package).
  Every model in the bundled `k96_config.json` (a copy of `k96/config.json`) can be chosen in the app; "Auto" shows the
  config's recommendation for the tube position (AIMNet_1.7 at the inlet, C5 at the old position). A model chosen in the
  middle of a power-on is rebuilt from that power-on's frames, so it has the same zero as if it had run from the start.
  One zero per power-on, kept across Bluetooth reconnects, restored from the raw log after an app relaunch.
  Code: `AIMNET/AIMNET/Calibration/`; frozen model files and config: `AIMNET/AIMNET/Calibration/Models/`.
- Raw frame logging in the Python UI's format (`Documents/AIMnetMethane/Raw/<device> data <time>.csv`), usable with `k96/run_file.py`.
- Local session buffering and CSV/JSON export.
- iPad-oriented split view UI (device list + live monitor).
- Bluetooth permission and background mode `Info.plist` template.

## How to Run
1. Create a new iOS App target in Xcode (SwiftUI, iPad compatible).
2. Add all files under this folder into the target.
3. Merge the keys from `Config/Info.plist` into your target `Info.plist`.
4. Build on a physical iPad (CoreBluetooth does not work on most simulators).

## Validation
- `Tools/K96Golden/run.sh /path/to/AIMNet_realtime/k96` checks the Swift models against the Python pipeline: every
  output column of every model, frame by frame, on synthetic recordings (cold start, hot restart, shifted air, data
  gap, flow steps, slow sampling, stuck sensor, room-air zero then N2, manual zero), plus switching models on mid
  recording. Rerun it whenever a model file, `config.json` or `k96_rt.py` changes (copy the new files into
  `Calibration/Models/` first). Add real raw logger files when available.
Use `ValidationChecklist.md` to run scan/connect/stream/disconnect/export checks.
