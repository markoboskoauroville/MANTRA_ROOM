#!/bin/sh
# build.sh: Meditation Room (Mantra).app, swiftc straight, no Xcode. Run ONLY by GitHub Actions
# (.github/workflows/mac.yml; MANTRA_MANIFEST android-app.md §0: nothing compiles on the Mac). The version is VERSION in
# mac/app/App.swift. The page and butterchurn come from the Android app's assets (one copy of the engine); the songs are
# not in the bundle: the app plays the repository's copy on this Mac or downloads each one once (Player.swift, Songs).
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Meditation Room (Mantra)"
APP="build/$NAME.app"
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web/vendor"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/MeditationRoom" app/*.swift 2>&1 | grep -v "warning:" || true
[ -x "$APP/Contents/MacOS/MeditationRoom" ] || { echo "the app did not build"; exit 1; }
cp web/index.html "$APP/Contents/Resources/web/"
cp ../android/app/src/main/assets/web/vendor/* "$APP/Contents/Resources/web/vendor/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.meditationroom</string>
<key>CFBundleExecutable</key><string>MeditationRoom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Meditation Room (Mantra) sends its picture and sound as an NDI source on your network.</string>
<key>NSBonjourServices</key><array><string>_ndi._tcp</string></array>
<key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
</dict></plist>
PL
swift icon/make_icon.swift "$V" build/icon_1024.png
I=build/AppIcon.iconset; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
