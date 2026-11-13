#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
MODE=preview
PROFILE=''
PACKAGE_APP=''
PREBUILT=false
while (( $# )); do
  case "$1" in
    --preview) MODE=preview; shift ;;
    --notarize) (( $# >= 2 )) || { print -u2 'Missing keychain profile'; exit 1; }; MODE=notarized; PROFILE="$2"; shift 2 ;;
    --app) (( $# >= 2 )) || { print -u2 'Missing app path'; exit 1; }; PACKAGE_APP="$2"; PREBUILT=true; shift 2 ;;
    *) print -u2 "Usage: $0 [--preview | --notarize keychain-profile] [--app /path/Moonshine.app]"; exit 1 ;;
  esac
done
if [[ -z "$PACKAGE_APP" ]]; then
  ./scripts/build.sh
  PACKAGE_APP="${MOONSHINE_OUTPUT_DIR:-$PWD/build}/Moonshine.app"
fi
PACKAGE_APP="${PACKAGE_APP:A}"
codesign --verify --strict "$PACKAGE_APP"
python3 scripts/validate-package.py "$PACKAGE_APP"
[[ "$(/usr/bin/lipo -archs "$PACKAGE_APP/Contents/MacOS/Moonshine")" == arm64 ]] || { print -u2 'Package must contain exactly arm64'; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PACKAGE_APP/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" == <-> ]] || { print -u2 'Invalid app version'; exit 1; }
DIST="${MOONSHINE_DIST_DIR:-$PWD/dist}"
mkdir -p "$DIST"
DIST="${DIST:A}"
STAGE="$(mktemp -d "$DIST/.moonshine-package.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
NAME="Moonshine-$VERSION-macos-arm64-$MODE"
BUNDLE="$STAGE/$NAME"
mkdir -p "$BUNDLE"
ditto --norsrc --noextattr "$PACKAGE_APP" "$BUNDLE/Moonshine.app"
if [[ "$MODE" == notarized ]]; then
  SIGNATURE="$(codesign -dv --verbose=4 "$BUNDLE/Moonshine.app" 2>&1)"
  [[ "$SIGNATURE" == *'Authority=Developer ID Application:'* && "$SIGNATURE" == *'runtime'* && "$SIGNATURE" == *'Timestamp='* ]] || { print -u2 'Notarized releases require Developer ID Application, hardened runtime, and a secure timestamp.'; exit 1; }
  ditto -c -k --norsrc --noextattr --keepParent "$BUNDLE/Moonshine.app" "$STAGE/notarize.zip"
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  if [[ -n "${MOONSHINE_NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$MOONSHINE_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$STAGE/notarize.zip" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$BUNDLE/Moonshine.app"
  xcrun stapler validate "$BUNDLE/Moonshine.app"
  spctl --assess --type execute --verbose=2 "$BUNDLE/Moonshine.app"
fi
cp scripts/install-app.sh "$BUNDLE/Install.command"
chmod 755 "$BUNDLE/Install.command"
cp LICENSE "$BUNDLE/LICENSE.txt"

python3 scripts/package-extensions.py --output-dir "$BUNDLE/BrowserExtensions"
cat > "$BUNDLE/READ-ME.txt" <<EOF
Moonshine $VERSION (build $BUILD) — Apple silicon — $MODE

No Xcode or compiler is needed to use this app.
Tested on macOS 26. Earlier deployment targets remain unverified; Intel is not included.

Install: quit the copy you are updating. In Finder, choose Go > Go to Folder,
enter ~/Applications, create that folder if needed, and move Moonshine.app there.
Open the app from that folder. Keep only one installed copy for predictable handoff.

Optional checked install/update from Terminal, in this extracted folder:
  /bin/zsh ./Install.command
It checks the signature, identity, OS/architecture, running destination, signing team,
and build number. It preserves quarantine, preferences, data, and keys. No sudo.
An intentional downgrade requires --allow-downgrade. The script never starts the app.
The helper itself is a readable shell script, not a notarized installer package.

If this is a preview: it is NOT notarized and may be blocked by macOS after download.
It is for developer evaluation, not a friction-free public release. Use a notarized
release when available, or build from source. Do not disable Gatekeeper or strip quarantine.
For a preview you trust, Apple explains per-app opening at:
https://support.apple.com/en-us/102445

Setup and permissions: https://github.com/d4j3y2k/moonshine/blob/main/docs/SETUP.md
Source and updates: https://github.com/d4j3y2k/moonshine
EOF
PROVENANCE=source-build
if [[ "$PREBUILT" == true ]]; then PROVENANCE=packaging-checkout-only; fi
COMMIT="$(git rev-parse HEAD)"
DIRTY=false
[[ -z "$(git status --porcelain)" ]] || DIRTY=true
cat > "$BUNDLE/BUILD-INFO.txt" <<EOF
app=Moonshine
version=$VERSION
build=$BUILD
architecture=arm64
distribution=$MODE
prebuilt_app=$PREBUILT
source_provenance=$PROVENANCE
source_commit=$COMMIT
source_modified=$DIRTY
EOF
python3 scripts/validate-package.py "$BUNDLE/Moonshine.app"
codesign --verify --strict "$BUNDLE/Moonshine.app"
ditto -c -k --norsrc --noextattr --keepParent "$BUNDLE" "$STAGE/$NAME.zip"
unzip -tq "$STAGE/$NAME.zip"
# Verify that archive extraction retains a usable signature and, in release mode, the ticket.
mkdir "$STAGE/extracted"
ditto -x -k "$STAGE/$NAME.zip" "$STAGE/extracted"
codesign --verify --strict "$STAGE/extracted/$NAME/Moonshine.app"
if [[ "$MODE" == notarized ]]; then xcrun stapler validate "$STAGE/extracted/$NAME/Moonshine.app"; fi
(cd "$STAGE" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
mv "$STAGE/$NAME.zip" "$DIST/$NAME.zip"
mv "$STAGE/$NAME.zip.sha256" "$DIST/$NAME.zip.sha256"
print "Package: $DIST/$NAME.zip"
print "Mode: $MODE; see docs/DISTRIBUTION.md before sharing."
