import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

MODULE_PATH = Path(__file__).with_name("justwisper.py")
spec = importlib.util.spec_from_file_location("justwisper", MODULE_PATH)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class LocalAutomationTests(unittest.TestCase):
    def test_encrypted_library_never_falls_back_to_leftover_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "library.vault").write_bytes(b"encrypted fixture")
            (root / "library.json").write_text('{"history":[{"text":"must not be read"}]}')
            with self.assertRaisesRegex(ValueError, "encrypted"):
                cli.call_tool(root, "list_history", {})

    def test_mcp_stdio_and_private_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "library.json").write_text(json.dumps({"settings": {"apiKey": "must-never-be-returned"}, "history": [{"id": "123", "title": "Example", "audioPath": "/private/audio"}]}))
            messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
                        {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_history"}}]
            result = subprocess.run([sys.executable, str(MODULE_PATH), "--root", directory, "mcp"], input="\n".join(map(json.dumps, messages)) + "\n", capture_output=True, text=True, check=True)
            replies = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(replies), 3)
            self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-11-25")
            self.assertTrue(any(tool["name"] == "add_vocabulary" for tool in replies[1]["result"]["tools"]))
            self.assertNotIn("must-never-be-returned", result.stdout)
            self.assertNotIn("/private/audio", result.stdout)

    def test_client_uses_queue_and_never_writes_library(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = b'{"history":[]}'
            (root / "library.json").write_bytes(original)
            folder = root / "Automation"
            folder.mkdir(mode=0o700)
            (folder / "inbox").mkdir(mode=0o700)
            (folder / "replies").mkdir(mode=0o700)
            status = folder / "status.json"
            status.write_text(json.dumps({"updatedAt": time.time()}))
            status.chmod(0o600)
            received = []

            def fake_app():
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    for request in (folder / "inbox").glob("*.json"):
                        received.append(json.loads(request.read_text()))
                        reply = folder / "replies" / request.name
                        reply.write_text(json.dumps({"ok": True, "result": {"saved": "true"}}))
                        reply.chmod(0o600)
                        return
                    time.sleep(0.02)

            worker = threading.Thread(target=fake_app)
            worker.start()
            reply = cli.request_action(root, "add_vocabulary", {"phrase": "JustWisper"})
            worker.join(timeout=4)
            self.assertEqual(reply, {"saved": "true"})
            self.assertEqual(received[0]["arguments"], {"phrase": "JustWisper"})
            self.assertEqual((root / "library.json").read_bytes(), original)
            self.assertEqual(list((folder / "inbox").glob("*.json")), [])

    def test_nonprivate_and_symlink_files_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "file"
            file.write_text("{}")
            file.chmod(0o644)
            with self.assertRaises(ValueError):
                cli.read_json(file, private=True)
            file.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(file)
            with self.assertRaises(OSError):
                cli.read_json(link, private=True)


if __name__ == "__main__":
    unittest.main()
