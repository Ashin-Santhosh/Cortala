# Live meeting translation

Meetings offers opt-in Live translation with From and To selectors populated from Apple supported languages. Prepare languages asks the system to download any missing language pair; the app checks that models are installed before showing Ready. Requires macOS 15 or later and supported on-device speech recognition for the selected source.

The app keeps a TranslationSession alive, coalesces incoming caption snapshots to at most one request per 0.8 seconds, and translates only the most recent 480 characters. It never queues an entire growing meeting. New language sessions and stopped recordings reject late results. Original and translated recent captions are displayed separately, explicitly provisional. After Stop, the original complete audio goes through the selected final speech model and optional speaker separation; live translations are not a full translated transcript saved in History.

Live translation uses Apple Translation locally and does not use Ollama or automatically upload audio or caption text to cloud providers. Apple Speech remains the live caption source: its interruptions can affect translated previews, so the original recording continues and warnings remain visible. This is not proof of sustained real meeting reliability.

## Evidence

- Full suite: 99 tests across 23 suites passed, including queue bounds/coalescing, persisted opt-in language settings, late session/capture results, and visible translation failures.
- Actual installed English-to-German TranslationSession translated 20 consecutive public sample sentences in 1.794 seconds total, including initial session work. This measures translation only, not microphone-to-caption latency or linguistic quality.
- Final readiness verification requires installed language assets. The updated app was installed at the existing user Applications location; Meetings Live translation, English/German From/To selectors, and Prepare languages were exercised through the native UI. The system session returned Languages ready. No microphone or system audio recording was started during this check.
- Real long meeting speech, multilingual caption quality and end-to-end live latency need user acceptance.

Apple references: [TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [Prepare translation](https://developer.apple.com/documentation/translation/translationsession/preparetranslation()), [Translating text within your app](https://developer.apple.com/documentation/translation/translating-text-within-your-app).
