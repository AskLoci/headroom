#!/bin/zsh
# Local builds may use a development signature. Distributable archives must pass every release gate.
set -euo pipefail
script_path="${0:A}"
cd "${0:A:h}/.."

fail() { print -u2 -- "$1"; exit 1; }

# Exercise the real release control flow with isolated stand-ins for external Apple tools.
self_test() {
  local test_dir="$(mktemp -d "${TMPDIR:-/tmp}/headroom-release-test.XXXXXX")"
  trap 'rm -rf "$test_dir"' EXIT
  mkdir -p "$test_dir/bin" "$test_dir/binary"
  print -- 'test executable' > "$test_dir/binary/Headroom"
  cat > "$test_dir/bin/swift" <<'MOCK'
#!/bin/zsh
if [[ " $* " == *' --show-bin-path '* ]]; then print -- "$HEADROOM_TEST_DIR/binary"; fi
MOCK
  cat > "$test_dir/bin/codesign" <<'MOCK'
#!/bin/zsh
print -r -- "codesign $*" >> "$HEADROOM_TEST_DIR/calls"
if [[ "$*" == *'--sign'* ]]; then
  [[ "$*" == *'--options runtime'* && "$*" == *'--timestamp '* ]] || exit 1
fi
if [[ "$*" == *'--display'* ]]; then
  print -u2 -- 'Authority=Developer ID Application: Example (TEST123456)'
  print -u2 -- 'CodeDirectory flags=0x10000(runtime)'
  print -u2 -- 'Timestamp=Oct 19, 2026'
fi
[[ "${HEADROOM_TEST_FAILURE:-}" != signing ]] || exit 1
MOCK
  cat > "$test_dir/bin/xcrun" <<'MOCK'
#!/bin/zsh
print -r -- "xcrun $*" >> "$HEADROOM_TEST_DIR/calls"
if [[ "$1 $2" == 'notarytool submit' ]]; then
  result=Accepted
  [[ "${HEADROOM_TEST_FAILURE:-}" != rejected ]] || result=Invalid
  print -- "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>status</key><string>$result</string></dict></plist>"
elif [[ "$1 $2" == 'notarytool history' ]]; then
  [[ "${HEADROOM_TEST_FAILURE:-}" != credentials ]] || exit 1
elif [[ "$1" == stapler ]]; then
  [[ "${HEADROOM_TEST_FAILURE:-}" != stapler ]] || exit 1
fi
MOCK
  cat > "$test_dir/bin/spctl" <<'MOCK'
#!/bin/zsh
print -r -- "spctl $*" >> "$HEADROOM_TEST_DIR/calls"
[[ "${HEADROOM_TEST_FAILURE:-}" != gatekeeper ]] || exit 1
MOCK
  chmod +x "$test_dir/bin/"*
  export HEADROOM_TEST_DIR="$test_dir"
  export PATH="$test_dir/bin:$PATH"
  export HEADROOM_SIGNING_IDENTITY='Developer ID Application: Example (TEST123456)'
  export HEADROOM_NOTARY_PROFILE='test-only-profile'
  local scenario
  for scenario in credentials signing rejected stapler gatekeeper; do
    if HEADROOM_TEST_FAILURE="$scenario" HEADROOM_BUILD_DIR="$test_dir/$scenario" \
        "$script_path" --release > "$test_dir/$scenario.log" 2>&1; then
      fail "Release test failed: $scenario was accepted"
    fi
    [[ ! -e "$test_dir/$scenario/Headroom.zip" && ! -e "$test_dir/$scenario/Headroom.app" ]] \
      || fail "Release test failed: $scenario published an artifact"
  done
  if HEADROOM_NOTARY_PROFILE='' HEADROOM_BUILD_DIR="$test_dir/missing" "$script_path" --release >/dev/null 2>&1; then
    fail 'Release test failed: missing credentials accepted'
  fi
  if HEADROOM_SIGNING_IDENTITY='-' HEADROOM_BUILD_DIR="$test_dir/adhoc" "$script_path" --release >/dev/null 2>&1; then
    fail 'Release test failed: ad-hoc signing accepted'
  fi
  HEADROOM_BUILD_DIR="$test_dir/accepted" "$script_path" --release >/dev/null
  [[ -s "$test_dir/accepted/Headroom.zip" ]] || fail 'Release test failed: accepted archive missing'
  [[ -f "$test_dir/accepted/Headroom.zip.sha256" ]] || fail 'Release test failed: checksum missing'
  if HEADROOM_BUILD_DIR="$test_dir/accepted" "$script_path" --release >/dev/null 2>&1; then
    fail 'Release test failed: existing release overwritten'
  fi
  print -- 'Release workflow tests passed (success, missing credentials, wrong identity, signing, rejection, stapling, Gatekeeper, overwrite).'
  rm -rf "$test_dir"
  trap - EXIT
}

