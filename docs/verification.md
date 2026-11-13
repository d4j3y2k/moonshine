# Verification

## Public-source preparation — November 13, 2026

The shared source contains fictional fixtures and synthetic previews. Local credentials, raw desktop-testing notes, real browsing labels, diagnostic logs, evaluation data, and build products are excluded. Earlier machine-specific verification notes remain in an ignored local backup and are not part of this repository.

The publication review covers the source allowlist, documentation, image pixels and metadata, credential-like patterns, and the browser/handoff privacy boundaries. Gitleaks and an exact-match check against locally configured credentials are used without printing credential values. Secret scanners do not establish absence of every sensitive string or vulnerability.

Validation for this source preparation passed **60 Swift tests**, **17 JavaScript tests**, the release build/signature check, and the native fixture suite. The per-user installer passed isolated installation, update, path-with-spaces, running-app refusal, symlink refusal, and unrelated-bundle refusal checks. Final Gitleaks source scanning and exact local-credential matching found no secrets.

## Repeatable local checks

```sh
./scripts/test.sh
./scripts/build.sh
mkdir -p build/verification/public
build/Moonshine.app/Contents/MacOS/Moonshine --demo --self-test "$PWD/build/verification/public"
```

The package suite covers local matching, exact selection, stale semantic results, URL sanitization, bounded page context, private-tab exclusion, bridge authentication and expiry, layout, and query-handoff parsing. The JavaScript suite covers browser lifecycle, command acknowledgements, permission removal, navigation races, private-state rejection, and the page-label collector. Native fixture checks cover filtering, keyboard selection, query clearing, closed targets, exact Unicode handoff, caret placement, marked-text composition, held Tab suppression, failed-dispatch recovery, and late callbacks.

These checks use synthetic data and injected transports. They do not send requests to OpenAI or activate real destinations. Native tests need a logged-in macOS desktop and access to the window server. Test output and generated images stay under ignored build directories.

## Limits

Tests were run on Apple silicon with macOS 26 and Xcode 26. Older macOS versions, Intel builds, representative multi-Space/full-screen behavior, third-party Accessibility implementations, and broader Safari lifecycle/profile/page-context behavior still need acceptance testing. The app has no notarized distribution, and Safari currently uses temporary development installation.

Historical desktop checks exercised ordinary Chrome/Safari exact-tab activation and warm/cold search transfers. Automated handoff checks use injected dispatch; they do not substitute for testing both installed apps with actual keyboard focus and the current macOS permissions. No universal latency or compatibility claim is made.

## Privacy defaults

A fresh installation starts with OpenAI refinement and richer page context off. Source builds include neither a key nor an author-specific credential path. Existing explicit refinement preferences remain in effect; installing a new build does not erase preferences or saved credentials.
