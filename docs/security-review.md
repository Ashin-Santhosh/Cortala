# JustWisper security review

Reviewed 2026-10-23. Source review covers command entry points, provider transport/credentials, local subprocess execution, model installation, automation, storage/sync and packaging. Installed app inspection used `file`, `codesign`, `otool`, hashes and text inspection only; it did not run its executable or recording engine. No microphone/system capture, personal Library/history inspection, private recording access, credential retrieval or network uploads were performed. Video work remains paused.

**Result:** one concrete high-priority authorization issue was identified in custom URL commands. Two bounded hardening changes were implemented here for subprocess environment and model download size. No suspicious hidden launcher, arbitrary download-and-execute path or unrelated exfiltration destination was found in the reviewed source and installed bundle inventory. This is not a malware-free assurance: the review is static and selective, native dependencies were not comprehensively audited, installed binaries were not reproducibly matched to source, and the installed development app predates concurrent hardening work.

## Findings

### P1: external URL commands can start and finish recording without an in-app approval

At the reviewed baseline, `JustWisperApp.swift:27–28` dispatches `justwisper:` URLs to `AppStore.swift:204–222`. `executeCommandURL` directly handles start/toggle/stop/cancel after syntax validation. There is no local-automation opt-in or per-command user approval in this path. With microphone permission already granted, an external link can request capture; a later stop can trigger the configured transcription provider and text cleanup. Browser external-app prompts are not a dependable app authorization boundary. Strict URL parsing prevents parameter confusion but does not establish who authorized recording.

**Fix requested from the main implementation:** require explicit in-app confirmation for recording-affecting external URLs, or disable those actions by default behind deliberate opt-in. Do not silently treat a browser launch as a hotkey. Include stop/cancel and mode changes in the policy so an external link cannot choose a cloud route or terminate an unrelated recording. Re-check final source and tests after integration. No external URL was invoked during this review.

### P2: inherited process environment could alter the chosen local runtime

`ProviderServices.swift` launches a configured executable using `Process.executableURL` and argument arrays, avoiding shell string interpolation. Previously it inherited all environment variables, including dynamic-loader and GGML backend overrides. The generated bundled shell launcher also invoked `dirname` through inherited PATH. This primarily affects an app launched from an attacker-influenced environment or user-written wrapper; it does not establish a remote compromise route by itself.

**Implemented:** internal `LocalProcessEnvironment.sanitized(_:)` removes `DYLD_*`, `GGML_*`, `LD_PRELOAD` and `LD_LIBRARY_PATH`, sets a system-only PATH, and supplies that environment to the child process. Executable path and arguments are unchanged. `scripts/bundle-whisper.py` now generates `/usr/bin/dirname`. Existing installed launchers must be rebuilt/repackaged to receive that fix. User-written executable wrappers should use absolute tool paths if they require Homebrew commands; safe PATH can intentionally change short-name tool lookup. This is defense in depth, not a sandbox for arbitrary executables the user selects.

### P2: Whisper model download could exceed its expected size before rejection

`ModelDownloadService.swift` verified size and SHA256 after the complete payload was downloaded, but did not pass the known expected size to its download delegate. A compromised/misbehaving host could consume excess disk space before checksum rejection despite initial free-space checks.

**Implemented:** the delegate receives `maximumBytes: verified.byteCount` and cancels when announced or received bytes exceed that limit. The existing exact size/SHA256 installation checks remain. This is a bounded download cap; URLSession can buffer a small amount before a progress callback. Focused tests use suspended tasks without network requests to exercise received-byte and announced-size cancellation.

### P2: private transcripts have filesystem permissions, not independent encryption at the reviewed baseline

At audit time, the library/history JSON and backups were stored as readable plaintext for the current user, with intended 0700 directories and 0600 files. Audio recovery and explicit retention can leave additional managed recordings. Those controls separate OS users; they do not protect against another process with the same user's filesystem access, an unlocked account or plaintext exported copies. Keychain storage protects API credentials separately. The main task is considering encrypted storage; this report does not certify an encryption implementation or migration. Any such change needs tests for locked Keychain, authenticated-decryption failure, existing backup migration, recovery and explicit exports.

