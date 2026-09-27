#!/usr/bin/env bash
# Runs the plugin's tests: pure logic in qmltestrunner, the launch helper's
# argument handling, and shell syntax.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
qt_bin=$(dirname -- "$(readlink -f -- "$(command -v qml6)")")

bash -n "$repo/Launch.sh"
if bash "$repo/Launch.sh" bogus 2>/dev/null; then
  echo "Launch.sh accepted an unknown action" >&2
  exit 1
fi

env -u DISPLAY -u WAYLAND_DISPLAY \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
  "$qt_bin/qmltestrunner" -input "$repo/tests"
