# Reproducible accuracy evaluation

Current scope: evaluate JustWisper independently. The user declined a Wispr Flow comparison for now; optional baseline support remains available for future evaluator-supplied comparisons and is not a current acceptance requirement. Public-fixture results do not establish accuracy on the user's private speech.

`tools/benchmark.py` evaluates user-supplied recordings with local `whisper-cli`, or compares existing transcript text. It creates no recordings, uses no cloud endpoint and downloads no model. The report includes every case, including malformed manifest rows, failed inference, timeouts and failed assertions. Corpus WER covers measured cases only; the report separately shows processing failures and coverage so a partial successful subset cannot imply a complete pass.

The bundled manifest `public-jfk.jsonl` points to whisper.cpp's public JFK sample at its usual Apple Silicon Homebrew location. Change `audio` to your installed fixture location when needed. It is a pipeline smoke fixture, not a representative voice benchmark. The audio is not copied into this repository.

```sh
python3 tools/benchmark.py \
  --manifest benchmarks/public-jfk.jsonl \
  --model Models/ggml-medium.bin \
  --cli /opt/homebrew/bin/whisper-cli \
  --output benchmarks/results/jfk.json \
  --max-wer 0.25
python3 -m unittest discover -s tools -p 'test_*.py'
```

Local runs record the model, executable, manifest and audio SHA-256 hashes; runtime help/version identity; exact inference arguments; platform; per-case language; raw hypothesis; and inference time including model loading. The configured executable path is used for launching, including symlinks and wrappers, while `executable_resolved` separately records the target path. This preserves runtimes that locate assets relative to their launch path. Runtime help is best-effort with a three-second timeout; a help timeout does not skip fixture inference. Four threads and temperature zero are explicit defaults. Hardware and runtime differences can still affect results. Median and interpolated p95 include available recorded timings; a single fixture has one timing sample and is insufficient for a latency claim.

A JSONL manifest has one object per line:

```json
{"id":"names-and-numbers","audio":"recordings/case01.wav","reference":"Send the invoice to Ashin for 42 euros","language":"en","expected_terms":["Ashin"]}
```

Paths are relative to the manifest. Baselines are optional, must be supplied by the evaluator, and are recorded with their provided metadata. `expected_terms` checks complete normalized word sequences. Numeric assertions compare digit forms and counts; they intentionally flag `42` versus `forty two` for human review rather than asserting semantic equivalence. WER uses Unicode letter/number tokens after NFKC normalization and case folding. CER uses normalized letters/numbers, omitting punctuation and spaces. These definitions are included in each report.

For existing outputs, use `--engine existing` and provide `hypothesis` or `transcript_file`, plus optional `latency_seconds`, in each row. Audio is optional for this mode; when supplied it must exist so its hash can be recorded. This enables repeated side-by-side evaluation without running a speech model.

Exit status 0 means every case processed and passed its expected-term/number assertions and the optional user-selected WER threshold. Status 1 means one or more cases failed processing or assertions. Status 2 means invalid global setup. An omitted WER threshold does not imply accuracy acceptance. `parity_established` is always false: representative held-out user speech and independently measured vendor outputs require a separate evaluation. A public sample cannot establish Wispr Flow accuracy parity, multilingual quality, microphone behavior, or final insertion latency.

## Resident local live Whisper

`native/live-whisper.cpp` is a small first-party adapter built against the existing whisper.cpp 1.9.4 runtime. It loads one GGML model per resident helper, then reads bounded mono 16 kHz PCM frames through a private pipe. No microphone or network is used by this benchmark. The app keeps the helper warm between captures, and releases it on model/language changes, explicit Release memory, or quit. Translation has a separate meeting-only lifecycle.

```sh
scripts/build-live-whisper.sh
python3 tools/benchmark_live_whisper.py \
  --helper .build/live-whisper/justwisper-live-native \
  --model Models/ggml-medium.bin \
  --output benchmarks/results/live-jfk-medium.json
```

The checked-in medium run on this Mac measured a cached model load of 0.63 seconds and median warm window decode of 0.88 seconds, with a 1.51-second maximum across 15 overlapping windows. The original public JFK fixture had 0.0 WER in the warm full-fixture check; repeated 44-second playback checks boundary merging and does not provide independent accuracy samples. First-ever Metal shader compilation took 23 seconds in an earlier base-model startup; cached startup results do not measure cold installation startup. The app currently waits between decodes, so window timing alone is not the time from speaking a word to seeing it. Hardware, audio length, model, and GPU state affect latency.

Recent hypotheses replace the same overlapping region. Older words commit only after a lexical and acoustic boundary match; uncertain coverage, queue gaps, or a truncated long-session prefix cannot be declared a complete final. Stop decodes the final saved-audio tail; if completeness is uncertain, the existing full-audio local pipeline completes the saved recording. This path never automatically uploads speech to a cloud provider. Live words are provisional and never pasted. Retained audio can be reprocessed from History; normal audio-retention settings still apply.
