#!/usr/bin/env bash
# Runs the plugin's tests: pure logic in qmltestrunner, shell syntax, the
# launch helper's argument handling, and the sampler's output shape.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
qt_bin=$(dirname -- "$(readlink -f -- "$(command -v qml6)")")

for f in "$repo/Launch.sh" "$repo/bin/Sample.sh" "$repo/bin/Connect.sh" "$repo/bin/shim/xfreerdp3"; do
  bash -n "$f"
done
if bash "$repo/Launch.sh" bogus 2>/dev/null; then
  echo "Launch.sh accepted an unknown action" >&2
  exit 1
fi
# The sampler must always print one JSON object with a boolean "running".
bash "$repo/bin/Sample.sh" | jq -e 'type == "object" and (.running | type == "boolean")' >/dev/null

env -u DISPLAY -u WAYLAND_DISPLAY \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
  "$qt_bin/qmltestrunner" -input "$repo/tests"
