#!/bin/zsh
# Builds Headroom.app, signs it with the first Apple Development identity (ad hoc if none),
# installs it to ~/Applications and opens it.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
binary="$(swift build -c release --show-bin-path)/Headroom"
app="build/Headroom.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Headroom"
cp Resources/Info.plist "$app/Contents/Info.plist"

identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
codesign --force --timestamp=none --sign "${identity:--}" "$app"
codesign --verify --strict "$app"

if pgrep -xq Headroom; then
  osascript -e 'tell application id "ai.askloci.headroom" to quit' || true
  for _ in {1..40}; do pgrep -xq Headroom || break; sleep 0.25; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Headroom.app"
cp -R "$app" "$HOME/Applications/Headroom.app"
open "$HOME/Applications/Headroom.app"
echo "Installed $HOME/Applications/Headroom.app (signed by ${identity:-ad hoc})"
