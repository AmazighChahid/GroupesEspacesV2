#!/bin/sh
set -eu
cd "$(dirname "$0")"
minimum_macos=$(awk '$1 == "MACOSX_DEPLOYMENT_TARGET" && $2 == "=" { print $3 }' Resources/ProjectHop.xcconfig)
test -n "$minimum_macos"
work=$(mktemp -d)
trap 'rmdir "$work" 2>/dev/null || true' EXIT
app="$PWD/build/ProjectHop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -fobjc-arc -mmacosx-version-min="$minimum_macos" -c Sources/DockRenderer/DockRenderer.m -o "$work/DockRenderer.o"
xcrun swiftc -swift-version 6 -parse-as-library -O -whole-module-optimization \
    -import-objc-header Sources/DockRenderer/DockRenderer.h \
    -target "arm64-apple-macosx$minimum_macos" \
    Sources/ProjectHop/*.swift "$work/DockRenderer.o" -o "$work/ProjectHop"
mv "$work/ProjectHop" "$app/Contents/MacOS/ProjectHop"
unlink "$work/DockRenderer.o"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string fr.groupesespaces.v2 "$app/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string ProjectHop "$app/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$minimum_macos" "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
identity="${PROJECTHOP_CODESIGN_IDENTITY:-${GROUPES_V2_CODESIGN_IDENTITY:-}}"
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
codesign --force --sign "${identity:--}" --timestamp=none "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
