#!/usr/bin/env python3
"""Local Cortala CLI and MCP stdio server. Requires Python 3.9+, no dependencies."""
import argparse
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

DEFAULT_ROOT = Path.home() / "Library/Application Support/JustWisper"
ACTIONS = {
    "select_mode": (["id"], "Select a dictation mode by UUID."),
    "start_recording": ([], "Start recording in the running app. Requires local automation enabled."),
    "stop_recording": ([], "Stop a recording in the running app."),
    "toggle_recording": ([], "Toggle recording in the running app."),
    "cancel": ([], "Cancel the active operation."),
    "add_vocabulary": (["phrase", "replacement"], "Add a vocabulary hint or deterministic replacement."),
    "remove_vocabulary": (["id"], "Remove a vocabulary entry by UUID."),
    "add_snippet": (["trigger", "text"], "Add a spoken snippet expansion."),
    "remove_snippet": (["id"], "Remove a snippet by UUID."),
}
READ_TOOLS = {
    "list_history": "List saved transcript metadata; does not include audio paths or credentials.",
    "get_transcript": "Read raw and processed transcript text by UUID.",
    "list_modes": "List configured dictation modes.",
    "list_vocabulary": "List vocabulary hints and replacements.",
    "list_snippets": "List spoken snippets.",
}


