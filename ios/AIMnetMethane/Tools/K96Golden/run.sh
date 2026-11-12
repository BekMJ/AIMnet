#!/bin/zsh
# Compare the app's Swift K96 models with the Python reference (every model of k96_config.json).
#   ./run.sh /path/to/AIMNet_realtime/k96      (or set K96_DIR)
# The fixtures are generated into a temporary folder each run (they are deterministic, ~150 MB, not kept in git).
set -euo pipefail
HERE=${0:A:h}
APP=$HERE/../../AIMNET/AIMNET/Calibration
K96=${1:-${K96_DIR:-}}
if [[ -z $K96 ]]; then echo "usage: run.sh /path/to/AIMNet_realtime/k96"; exit 2; fi
if ! cmp -s "$K96/config.json" "$APP/Models/k96_config.json"; then
  echo "note: $K96/config.json differs from the app's k96_config.json - the app may be out of date"
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/k96golden.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
python3 "$HERE/make_golden.py" --k96 "$K96" --out "$WORK/fixtures"
swiftc -O -o "$WORK/k96golden" "$APP/K96Frame.swift" "$APP/K96Model.swift" "$HERE/main.swift"
"$WORK/k96golden" "$APP/Models" "$WORK/fixtures"
