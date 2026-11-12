#!/bin/zsh
# Compare the app's Swift K96 model with the Python reference on the golden fixtures.
#   ./run.sh                                  check against the committed fixtures
#   ./run.sh --regen /path/to/AIMNet_realtime/k96   rebuild the fixtures from the Python pipeline first
set -euo pipefail
HERE=${0:A:h}
APP=$HERE/../../AIMNET/AIMNET/Calibration
if [[ ${1:-} == --regen ]]; then
  python3 "$HERE/make_golden.py" --k96 "$2" --out "$HERE/fixtures"
fi
BIN=${TMPDIR:-/tmp}/k96golden
swiftc -O -o "$BIN" "$APP/K96Frame.swift" "$APP/K96Model.swift" "$HERE/main.swift"
"$BIN" "$APP/Models" "$HERE/fixtures"