def read_json(path, limit=32 * 1024 * 1024, private=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("Expected an owned regular file within the size limit.")
        if private and stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("Automation files must have private permissions (0600).")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("The file exceeds the size limit.")
        return json.loads(data)
    finally:
        os.close(descriptor)


def private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Automation directories must be owned by you with permissions 0700.")


def request_action(root, action, arguments, timeout=10):
    if action not in ACTIONS:
        raise ValueError("Unsupported local automation action.")
    required = ACTIONS[action][0]
    if set(arguments) - set(required) or any(not isinstance(value, str) for value in arguments.values()):
        raise ValueError("Action arguments must match the tool's documented string fields.")
    # Empty replacement means a recognition hint. All other fields are required.
    missing = [key for key in required if key != "replacement" and not arguments.get(key)]
    if missing:
        raise ValueError("Missing arguments: " + ", ".join(missing))
    folder = root / "Automation"
    try:
        for directory in (folder, folder / "inbox", folder / "replies"):
            private_directory(directory)
        status = read_json(folder / "status.json", 4096, private=True)
        if not -5 <= time.time() - float(status.get("updatedAt", 0)) <= 3:
            raise ValueError("Cortala's automation heartbeat is stale.")
    except (OSError, ValueError) as error:
        raise ValueError("Open Cortala and enable Local automation in Configuration. " + str(error)) from None
    request_id = str(uuid.uuid4())
    payload = json.dumps({"id": request_id, "createdAt": time.time(), "action": action, "arguments": arguments}).encode()
    if len(payload) > 65536:
        raise ValueError("Automation request exceeds 64 KiB.")
    temporary = folder / "inbox" / (request_id + ".tmp")
    destination = temporary.with_suffix(".json")
    reply_path = folder / "replies" / (request_id + ".json")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                reply = read_json(reply_path, 65536, private=True)
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not reply.get("ok"):
                raise ValueError(reply.get("error", "The app rejected the request."))
            return reply.get("result") or {"accepted": True}
        raise ValueError("Cortala did not answer within 10 seconds. Check that the app is running with Local automation enabled.")
    finally:
        for path in (temporary, destination, reply_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def call_tool(root, name, arguments):
    if name in ACTIONS:
        return request_action(root, name, arguments)
    if name not in READ_TOOLS:
        raise ValueError("Unknown tool.")
    if (root / "library.vault").exists() or (root / "library.vault").is_symlink():
        raise ValueError("The transcript library is encrypted. Read or export it from Cortala; this tool does not retrieve the encryption key.")
    library = read_json(root / "library.json")
    if name == "list_history":
        limit = max(1, min(1000, int(arguments.get("limit", 50))))
        keys = ("id", "title", "date", "mode", "duration", "isMeeting")
        return [{key: item[key] for key in keys if key in item} for item in library.get("history", [])[:limit]]
    if name == "get_transcript":
        identifier = str(uuid.UUID(arguments["id"])).lower()
        for item in library.get("history", []):
            if item.get("id", "").lower() == identifier:
                return {key: value for key, value in item.items() if key != "audioPath"}
        raise ValueError("No transcript has that UUID.")
    return library.get({"list_modes": "modes", "list_vocabulary": "vocabulary", "list_snippets": "snippets"}[name], [])


def tool_list():
    result = []
    for name, description in READ_TOOLS.items():
        properties = {"id": {"type": "string"}} if name == "get_transcript" else ({"limit": {"type": "integer", "minimum": 1, "maximum": 1000}} if name == "list_history" else {})
        schema = {"type": "object", "properties": properties, "additionalProperties": False}
        if name == "get_transcript":
            schema["required"] = ["id"]
        result.append({"name": name, "description": description, "inputSchema": schema})
    for name, (keys, description) in ACTIONS.items():
        schema = {"type": "object", "properties": {key: {"type": "string"} for key in keys}, "additionalProperties": False,
                  "required": [key for key in keys if key != "replacement"]}
        result.append({"name": name, "description": description, "inputSchema": schema})
    return result


def mcp(root):
    """MCP JSON-RPC stdio: one UTF-8 JSON message per line; stdout is protocol-only."""
    while True:
        line = sys.stdin.buffer.readline(1024 * 1024 + 1)
        if not line:
            return
        response = None
        identifier = None
        try:
            if len(line) > 1024 * 1024:
                raise ValueError("Message exceeds 1 MiB.")
            message = json.loads(line)
            if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                raise ValueError("Expected a JSON-RPC 2.0 object.")
            if "id" not in message:
                continue
            identifier = message["id"]
            method = message.get("method")
            params = message.get("params") or {}
            if not isinstance(params, dict):
                raise ValueError("Request params must be an object.")
            if method == "initialize":
                requested = params.get("protocolVersion")
                version = requested if requested in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25") else "2025-11-25"
                result = {"protocolVersion": version, "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "justwisper-local", "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": tool_list()}
            elif method == "tools/call":
                try:
                    arguments = params.get("arguments") or {}
                    if not isinstance(arguments, dict):
                        raise ValueError("Tool arguments must be an object.")
                    value = call_tool(root, params["name"], arguments)
                    result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
                except (OSError, ValueError, KeyError, TypeError) as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                response = {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32601, "message": "Method not found"}}
                result = None
            if response is None:
                response = {"jsonrpc": "2.0", "id": identifier, "result": result}
        except json.JSONDecodeError:
            response = {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32700, "message": "Parse error"}}
        except (ValueError, KeyError, TypeError) as error:
            response = {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32600, "message": str(error)}}
        print(json.dumps(response, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Application Support/JustWisper directory")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mcp", help="Serve MCP JSON-RPC over stdio")
    history = sub.add_parser("history", help="List transcript metadata")
    history.add_argument("--limit", type=int, default=50)
    transcript = sub.add_parser("transcript", help="Read one transcript")
    transcript.add_argument("id")
    for name in ("modes", "vocabulary", "snippets"):
        sub.add_parser(name)
    action = sub.add_parser("action", help="Send a mutation to the running, opted-in app")
    action.add_argument("name", choices=sorted(ACTIONS))
    action.add_argument("arguments", nargs="*", metavar="KEY=VALUE")
    options = parser.parse_args()
    if options.command == "mcp":
        mcp(options.root)
        return
    try:
        if options.command == "action":
            arguments = dict(item.split("=", 1) for item in options.arguments)
            value = request_action(options.root, options.name, arguments)
        else:
            names = {"history": "list_history", "transcript": "get_transcript", "modes": "list_modes", "vocabulary": "list_vocabulary", "snippets": "list_snippets"}
            arguments = {"id": options.id} if options.command == "transcript" else ({"limit": options.limit} if options.command == "history" else {})
            value = call_tool(options.root, names[options.command], arguments)
        print(json.dumps(value, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, "justwisper: " + str(error) + "\n")


if __name__ == "__main__":
    main()
