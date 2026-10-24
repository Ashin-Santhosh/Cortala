# Experimental website download preparation

Prepared 2026-10-24. No website upload, GitHub publication, Apple submission, or installation over the user's app is part of this preparation.

## Privacy review

- Gitleaks 8.30.1, obtained from its official release and verified against its published SHA-256, scanned the available Git history: no credential leaks detected.
- A separate allowlisted source snapshot was scanned: no credential leaks detected. Models, recordings, credentials, local tooling, build caches, dependency checkouts and generated applications are excluded.
- Personal development-directory paths were removed from the current benchmark report. Release builds remap compiler source paths and no longer discover models through the developer's source directory.
- The existing private Git history still contains historical benchmark paths and normal author email metadata. The publication candidate intentionally excludes `.git`; publish that reviewed snapshot with a deliberate public author identity rather than blindly uploading this workspace's private history.
- These checks detect known secret patterns and selected metadata. They are not proof that every possible confidential value is absent. Review the selected filenames, changes and final archive before publication.

## Mac download

The bundled Homebrew speech libraries require **macOS 26**, despite the application's own macOS 14 deployment target. Packaging derives the final minimum version from the bundled native executables and libraries. This candidate is for **Apple Silicon only**. Earlier macOS releases and Intel Macs are not supported claims.

The app is ad-hoc signed and not Apple-notarized. The DMG is an experimental evaluation candidate. Microphone, Accessibility and system-audio permissions remain user-controlled. Speech models and Ollama are not bundled; first-use model/provider setup is required. The app does not ship the developer's settings, recordings or API keys.

Validation: all 152 Swift regression tests passed after release-path changes. The package passed its native inventory, dependency-path, notice-hash and code-signature audit. The created DMG passed image verification; its mounted app passed the bundle audit and personal development-path scan. A SHA-256 sidecar uses the public filename rather than a local absolute path. A clean installation on another supported Mac remains a release acceptance item.

## Licensing decision

The final selected license is **GPL-3.0-only**, with copyright attributed to **CortexKinematics** (one word, capital K). It permits commercial redistribution and requires corresponding source under its terms. Earlier resale restrictions were superseded by this explicit GPLv3 choice. LICENSE contains the complete GPLv3 text; COPYRIGHT states its first-party scope. Third-party licenses and notices remain unchanged.

Before public binary distribution, provide the complete corresponding source and build materials required by the GPL, including the necessary exact dependency sources or compliant equivalent source access. The first-party source snapshot and pinned manifests are preparation artifacts, not a completed assessment of corresponding-source compliance for every bundled component.

## Windows and Linux

The separate desktop port passed 17 backend tests and rendered successfully in an isolated Mac preview. Linux x64 speech executables and an Electron package were built, and the Linux recognizer transcribed the public JFK fixture successfully in Docker. This is not full desktop/hardware acceptance. Windows cross-compilation failed on missing MinGW Windows API declarations; a native Windows CI job is prepared but has not run. Mobile and video work remain on hold.
