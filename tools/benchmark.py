#!/usr/bin/env python3
"""Reproducible local ASR evaluation. User-supplied recordings only; no network calls."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time
import unicodedata


def words(text):
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", text).casefold(), flags=re.UNICODE)


def edit_distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for index, token in enumerate(reference):
        next_row = [index + 1]
        for column, other in enumerate(hypothesis):
            next_row.append(min(next_row[-1] + 1, row[column + 1] + 1, row[column] + (token != other)))
        row = next_row
    return row[-1]


def metrics(reference, hypothesis, expected_terms=()):
    reference_words, hypothesis_words = words(reference), words(hypothesis)
    reference_chars = [char for char in unicodedata.normalize("NFKC", reference).casefold() if char.isalnum()]
    hypothesis_chars = [char for char in unicodedata.normalize("NFKC", hypothesis).casefold() if char.isalnum()]
    missing_terms = [term for term in expected_terms if " " + " ".join(words(term)) + " " not in " " + " ".join(hypothesis_words) + " "]
    reference_numbers = Counter(re.findall(r"\d+(?:[.,]\d+)*", unicodedata.normalize("NFKC", reference)))
    hypothesis_numbers = Counter(re.findall(r"\d+(?:[.,]\d+)*", unicodedata.normalize("NFKC", hypothesis)))
    return {"wer": edit_distance(reference_words, hypothesis_words) / max(1, len(reference_words)),
            "cer": edit_distance(reference_chars, hypothesis_chars) / max(1, len(reference_chars)),
            "word_errors": edit_distance(reference_words, hypothesis_words), "reference_words": len(reference_words),
            "missing_expected_terms": missing_terms,
            "missing_number_forms": list((reference_numbers - hypothesis_numbers).elements()),
            "unexpected_number_forms": list((hypothesis_numbers - reference_numbers).elements())}


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_path(base, value):
    path = Path(value).expanduser()
    return path if path.is_absolute() else base / path


def load_manifest(path):
    cases = []
    with path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
                if not isinstance(value, dict) or not isinstance(value.get("reference"), str):
                    raise ValueError("Each case requires a reference string.")
                if not isinstance(value.get("expected_terms", []), list) or not all(isinstance(term, str) for term in value.get("expected_terms", [])):
                    raise ValueError("expected_terms must contain strings.")
                value.setdefault("id", str(number))
                cases.append(value)
            except (ValueError, TypeError) as error:
                cases.append({"id": str(number), "manifest_error": str(error)})
    if not cases:
        raise ValueError("The manifest is empty.")
    return cases


def run(options):
    manifest = options.manifest.expanduser().resolve()
    cases = load_manifest(manifest)
    # Keep the configured launch path: a wrapper or symlink can locate adjacent
    # runtime assets through argv[0]. Resolve only for reproducible file identity.
    executable = str(Path(options.cli).expanduser().absolute()) if "/" in options.cli else shutil.which(options.cli)
    metadata = {"created_at": datetime.now(timezone.utc).isoformat(), "engine": options.engine,
                "manifest": str(manifest), "manifest_sha256": sha256(manifest), "platform": platform.platform(),
                "python": platform.python_version(), "normalization": "NFKC + casefold; WER Unicode letter/number tokens; CER letters/numbers only",
                "parity_established": False, "scope": "Local ASR or supplied transcript comparison; no cleanup or delivery measurement"}
    if options.engine == "local":
        if not executable or not Path(executable).is_file() or not options.model:
            raise ValueError("Local evaluation requires an executable --cli and a readable --model.")
        model = options.model.expanduser().resolve()
        metadata.update({"executable": executable, "executable_resolved": str(Path(executable).resolve()), "executable_sha256": sha256(Path(executable)), "model": str(model), "model_sha256": sha256(model), "threads": options.threads})
        try:
            version = subprocess.run([executable, "--help"], capture_output=True, text=True, timeout=3)
            help_lines = (version.stdout + version.stderr).strip().splitlines()
            metadata["runtime_identity"] = help_lines[:6]
        except (OSError, subprocess.SubprocessError) as error:
            # Runtime metadata is best-effort; fixture failures must still be reported.
            metadata["runtime_identity"] = []
            metadata["runtime_identity_error"] = str(error)
            metadata["runtime_version"] = "unknown; executable SHA-256 recorded"
    results = []
    for case in cases:
        result = {"id": case["id"], "reference": case.get("reference", ""), "language": case.get("language", "auto")}
        start = time.perf_counter()
        try:
            if "manifest_error" in case:
                raise ValueError(case["manifest_error"])
            audio = resolve_path(manifest.parent, case["audio"]) if case.get("audio") else None
            if audio is not None:
                result.update({"audio": str(audio), "audio_sha256": sha256(audio)})
            if options.engine == "existing":
                if isinstance(case.get("hypothesis"), str):
                    hypothesis = case["hypothesis"]
                elif case.get("transcript_file"):
                    hypothesis = resolve_path(manifest.parent, case["transcript_file"]).read_text(encoding="utf-8")
                else:
                    raise ValueError("Existing comparison requires hypothesis or transcript_file.")
                result["latency_seconds"] = case.get("latency_seconds")
            else:
                if audio is None:
                    raise ValueError("Local evaluation requires an audio path.")
                with tempfile.TemporaryDirectory(prefix="justwisper-benchmark-") as temporary:
                    output = Path(temporary) / "transcript"
                    arguments = [executable, "-m", str(model), "-f", str(audio), "-l", case.get("language", "auto"), "-nt", "-otxt", "-of", str(output), "-tp", "0", "-t", str(options.threads)]
                    result["arguments"] = ["<temporary-output>" if value == str(output) else value for value in arguments]
                    began_inference = time.perf_counter()
                    process = subprocess.run(arguments, capture_output=True, text=True, timeout=options.timeout)
                    result["latency_seconds"] = time.perf_counter() - began_inference
                    if process.returncode:
                        raise ValueError("whisper-cli exited with status " + str(process.returncode))
                    hypothesis = output.with_suffix(".txt").read_text(encoding="utf-8").strip()
            result["hypothesis"] = hypothesis
            result.update(metrics(case["reference"], hypothesis, case.get("expected_terms", [])))
            result["critical_terms_and_numbers_pass"] = not any(result[key] for key in ("missing_expected_terms", "missing_number_forms", "unexpected_number_forms"))
            baseline = case.get("baseline")
            baseline_text = baseline if isinstance(baseline, str) else baseline.get("text") if isinstance(baseline, dict) else None
            if isinstance(baseline_text, str):
                result["baseline"] = {"metadata": baseline if isinstance(baseline, dict) else {"source": "user-supplied"}, **metrics(case["reference"], baseline_text, case.get("expected_terms", []))}
                result["wer_difference_from_baseline"] = result["wer"] - result["baseline"]["wer"]
            result["status"] = "passed" if result["critical_terms_and_numbers_pass"] and (options.max_wer is None or result["wer"] <= options.max_wer) else "failed_assertion"
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            result["status"] = "failed_processing"
            result["error"] = str(error)
        result["evaluation_seconds"] = time.perf_counter() - start
        results.append(result)
    measured = [item for item in results if "wer" in item]
    latencies = [item["latency_seconds"] for item in results if isinstance(item.get("latency_seconds"), (int, float)) and item["latency_seconds"] >= 0]
    summary = {"cases": len(results), "measured": len(measured), "failed_processing": sum(item["status"] == "failed_processing" for item in results),
               "failed_assertions": sum(item["status"] == "failed_assertion" for item in results),
               "corpus_wer": sum(item["word_errors"] for item in measured) / max(1, sum(item["reference_words"] for item in measured)) if measured else None,
               "latency_samples": len(latencies), "median_seconds": statistics.median(latencies) if latencies else None,
               "p95_seconds": percentile(latencies, 0.95), "all_cases_passed": all(item["status"] == "passed" for item in results)}
    report = {"metadata": metadata, "summary": summary, "cases": results}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0 if summary["all_cases_passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", choices=("local", "existing"), default="local")
    parser.add_argument("--cli", default="whisper-cli")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--max-wer", type=float, help="Optional user-chosen WER acceptance threshold")
    options = parser.parse_args()
    if options.threads < 1 or options.timeout <= 0:
        parser.error("threads and timeout must be positive")
    try:
        raise SystemExit(run(options))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(2, "benchmark: " + str(error) + "\n")


if __name__ == "__main__":
    main()
