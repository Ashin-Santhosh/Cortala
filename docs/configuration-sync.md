# Configuration folder sync

Choose a folder managed by your existing file-sync provider. JustWisper writes configuration JSON files there; it does not provide a hosted account, transfer service, or cross-device credentials. Sync is off by default. Keep the folder's contents private if modes, vocabulary, snippets, or provider connection details contain sensitive information.

Manual publishing checks the previously inspected shared file's SHA-256 before replacement. A changed or unreviewed file produces a separate local conflict snapshot and leaves the shared file intact. Pulling backs up the local library before applying shared configuration. Settings for history, retained audio, context capture, correction learning, local automation, login items, meeting audio source, speaker separation enablement, microphone device, sync folder, local executable, and local model paths remain specific to each Mac. Keychain keys are never encoded in configuration snapshots.

Automatic sync requires an explicit initial source: this Mac publishes its configuration, or the shared configuration is applied to this Mac. A saved baseline permits resuming the same folder on later launches. While enabled and the app is running, a two-second poll detects changes. A single changed side propagates; independently changed sides or divergent revision histories pause sync and preserve a separate local conflict snapshot. Recording and processing defer applying remote changes until the app is idle. Resolve a conflict by reviewing the preserved files and explicitly choosing the initial source again.

`JustWisper-configuration.json` is the current shared snapshot. Immutable `JustWisper-revision-*.json` files retain revision ancestry across provider races, `JustWisper-previous-*.json` files retain replaced shared snapshots, and `JustWisper-local-conflict-*.json` files preserve local conflicts. Keep revision files with the canonical file so another Mac can validate ancestry. These files are not automatically pruned. Missing, malformed, unsupported-version, oversized, or hash-mismatched snapshots are not applied. The inbound and outbound limit is 5 MB. Cross-device file providers can delay or reorder delivery; an unavailable parent revision conservatively pauses sync instead of assuming a winner.

Local baselines are saved with private permissions under `Application Support/JustWisper/SyncState`. The automatic tests substitute temporary local folders for both Macs and never access a cloud folder.

## Acceptance checks

1. Start two independent installations with separate application-support directories and the same disposable shared folder. Choose this Mac as the initial source on A and the shared source on B. Edit vocabulary on A and confirm B converges while its own local model path, microphone choice, history, and privacy choices remain unchanged.
2. Edit vocabulary on B and confirm A converges. Close B, edit A, reopen B with automatic sync enabled, and confirm the saved baseline resumes without another source selection.
3. Start recording on B, change configuration on A, and confirm B waits until recording and processing finish before applying it.
4. Edit both configurations before the next poll. Confirm sync pauses, the current shared file is preserved, and the local conflict snapshot contains the other edit. Review both before explicitly choosing a source.
5. Delete, corrupt, or temporarily remove the shared file. Confirm local settings remain intact and the status explains that sync is waiting. Restore a valid current revision or explicitly choose a source to resume.
6. Revert the canonical file to an older revision after both Macs have accepted a newer revision. Confirm sync pauses rather than rolling back local settings. Test provider-specific offline, delayed-parent, and conflict-copy behavior before relying on this workflow.

Automated coverage includes two-machine convergence across multiple revisions, resume, simultaneous-edit conflicts, busy deferral, rollback detection, local privacy/path preservation, missing initial baseline, and outbound size rejection. Run the Swift test suite to verify these paths. Real cloud-provider behavior requires the acceptance checks above.
