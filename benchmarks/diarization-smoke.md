# Local speaker pipeline smoke

Verified 2026-10-22 on this Mac (macOS 26, Apple Silicon) with FluidAudio 0.17.7 and pinned FluidInference CoreML models at `7eab74f3463c736418d0eb10296261ae581146c9`.

Run `JUSTWISPER_DIARIZATION_SMOKE=1 scripts/test.sh --filter DiarizationTests` with normal macOS system-service access. The opt-in test uses `/usr/bin/say` to generate unplayed temporary speech with the installed Samantha and Daniel voices, concatenates four alternating turns, runs the actual segmentation/embedding/VBx model pipeline, and removes the fixture. It uses no microphone, remote speech recognition, or downloaded voice assets.

Observed: approximately 40 seconds of audio; two anonymous clusters; four turns correctly mapped A/B/A/B; dominant-speaker coverage 100% for each turn; inference 6.28 seconds. This demonstrates genuine model execution and turn separation on synthesized speech. It does not establish speaker accuracy on real meetings, overlapping human voices, or noisy recordings.

The model downloader pins SHA256 and byte size for every asset and publisher notice. It does not use FluidAudio's automatic downloader. Models and terms: https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9 . Notices are copied into the app and downloaded alongside the model assets.

Offline diarization requires macOS 15 or later due to the upstream documented macOS 14 BNNS crash. Word timestamps are not invented: existing ASR segment times are retained, majority speaker overlap labels a segment, and substantial competing speech is marked `Multiple speakers`.
