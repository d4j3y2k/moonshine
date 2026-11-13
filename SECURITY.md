# Security

Moonshine is experimental software. Local matching works without an API key. OpenAI refinement and richer page labels are off by default; enabling them changes what data can leave your Mac. Read the [privacy description](README.md#privacy) before opting in.

## Report a vulnerability

Use this repository's **Security → Report a vulnerability** feature for a private report. Do not post keys, pairing codes, personal screenshots, real browsing inventories, or exploitable details in public issues. Use synthetic examples and redact machine paths and identifiers from logs.

## Boundaries

- Exact native-window or browser-tab identities are resolved again before activation; model responses cannot supply commands or destinations.
- The browser bridge binds to IPv4 loopback, checks the host and origin, requires a random pairing credential, and bounds request sizes and lifetimes. Keep the pairing code private.
- Private browser tabs and unknown privacy states are excluded by the extension. A compromised browser/extension or a process running as the same macOS user is outside this isolation boundary.
- Optional page context excludes forms and full bodies, but page labels can still be sensitive. URL sanitization does not anonymize titles or paths.
- Search-handoff URLs accept untrusted local input. They transfer search text, not a command to open a result. Receiving-app settings still govern any remote refinement.
- Credentials are supplied per installation. The public source and build do not include API keys, pairing codes, personal state, or an author's credential-file path.

## Before publishing changes

Review the full staged diff, not only ignore rules. Keep `.env*`, local evaluations, `.local-state/`, build outputs, and diagnostic evidence untracked. Use fictional test data and inspect image pixels and metadata. Scan the candidate source and all reachable Git history with a secret scanner such as Gitleaks, and review findings locally without copying secrets into reports. Use a GitHub no-reply commit email when personal email privacy matters.

A scan can miss secrets and personal context. It complements source review, privacy-boundary tests, and platform permission checks; it does not establish that all vulnerabilities are absent.
