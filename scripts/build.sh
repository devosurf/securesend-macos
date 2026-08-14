#!/bin/bash
set -euo pipefail

# Builds SecureSend.app. SwiftPM compiles the binary, this assembles the bundle
# around it, because SwiftPM has no notion of a .app and the Services live in the
# Info.plist. Ad-hoc signed by default, which is enough to run locally; the
# release pipeline passes a real Developer ID identity in SIGN_IDENTITY.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/SecureSend.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --package-path "$ROOT" --product SecureSend

# Stop any running copy so the bundle can be replaced cleanly.
pkill -x SecureSend || true

BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/SecureSend"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/SecureSend"

codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

# Tell Launch Services the bundle exists, then rebuild the services database, or
# the right-click entries will not appear until the next login.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
/System/Library/CoreServices/pbs -flush

echo "built and registered: $APP"
