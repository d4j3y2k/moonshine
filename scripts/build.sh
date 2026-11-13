#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache .build/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox --cache-path .build/swiftpm-cache
MOONSHINE_APP="$PWD/build/Moonshine.app"
mkdir -p "$MOONSHINE_APP/Contents/MacOS" "$MOONSHINE_APP/Contents/Resources"
cp .build/release/Moonshine "$MOONSHINE_APP/Contents/MacOS/Moonshine"
cp Resources/Info.plist "$MOONSHINE_APP/Contents/Info.plist"
# Credentials and their paths are configured per user in Settings, never bundled.
codesign --force --sign "${MOONSHINE_SIGN_IDENTITY:--}" "$MOONSHINE_APP"
codesign --verify --strict "$MOONSHINE_APP"
python3 scripts/package-extensions.py
print "Built: $MOONSHINE_APP"
