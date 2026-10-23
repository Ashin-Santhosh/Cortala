# JustWisper and Glaido: feature comparison

Reviewed 23 October 2026. The table is the baseline before the newly requested workflow feature; see the update below. Glaido entries summarize its own public documentation; the competitor was not installed or independently tested. JustWisper entries come from this workspace, regression evidence and the user's reported live acceptance. Feature presence does not establish equivalent usability, speed, recognition quality or security.

| Area | Glaido, as documented | JustWisper, current implementation |
|---|---|---|
| Desktop platforms | macOS and Windows 11 | macOS only; packaged build is Apple Silicon |
| Dictation and insertion | Keyboard-triggered capture, cleanup and insertion into another app | Toggle/hold shortcuts, guarded auto-paste, raw or formatted modes; Codex insertion confirmed by user |
| Recognition location | Audio is sent to its service for Whisper transcription | Apple on-device Fast mode, local whisper.cpp, or explicitly configured cloud speech |
| Provider choice | Managed service described; user-supplied recognition backends not established in reviewed pages | Separate local/cloud speech and language routes, with per-mode overrides |
| Languages | Broad multilingual support advertised | Depends on the selected engine and installed assets; no claim of equal language coverage |
| Specialized vocabulary | Dictionary and spelling preferences | Recognition hints, optional whole-word substitutions, CSV import/export and reviewed correction suggestions |
| Reusable expansions | Spoken text shortcuts | Snippets |
| Formatting by destination | Default style plus application/website-specific rules | Modes, instructions/tone, app/site matching and per-mode language providers; simpler matching interface |
| History | Stored dictations, playback, retry, keyboard navigation and voice-assisted retrieval | Searchable History, playback/retry when audio is retained, editing/export; no semantic voice-history search |
| General command assistant | Spoken requests can use bundled web, file, calculation and image tools | No general voice-operated web/file assistant; selected-text transformations and transcript-grounded meeting questions only |
| Tool extensions | Imports tool servers and calls them from its assistant | A default-off CLI/MCP server exposes a fixed set of app controls; it does not act as a general tool-server client |
| Spoken activation | A leading product-name phrase changes a dictation into a command | No corresponding command-activation feature |
| Clipboard features | A searchable local clipboard archive and approved image questions are documented | Optional three-second plain-text context, not a persistent clipboard archive or image-analysis feature |
| Meetings | Dedicated meeting diarization/live translation not established in the pages reviewed | Microphone/system/mixed audio, meeting templates/Q&A, anonymous offline speaker labels and provisional live translation |
| Video | No conclusion from reviewed pages | Not implemented; user explicitly paused video work |
| Guidance | Written guides and command-based help | New first-run walkthrough, permanent Help & Tutorial, permission links and explanations |
| Privacy controls | Local history and service-retention claims; technical crash-report collection is disclosed | User-selectable local/cloud processing, Keychain keys, optional authenticated transcript vault, explicit context/automation choices; no security-certification claim |
| Release maturity | A marketed download with account/subscription support | Personal development build; public licensing, identity signing/notarization and broader acceptance remain release work |

Glaido platform, personalization and general feature descriptions: [documentation overview](https://glaido.com/docs). Its recognition guide explicitly describes server-side transcription, so local history should not be mistaken for fully offline processing: [dictation processing](https://glaido.com/docs/features/dictation). Destination-style details: [formatting rules](https://glaido.com/blog/formatting-rules-for-how-dictation-lands-on-the-page).

The assistant/clipboard rows come from [built-in command documentation](https://glaido.com/docs/features/built-in-commands), [custom extensions](https://glaido.com/docs/beta/tools), and [spoken activation](https://glaido.com/docs/features/voice-activation). These are different capabilities from JustWisper's fixed local automation interface, even though both mention MCP. No Glaido tool installation instructions were executed.

Privacy statements are vendor claims, not independent validation. Glaido's [privacy policy](https://glaido.com/privacy-policy) discloses optional record reports and technical crash reporting enabled until switched off; its [home page](https://glaido.com/) advertises retention/security claims. JustWisper's transcript vault does not encrypt separate audio, exports, old backups or synced configuration, and the development binary is not sandboxed/notarized.

## What to prioritize for JustWisper

1. Finish dependable capture, silence handling, focus-safe insertion and clear provider/permission setup before adding a general assistant.
2. Improve dictionary usability: preferred spellings, reviewable mishearings and context-specific hints. Existing basic vocabulary works without retraining.
3. Add a fast searchable navigation/history launcher if needed, without confusing text lookup with semantic voice search.
4. Treat general web/file/image tool execution as a separate security-sensitive project with explicit capability and approval design.
5. A Windows/Linux port is a separate platform effort. Video remains paused, as requested.

No recommendation here depends on unmeasured claims of faster transcription or greater accuracy. The newly added welcome/tutorial and security controls were authorized independently of this comparison; this document does not authorize additional feature implementation.


## Requested workflow update

After this baseline comparison, the user authorized customizable workflows. JustWisper now implements an explicit command recorder with exact phrase matching, ordered app/website/search/wait actions, automatic execution after explicit command capture, and versioned JSON sharing. Imports receive new identities and are disabled for matching. All 132 regression tests pass; final installed UI acceptance is tracked separately. This is a deterministic action builder, not a general web/file/image assistant or tool-server client. It does not close windows or automatically start ChatGPT Voice. See [voice workflow guide](voice-workflows.md).
