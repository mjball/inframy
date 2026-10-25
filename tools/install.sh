#!/bin/zsh
# Builds Inframy (Release) and installs it as /Applications/Inframy.app, the only copy that should exist:
# the build product is moved out, not copied, so Spotlight never shows a second Inframy.
set -euo pipefail
cd "$(dirname "$0")/.."

derived=$(mktemp -d -t inframy-build)
trap 'rm -rf "$derived"' EXIT

xcodegen generate --quiet
xcodebuild -scheme Inframy -configuration Release -derivedDataPath "$derived" build -quiet
built="$derived/Build/Products/Release/Inframy.app"

# Quit the running copy (it reopens below).
osascript -e 'tell application id "net.mjball.inframy" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -x Inframy >/dev/null || break; sleep 0.5; done
if pgrep -x Inframy >/dev/null; then echo "Inframy didn't quit; not installing." >&2; exit 1; fi

rm -rf /Applications/Inframy.app
mv "$built" /Applications/Inframy.app
open /Applications/Inframy.app

# Old build products from before this script (build/, DerivedData) would show up in Spotlight too.
rm -rf build/Inframy.app
find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 -path '*/Build/Products/*/Inframy.app' -prune \
    -exec rm -rf {} + 2>/dev/null || true
echo "Installed $(git rev-parse --short HEAD) at /Applications/Inframy.app"