mode=development
install_app=true
for argument in "$@"; do
  case "$argument" in
    --release) mode=release; install_app=false ;;
    --no-install) install_app=false ;;
    --self-test) self_test; exit 0 ;;
    *) fail 'Usage: scripts/build-app.sh [--release | --no-install | --self-test]' ;;
  esac
done
build_dir="${HEADROOM_BUILD_DIR:-$PWD/build}"
build_dir="${build_dir:A}"
identity="${HEADROOM_SIGNING_IDENTITY:-}"
profile="${HEADROOM_NOTARY_PROFILE:-}"

if [[ "$mode" == release ]]; then
  [[ "$identity" == 'Developer ID Application: '* ]] || fail 'Set HEADROOM_SIGNING_IDENTITY to a Developer ID Application certificate name.'
  [[ -n "$profile" ]] || fail 'Set HEADROOM_NOTARY_PROFILE to a stored notarytool Keychain profile.'
  [[ ! -e "$build_dir/Headroom.app" && ! -e "$build_dir/Headroom.zip" && ! -e "$build_dir/Headroom.zip.sha256" ]] \
    || fail 'Choose an empty HEADROOM_BUILD_DIR for this release.'
  xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null
fi

mkdir -p "$build_dir"
staging="$(mktemp -d "$build_dir/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
scratch="${HEADROOM_SWIFT_SCRATCH:-$build_dir/swift}"
swift build -c release --scratch-path "$scratch"
binary="$(swift build -c release --scratch-path "$scratch" --show-bin-path)/Headroom"
app="$staging/Headroom.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Headroom"
cp Resources/Info.plist "$app/Contents/Info.plist"

if [[ "$mode" == release ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
  codesign --verify --strict "$app"
  signature="$(codesign --display --verbose=4 "$app" 2>&1)"
  [[ "$signature" == *'Authority=Developer ID Application: '* && "$signature" == *'(runtime)'* && "$signature" == *'Timestamp='* ]] \
    || fail 'Release signature is missing Developer ID, hardened runtime, or a secure timestamp.'
  /usr/bin/ditto -c -k --keepParent "$app" "$staging/submission.zip"
  xcrun notarytool submit "$staging/submission.zip" --keychain-profile "$profile" --wait --output-format plist > "$staging/notary.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$staging/notary.plist")" == Accepted ]] \
    || fail 'Apple did not accept this build for notarization.'
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  codesign --verify --strict "$app"
  spctl --assess --type execute --verbose=2 "$app"
  /usr/bin/ditto -c -k --keepParent "$app" "$staging/Headroom.zip"
  (cd "$staging" && shasum -a 256 Headroom.zip > Headroom.zip.sha256)
  mv "$app" "$staging/Headroom.zip" "$staging/Headroom.zip.sha256" "$build_dir/"
  print -- "Signed and notarized release: $build_dir/Headroom.zip"
else
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
  fi
  codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$app"
  codesign --verify --strict "$app"
  if [[ -d "$build_dir/Headroom.app" ]] && lsof +D "$build_dir/Headroom.app" >/dev/null 2>&1; then
    fail 'The build output is in use. Choose a different HEADROOM_BUILD_DIR.'
  fi
  rm -rf "$build_dir/Headroom.app"
  mv "$app" "$build_dir/Headroom.app"
  if [[ "$install_app" == true ]]; then
    if pgrep -xq Headroom; then
      fail 'Headroom is running. Quit it before installing, or use --no-install.'
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Headroom.app"
    cp -R "$build_dir/Headroom.app" "$HOME/Applications/Headroom.app"
    open "$HOME/Applications/Headroom.app"
  fi
  print -- "Development build: $build_dir/Headroom.app"
fi
