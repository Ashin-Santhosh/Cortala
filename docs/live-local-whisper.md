# Live local Whisper on Mac

This update recognizes audio with local whisper.cpp rather than Apple Speech when Fast → Local Whisper is selected. The first-party resident helper loads the existing GGML model, receives bounded microphone/meeting PCM windows and returns provisional timed text. Apple Speech remains an explicit alternative. The helper is built against the existing pinned whisper.cpp 1.9.4/GGML 0.24.0 runtime; packaging inventories it alongside the licensed runtime libraries.

## Readiness and latency

Warm local Whisper at launch keeps the model resident until Release memory, a model/language change, or Quit. Warm now works independently of the launch preference. A passive overlay reports Warming, Ready or a load failure; Home retains the detailed model state. Ready comes from the helper's actual ready response, not a timer.

Public-JFK fixture measurements on this development Mac:

| Run | Model startup | Median warm window inference |
|---|---:|---:|
| Cached development helper | 0.63 seconds | 0.88 seconds |
| Initial relocated packaged helper | 24.06 seconds | 0.95 seconds |

The initial run included graphics/backend initialization. Cached startup is not guaranteed after updates or cache changes. Warm inference excludes the capture cadence, recording startup, finalization, formatting and paste. The current sequential window loop waits about 1.5 seconds between requests, so these measurements do not mean individual words appear in one second. The fixture repeats one short public recording; its zero final word error rate is not representative accuracy evidence. See benchmarks/results/live-jfk-medium*.json.

## Capture and recovery

The recorder retains the full audio and supplies bounded overlapping snapshots to one inference request at a time. Recent provisional text can change. Stable earlier words are committed conservatively; an exact final snapshot includes the last capture callbacks. Complete coverage can finish through the resident final tail. Missing/gapped/truncated coverage or a decoder failure uses the existing saved local audio recovery rather than treating an incomplete preview as complete. There is no automatic cloud-audio fallback. Quiet no-speech dictation remains a no-op.

Model memory remains allocated while resident, beyond the approximately 1.53 GB file on disk. Release memory is available in Home. Re-selecting an incompatible model/language requires warming again.

## Meetings and translation

Choose Local Whisper as the caption engine for meeting previews without Apple Speech. Meeting source selection still controls microphone/system/mixed audio; final meeting processing uses its separately selected speech route.

Translation is separate from speech recognition. Meetings offers Apple on-device translation or the saved default language-model provider from Configuration. Prepare languages installs Apple assets or validates the configured language-model route. The active translation session/warm request begins only with a translation-enabled meeting. Stop cancels it and rejects late results; changing the text provider requires preparation again. A shared Ollama process controls its own model retention; JustWisper does not forcibly unload models used by other apps.

Language-model translation sends bounded recent caption text to the configured endpoint, including cloud endpoints if explicitly chosen. It is not audio translation inside the speech model, and captions can lag/revise. Cloud usage may incur provider charges. Original meeting audio/transcripts remain the recovery source; provisional translated captions are not a complete saved translation of the whole meeting.

## Limits and acceptance

The current bundle is a personal Apple Silicon development build. The installed runtime libraries were built on this Mac and carry newer macOS deployment requirements; do not infer older-macOS support from the Swift package's minimum alone. Windows/Linux work is deferred at the user's request. Longer live microphone/meeting sessions, multi-monitor window placement, and language-model translation latency need live user acceptance beyond fixture tests.


### Translation path verification

The standard local Ollama route uses its native chat endpoint with reasoning disabled and output bounded to 512 tokens. Other providers keep their configured endpoint/protocol with a bounded response. The local Qwen3 8B test translated a public English sentence to German in 0.98 seconds after warmup. The earlier generic thinking-enabled path consumed about 20 seconds without final text within its test token budget; that path is no longer used for the standard local Ollama translation route. This is a single sentence, not sustained meeting throughput. Request controls follow [Ollama's official API documentation](https://github.com/ollama/ollama/blob/main/docs/api.md).


The final installed UI reported 22.53 seconds for an initial startup and 0.16 seconds on a later cached launch. Live → Local Whisper was selected for the user's next test. Stop captures the destination field; unavailable destinations offer a three-second copy overlay that pauses on hover. Genuine failures are available in the nonmodal session Errors page. No live microphone or multi-monitor placement test was performed by the agent.
