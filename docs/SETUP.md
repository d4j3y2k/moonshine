# Setup

## Build and install

Use an Apple silicon Mac with Xcode 26 or later and Python 3. In Xcode Settings → Locations, select the installed Xcode under Command Line Tools. `xcode-select -p` should point inside Xcode, and `swift --version` should report Swift 6 or later. A Command Line Tools-only installation may not provide the SDK this app uses.

```sh
git clone https://github.com/d4j3y2k/moonshine.git
cd moonshine
./scripts/install.sh
open "$HOME/Applications/Moonshine.app"
```

For a different destination, set `MOONSHINE_INSTALL_DIR` to a folder you own. The installer replaces only an existing Moonshine bundle, verifies the new signature, and restores the previous bundle if the final move fails. It never removes preferences or key files. Do not run it with sudo.

## Permissions and browsers

Use the controls in Moonshine Settings to request Accessibility and optional Screen Recording. macOS grants these separately. Without Accessibility, exact native-window activation can fail even when a title is visible. Some applications never expose usable native windows. Browser parent windows are excluded from generic capture to avoid including private browser content.

Chrome Automation is optional and reads regular Chrome windows. The [browser-extension instructions](../README.md#browser-tabs-and-page-context) cover Safari and explicit Chrome profiles. A browser extension needs its own pairing code, not an OpenAI key. If it cannot connect, make sure one copy of Moonshine is running, re-copy the code, and check whether another process occupies port 49731. Temporary Safari extensions must be reinstalled after they expire.

Ad-hoc builds change signature on rebuild. If macOS stops recognizing an existing Accessibility or Screen Recording grant, remove the old entry and add the newly installed app. An optional stable signing certificate can be selected with `MOONSHINE_SIGN_IDENTITY`; you do not need one to build locally.

## Optional OpenAI refinement

Ordinary search needs no API key. For semantic matching, use your own OpenAI Platform API key with access to the Decisions API and available API billing/credits. A ChatGPT or Codex sign-in is not used by Moonshine. API access and charges depend on your account.

1. Create a private directory and empty file outside the checkout:

   ```sh
   mkdir -p "$HOME/.config/moonshine"
   chmod 700 "$HOME/.config/moonshine"
   (umask 077; touch "$HOME/.config/moonshine/openai.env")
   chmod 600 "$HOME/.config/moonshine/openai.env"
   open -e "$HOME/.config/moonshine/openai.env"
   ```

2. In the editor, write `OPENAI_API_KEY=YOUR_API_KEY_HERE`, replacing the placeholder with your own key. Save and close the file. Entering it in an editor avoids putting the key in shell history. Do not share the file.
3. In Moonshine Settings, choose **Choose key file…** and select that file. Hidden files are shown.
4. Read the adjacent disclosure, then turn on **Refine matches with OpenAI Decisions**. Turning it off cancels pending refinement and leaves local matching available.

The implementation uses `gpt-6-luna` at `https://api.openai.com/v1/decisions`. If your account cannot use it, local search continues and the app reports refinement as unavailable. No shared credential is supplied. Do not put keys into source files, browser pairing fields, issues, screenshots, or pull requests.

For explicitly authorized developer smoke testing only, `moonshine-check` can read `.env.local` from its working directory or `OPENAI_API_KEY` from its process environment. After a release build, `.build/release/moonshine-check --live-smoke` sends synthetic metadata through a real API request. This is not part of the ordinary test suite. Real-data evaluation with `--evaluate` or `--live-workspace-eval` can send actual metadata; review and authorize that separately.

## Update

Quit Moonshine from its menu bar, then run from your clone:

```sh
git pull --ff-only
./scripts/install.sh
open "$HOME/Applications/Moonshine.app"
```

The app retains preferences and separately stored credentials. Reload unpacked browser extensions after their source changes. Both apps must include search-handoff support to use the [Spleen connection](INTEGRATION.md).

## Remove

Quit Moonshine and move `~/Applications/Moonshine.app` to the Trash. Remove its extensions through each browser's extension settings and revoke any macOS permission grants you no longer want. You can delete the source clone separately. Preferences and any key file you created remain unless you remove them yourself; a key may also be used by another app.