## Reviewed boundaries and residual risks

- **Provider credentials and transport:** `ProviderHTTP.validate` permits HTTPS or loopback-only plaintext HTTP, rejects URL userinfo, and uses an ephemeral URLSession that refuses all redirects. Request errors avoid echoing response bodies. Native provider keys use headers. Keychain accounts are scoped to normalized origins and connection IDs; changing origin requires a separate key, and empty connection keys do not borrow defaults. These are useful existing controls. HTTPS custom endpoints still receive the text/audio the user chooses to send; no domain allowlist is implied.
- **Configuration imports/sync:** merge preserves local executable/model paths and local privacy/automation permissions. Shared configuration can still change speech/text routes and mode instructions. A shared folder is therefore trusted configuration input: someone able to replace its file can redirect future *content*, even though origin-scoped credentials prevent forwarding the old host's key. Consider showing/confirming destination changes before activating incoming provider configuration. This is not a claimed automatic credential leak.
- **Local automation:** disabled by default; private on-disk inbox, no network listener in the reviewed implementation. Requests have UUID filenames, limited size and lifetime, an action allowlist, and `O_NOFOLLOW`/`fstat` checks for regular files, current ownership and private mode. The contract intentionally trusts other same-user programs when enabled. Directory creation/atomic writes use path-based Foundation APIs rather than descriptor-relative traversal, so this is not a race-proof boundary against a hostile same-user process. Do not advertise it as one.
- **File paths:** generated recording filenames use UUIDs and restricted extensions; managed recording deletion checks directory membership/recorded ownership rather than deleting arbitrary imported originals. User-selected meeting/sync directories can intentionally be shared or managed by a file provider. Source checks do not make those user-selected folders a protected vault. No exploitable cross-user write was demonstrated in this review; directory/file checks and subsequent writes are not universally atomic against local path replacement.
- **Model supply chain:** Whisper catalog fixes filenames, expected sizes and SHA256; source URL uses mutable `main`, so changes should fail closed but may break availability. Prefer immutable revisions. Diarization allowlists filenames, pins revision `7eab74f…` and exact size/hash, rejects symlink model files and initializes FluidAudio directly with verified local models rather than its download helper. Hashes identify expected bytes, not harmlessness of native model parsing. Current redirect rules limit downloads to HTTPS Hugging Face domains; provider requests do not use those redirect rules.
- **Build scripts:** inspected scripts perform local compiler/cache work, packaging, library relocation and ad-hoc signing. `swift-env.sh` uses SwiftPM `--disable-sandbox` for local toolchain workarounds. This broadens trust in dependency manifests/build behavior during development; retain only if needed and prefer a clean supported Xcode toolchain for release CI. No curl-to-shell/bootstrap installer was found in the reviewed scripts.
- **Persistence/capture:** launch at login uses `SMAppService.mainApp` after explicit setting changes. Source includes the expected microphone, system audio, speech, calendar and Accessibility capabilities. No separate LaunchAgent, launchctl persistence, network listener or unrelated command runner was found in the searched source. This does not replace runtime/network monitoring.

## Dependency evidence

`Package.swift` pins FluidAudio 0.17.7, traits disabled. Local checkout HEAD is `503b4bd1bbf7220882de39fe8ae6716aae4132da`, matching `Package.resolved`; its worktree had no reported modifications. The Swift 6.2 manifest gates the NeMo prebuilt Rust component behind its trait, which this app opts out of. The older upstream manifest always links that component, so keep Swift 6.2+ as the documented build requirement. A cached artifact directory alone is not proof that an artifact is linked. FluidAudio's offline diarizer path and manifest were inspected selectively, not its entire large ASR/TTS codebase. No vulnerability-database or full transitive source audit was completed, and the package revision alone is not a security endorsement.

## Installed application snapshot

