#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Build locally, then install for this account. Never requires sudo or changes grants.
INSTALL_DIR="${MOONSHINE_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Moonshine.app"
if pgrep -x Moonshine >/dev/null; then
  print -u2 'Quit Moonshine from its menu bar before installing or updating.'
  exit 1
fi
if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
  [[ ! -L "$INSTALL_APP" && -d "$INSTALL_APP" ]] || { print -u2 'Refusing to replace a symlink or non-app file.'; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_APP/Contents/Info.plist")" == 'com.d4j3y2k.moonshine' ]] || { print -u2 'Destination belongs to another application.'; exit 1; }
fi
./scripts/build.sh
mkdir -p "$INSTALL_DIR"
INSTALL_STAGE="$(mktemp -d "$INSTALL_DIR/.moonshine-install.XXXXXX")"
trap 'rm -rf -- "$INSTALL_STAGE"' EXIT
ditto --norsrc --noextattr build/Moonshine.app "$INSTALL_STAGE/Moonshine.app"
codesign --verify --strict "$INSTALL_STAGE/Moonshine.app"
if [[ -d "$INSTALL_APP" ]]; then mv "$INSTALL_APP" "$INSTALL_STAGE/Previous.app"; fi
if ! mv "$INSTALL_STAGE/Moonshine.app" "$INSTALL_APP"; then
  if [[ -d "$INSTALL_STAGE/Previous.app" ]]; then mv "$INSTALL_STAGE/Previous.app" "$INSTALL_APP"; fi
  exit 1
fi
print "Installed: $INSTALL_APP"
print "Open with: open \"$INSTALL_APP\""
