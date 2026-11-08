#!/bin/sh
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rmdir "$work" 2>/dev/null || true' EXIT
app="$PWD/build/Groupes d’espaces V2.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -fobjc-arc -mmacosx-version-min=27.2 -c Sources/DockRenderer/DockRenderer.m -o "$work/DockRenderer.o"
xcrun swiftc -swift-version 6 -parse-as-library -O -whole-module-optimization \
    -import-objc-header Sources/DockRenderer/DockRenderer.h \
    -target arm64-apple-macosx27.2 \
    Sources/GroupesEspaces/*.swift "$work/DockRenderer.o" -o "$work/GroupesEspacesV2"
mv "$work/GroupesEspacesV2" "$app/Contents/MacOS/GroupesEspacesV2"
unlink "$work/DockRenderer.o"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
identity="${GROUPES_V2_CODESIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
codesign --force --sign "${identity:--}" --timestamp=none "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
