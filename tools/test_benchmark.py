import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location("benchmark", Path(__file__).with_name("benchmark.py"))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkTests(unittest.TestCase):
    def test_metrics_and_critical_terms(self):
        value = benchmark.metrics("Hello WORLD, 42 euros", "hello word 24 euros", ["WORLD", "euros"])
        self.assertEqual(value["wer"], 0.5)
        self.assertEqual(value["missing_expected_terms"], ["WORLD"])
        self.assertEqual(value["missing_number_forms"], ["42"])
        self.assertEqual(value["unexpected_number_forms"], ["24"])
        self.assertEqual(benchmark.metrics("Café 東京", "CAFÉ 東京")["cer"], 0)
        self.assertEqual(benchmark.metrics("", "extra words")["wer"], 2)

    def test_percentiles_and_report_keep_failures(self):
        self.assertEqual(benchmark.percentile([1, 2, 3], .95), 2.9)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "cases.jsonl"
            manifest.write_text('\n'.join([json.dumps({"reference": "hello", "hypothesis": "hello", "latency_seconds": 2, "baseline": {"text": "hello", "name": "user supplied"}}), json.dumps({"reference": "missing transcript"}), 'invalid json']))
            options = SimpleNamespace(manifest=manifest, output=root / "report.json", engine="existing", cli="whisper-cli", model=None, threads=4, timeout=30, max_wer=None)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(benchmark.run(options), 1)
            report = json.loads(options.output.read_text())
            self.assertEqual(report["summary"]["cases"], 3)
            self.assertEqual(report["summary"]["failed_processing"], 2)
            self.assertEqual(report["summary"]["measured"], 1)
            self.assertFalse(report["metadata"]["parity_established"])
            self.assertEqual(report["cases"][0]["wer_difference_from_baseline"], 0)

    def test_help_timeout_does_not_skip_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable, model, audio = (root / name for name in ("whisper-cli", "model.bin", "audio.wav"))
            for path in (executable, model, audio):
                path.write_bytes(b"fixture")
            manifest = root / "cases.jsonl"
            manifest.write_text(json.dumps({"audio": "audio.wav", "reference": "hello", "language": "en"}) + "\n")
            options = SimpleNamespace(manifest=manifest, output=root / "report.json", engine="local", cli=str(executable), model=model, threads=4, timeout=30, max_wer=0)

            def fake_process(arguments, **kwargs):
                if "--help" in arguments:
                    raise subprocess.TimeoutExpired(arguments, 3)
                output = Path(arguments[arguments.index("-of") + 1]).with_suffix(".txt")
                output.write_text("hello")
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with contextlib.redirect_stdout(io.StringIO()), patch.object(benchmark.platform, "platform", return_value="test-platform"), patch.object(benchmark.subprocess, "run", side_effect=fake_process):
                self.assertEqual(benchmark.run(options), 0)
            report = json.loads(options.output.read_text())
            self.assertEqual(report["summary"]["measured"], 1)
            self.assertIn("runtime_identity_error", report["metadata"])
            self.assertEqual(report["cases"][0]["status"], "passed")

    def test_symlink_launch_path_is_preserved_and_target_identity_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, executable, model, audio = (root / name for name in ("engine", "whisper-cli", "model.bin", "audio.wav"))
            for path in (target, model, audio):
                path.write_bytes(b"fixture")
            executable.symlink_to(target)
            manifest = root / "cases.jsonl"
            manifest.write_text(json.dumps({"audio": "audio.wav", "reference": "hello"}) + "\n")
            options = SimpleNamespace(manifest=manifest, output=root / "report.json", engine="local", cli=str(executable), model=model, threads=4, timeout=30, max_wer=0)
            calls = []

            def fake_process(arguments, **kwargs):
                calls.append(arguments)
                if "-of" in arguments:
                    Path(arguments[arguments.index("-of") + 1]).with_suffix(".txt").write_text("hello")
                return subprocess.CompletedProcess(arguments, 0, "fixture runtime", "")

            with contextlib.redirect_stdout(io.StringIO()), patch.object(benchmark.platform, "platform", return_value="test-platform"), patch.object(benchmark.subprocess, "run", side_effect=fake_process):
                self.assertEqual(benchmark.run(options), 0)
            report = json.loads(options.output.read_text())
            self.assertTrue(all(call[0] == str(executable) for call in calls))
            self.assertEqual(report["metadata"]["executable_resolved"], str(target.resolve()))
            self.assertEqual(report["metadata"]["executable_sha256"], benchmark.sha256(target))


if __name__ == "__main__":
    unittest.main()
