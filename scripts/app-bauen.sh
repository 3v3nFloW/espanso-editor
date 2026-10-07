#!/bin/zsh
# Baut "Espanso Editor.app" (Release) nach build/ und installiert sie mit --installieren nach /Applications.
set -euo pipefail
cd "${0:A:h}/.."
# Das macOS-27-SDK der Command Line Tools verlangt für @State ein Makro-Plugin, das nur Xcode mitbringt → 26.x-SDK nehmen
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
[[ -n "$SDK" ]] && export SDKROOT="$SDK"
swift build -c release --product Bausteine
VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1)
APP="build/Espanso Editor.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bausteine "$APP/Contents/MacOS/Bausteine"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sprachordner: macOS wählt danach die Sprache der Standardmenüs; die eigenen Texte übersetzt L() (Sources/BausteineKern/Sprache.swift)
for sprache in en de; do mkdir -p "$APP/Contents/Resources/$sprache.lproj"; printf '"CFBundleName" = "Espanso Editor";\n' > "$APP/Contents/Resources/$sprache.lproj/InfoPlist.strings"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Espanso Editor</string>
  <key>CFBundleDisplayName</key><string>Espanso Editor</string>
  <key>CFBundleIdentifier</key><string>vet.kappa1.espanso-editor</string>
  <key>CFBundleExecutable</key><string>Bausteine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.3</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Zum Import der Bausteine aus Typinator.</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
</dict></plist>
PLIST
codesign --force --sign - --identifier vet.kappa1.espanso-editor "$APP"
echo "gebaut: $APP ($VERSION)"
if [[ "${1:-}" == "--installieren" ]]; then
  # nur beenden, wenn sie läuft (ein „tell … to quit“ würde sie sonst erst starten)
  if pgrep -f "Espanso Editor.app/Contents/MacOS" >/dev/null; then osascript -e 'tell application id "vet.kappa1.espanso-editor" to quit' 2>/dev/null || true; fi
  sleep 1
  rm -rf "/Applications/Espanso Editor.app" /Applications/Bausteine.app   # Bausteine.app = alter Name bis 07.10.26
  cp -R "$APP" /Applications/
  echo "installiert: /Applications/Espanso Editor.app"
fi
