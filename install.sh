#!/bin/bash
# Builds Margins and puts it in /Applications.
# Your library is never touched by this script, only backed up first.
set -eo pipefail
cd "$(dirname "$0")"

DATA="$HOME/Library/Application Support/Margins"

# 1. Build first. If the build fails, stop here: the installed app stays as it is.
xcodebuild -project Margins.xcodeproj -target Margins -configuration Release SYMROOT="$PWD/build" build | tail -n 20

# 2. Quit Margins if it's running, so it saves what's open.
if pgrep -x Margins >/dev/null; then
  osascript -e 'quit app "Margins"' || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Margins >/dev/null || break; sleep 0.5; done
fi

# 3. Back up the library before switching versions.
if [ -f "$DATA/library.json" ]; then
  mkdir -p "$DATA/Backups"
  cp "$DATA/library.json" "$DATA/Backups/before-install-$(date +%Y-%m-%d_%H%M%S).json"
  echo "Backed up your library to $DATA/Backups"
fi

# 4. Swap the app.
rm -rf /Applications/Margins.app
cp -R build/Release/Margins.app /Applications/
open /Applications/Margins.app
echo "Margins is installed in Applications."
