#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
fixture="$work/Deux fenêtres V2.app"
results="$PWD/build/cross-space-test.log"
mkdir -p "$fixture/Contents/MacOS"
cleanup() {
    if [ -s "$work/fixture.pid" ]; then
        pid=$(cat "$work/fixture.pid")
        if ps -ww -p "$pid" -o args= | grep -Fq "$work/fixture.json"; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fr.groupesespaces.v2.fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleName</key><string>Deux fenêtres V2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -parse-as-library \
    Sources/GroupesEspaces/SpaceSystem.swift Sources/GroupesEspaces/CrossSpaceFixture.swift \
    Tests/Fixture.swift -o "$fixture/Contents/MacOS/Fixture"
codesign --force --sign - "$fixture" 2>/dev/null
open -g -n -a "$fixture" --stdout "$work/fixture.log" --stderr "$work/fixture.log" --args "$work/fixture.json"
attempt=0
while [ ! -s "$work/fixture.json" ] && [ "$attempt" -lt 60 ]; do
    sleep .2
    attempt=$((attempt + 1))
done
if [ ! -s "$work/fixture.json" ]; then
    cat "$work/fixture.log"
    exit 1
fi
: > "$results"
open -g -n -W -a "$PWD/build/Groupes d’espaces V2.app" \
    --stdout "$results" --stderr "$results" --args --verify-spaces "$work/fixture.json"
cat "$results"
test "$(grep -c '^PASS ' "$results")" -eq 3
