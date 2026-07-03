#!/usr/bin/env bash
# Build (if needed), launch the Debug app via LaunchServices, and stream its
# dev-log output. Launching with `open` gives the event tap correct TCC
# attribution; the dev logger uses unified logging so its output shows here.
#
# Quit the app from its menu bar item (or `pkill -f Vizpr.app`); Ctrl+C stops the
# log stream.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/dd/Build/Products/Debug/Vizpr.app"
if [[ ! -d "$APP" ]]; then
  echo "Building Debug app ..."
  xcodebuild -project Vizpr.xcodeproj -scheme Vizpr -configuration Debug \
    -derivedDataPath build/dd build >/dev/null
fi

# Kill any running instance first: `open` would otherwise just activate the
# old process instead of launching the freshly built binary, silently testing
# stale code. (Ctrl+C below only stops the log stream, not the app.)
if pgrep -f "Vizpr.app/Contents/MacOS/Vizpr" >/dev/null; then
  echo "Quitting running Vizpr instance ..."
  pkill -f "Vizpr.app/Contents/MacOS/Vizpr"
  sleep 1
fi

echo "Launching $APP ..."
open "$APP"

echo
echo "Streaming dev log. Press Fn / hold Fn / Escape and watch for hotkey actions."
echo "(Ctrl+C to stop streaming; quit Vizpr from its menu-bar mic icon.)"
echo
exec log stream --level debug --predicate 'subsystem == "com.kudzuweb.vizpr"'
