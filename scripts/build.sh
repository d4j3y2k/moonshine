#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BUILD_ROOT="${MOONSHINE_BUILD_ROOT:-$PWD/.build}"
OUTPUT_DIR="${MOONSHINE_OUTPUT_DIR:-$PWD/build}"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
BUILD_ROOT="${BUILD_ROOT:A}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/clang-cache"
BUILD_ARGS=(-c release --arch arm64 --disable-sandbox --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/swiftpm-cache"
  -Xswiftc -gnone
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
  -Xswiftc -file-prefix-map -Xswiftc "$BUILD_ROOT=./.build"
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/redacted"
  -Xswiftc -file-compilation-dir -Xswiftc .)
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
STAGE="$(mktemp -d "$OUTPUT_DIR/.moonshine-build.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/Moonshine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Moonshine" "$APP/Contents/MacOS/Moonshine"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Release SwiftPM binaries can retain debug paths. Remove debug symbols before signing.
/usr/bin/strip -S "$APP/Contents/MacOS/Moonshine"
SIGN_IDENTITY="${MOONSHINE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--entitlements scripts/entitlements.plist)
if [[ "$SIGN_IDENTITY" == '-' ]]; then
  codesign --force --options runtime --timestamp=none "${SIGN_ARGS[@]}" --sign - "$APP"
else
  codesign --force --options runtime --timestamp "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
python3 scripts/validate-package.py "$APP"
if [[ -e "$OUTPUT_DIR/Moonshine.app" || -L "$OUTPUT_DIR/Moonshine.app" ]]; then
  [[ -d "$OUTPUT_DIR/Moonshine.app" && ! -L "$OUTPUT_DIR/Moonshine.app" ]] || { print -u2 'Unsafe build output destination'; exit 1; }
  mv "$OUTPUT_DIR/Moonshine.app" "$STAGE/Previous.app"
fi
if ! mv "$APP" "$OUTPUT_DIR/Moonshine.app"; then
  [[ ! -d "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "$OUTPUT_DIR/Moonshine.app"
  exit 1
fi
python3 scripts/package-extensions.py --output-dir "$OUTPUT_DIR"
print "Built: $OUTPUT_DIR/Moonshine.app (arm64)"
print 'Signing is separate from notarization; see docs/DISTRIBUTION.md.'