Path: `~/Applications/JustWisper.app`, observed during the audit before later rebuilds. Main executable SHA256: `f451f1ad136fc026299fe007762f88f27afd75f5b830477cfe79c310d31804da`.

Unique native payloads found:

- `Contents/MacOS/JustWisper` and `Contents/Resources/bin/whisper-cli-native`.
- Nine runtime libraries/backends: libwhisper 1.9.4; libggml and libggml-base 0.24.0; libomp; GGML BLAS, Metal and CPU Apple M1, M2/M3 and M4 plugins.
- Backend entries beside the launcher are symlinks into the bundle's Frameworks directory. No symlink resolving outside the bundle was found.
- Text helpers are the expected bundled whisper shell launcher and CLI Python integration tool. No extra helper/XPC/login/plugin-named payload was found in the inventory search.

All inspected native payloads are ARM64 and ad-hoc signed; no TeamIdentifier is present. `codesign --verify --deep --strict` returned success for the installed bundle. Linked dependencies were Apple system libraries/frameworks or relative `@rpath` GGML/runtime dependencies; no linked absolute Homebrew or unrelated third-party library path was found in that inspection. Signature integrity verifies consistency with its ad-hoc seal, not publisher identity, notarization or source correspondence. No unknown binary was executed. Production releases should add Developer ID signing, hardened runtime/notarization and a component/version/hash manifest.

## Implementation and verification handoff

This audit agent changed only `ProviderServices.swift`, `ModelDownloadService.swift`, `scripts/bundle-whisper.py`, the new `Tests/JustWisperTests/LocalRuntimeSecurityTests.swift` and this report during the security task. Tests cover environment override removal and oversized suspended-download cancellation; no build/test run was performed here while the main implementation was changing shared files. The main task owns URL authorization, storage encryption, setup/UI changes, integrated validation and rebuilding the installed app. Reconcile those changes before treating any baseline finding as closed.

### Release inventory hardening (implemented, actual package audit pending)

The release scripts now generate `Contents/Resources/runtime-manifest.json` after signing each runtime payload. Every runtime native file requires a versioned Homebrew source package with its own publisher license; unknown source layouts or missing component licenses fail closed. The manifest records relative bundle destinations, package/version, input/output SHA256, dependencies/rpaths and relative publisher notice files with notice hashes. It deliberately excludes personal source paths. Source package provenance is inferred from the versioned Cellar layout, not authenticated as a reproducible upstream build.

New CLI: `python3 scripts/audit-bundle.py /absolute/path/JustWisper.app`. It checks manifest structure, runtime and notice hashes, exact native inventory (apart from the expected main executable), internal symlink targets, relative/system-only loader paths and resolved bundle dependencies, then uses `/usr/bin/codesign --verify --deep --strict`. It never executes the app or speech engine. The package script signs only the outer app after runtime hashes are recorded and invokes this audit before creating its ZIP. The `--without-engine` path has an explicit empty runtime inventory and therefore rejects stale native runtime files. Absolute `/usr/bin` tools are used for binary inspection/relocation/signing.

Python/shell syntax checks and isolated synthetic inventory checks passed (valid empty runtime inventory, rejected unexpected Mach-O payload, rejected escaping symlink; external inspection/signing calls stubbed in fixtures). No real rebuild/package/audit was run by this agent while the main implementation was active. Verify the final generated package and manifest before claiming this gate has passed for the actual release. A self-consistent manifest plus ad-hoc signature is a bounded inventory/integrity check, not publisher authentication, malware analysis or notarization.


### Integrated package verification

The main implementation completed the integrated acceptance pass: 123 Swift tests, eight Python checks and a public-audio local runtime smoke test passed. The actual package and cleanly replaced installed app passed the new native inventory, notice/hash, symlink, loader-path and strict signature audit. The gate found obsolete notices retained by a merge-style installation; clean whole-bundle replacement resolved the signature failure. This verifies bounded package integrity, not independent malware analysis, publisher identity or notarization. Welcome and persistent help controls were verified in the native interface. Vault migration remains user opt-in; the installed personal library was not encrypted as part of UI testing.
