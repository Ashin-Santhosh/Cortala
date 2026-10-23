# Local CLI and MCP

The CLI requires Python 3.9 or later and uses only the standard library. No network listener or proprietary backend is involved. It is available at `tools/justwisper.py` and packaged at `JustWisper.app/Contents/Resources/CLI/justwisper.py`.

Read operations use the last atomically saved library snapshot, so they also work while the app is closed:

```sh
python3 tools/justwisper.py history --limit 10
python3 tools/justwisper.py modes
python3 tools/justwisper.py transcript TRANSCRIPT_UUID
python3 tools/justwisper.py vocabulary
python3 tools/justwisper.py snippets
```

Mutation and recording actions require the running app and the explicit **Local automation** setting in Configuration. The app applies and saves changes on its main actor. The CLI never rewrites `library.json`.

```sh
python3 tools/justwisper.py action add_vocabulary phrase=JustWisper replacement=JustWisper
python3 tools/justwisper.py action select_mode id=MODE_UUID
python3 tools/justwisper.py action add_snippet 'trigger=my signature' 'text=Best regards, Ashin'
python3 tools/justwisper.py action start_recording
python3 tools/justwisper.py action stop_recording
```

`remove_vocabulary` and `remove_snippet` take `id=UUID`. `toggle_recording` and `cancel` take no arguments. An omitted vocabulary replacement creates a recognition hint. `--root /path/to/JustWisper` selects another application-support directory for development or testing.

The MCP entry point is `python3 /absolute/path/to/tools/justwisper.py mcp`. Configure an MCP host with `command: "python3"` and `args: ["/absolute/path/to/tools/justwisper.py", "mcp"]`. It implements the handshake protocol versions 2024-11-05 through 2025-11-25, newline-delimited JSON-RPC stdio, `initialize`, `ping`, `tools/list`, and `tools/call`. [The official MCP SDK transport documentation](https://ts.sdk.modelcontextprotocol.io/v2/serving/stdio) describes the stdio channel. Read tools are `list_history`, `get_transcript`, `list_modes`, `list_vocabulary`, and `list_snippets`; action tool names match the CLI actions above.

The local queue is under `Application Support/JustWisper/Automation`. It uses directories restricted to the current user (0700) and request/reply files with 0600 permissions. Requests require UUID filenames, a known action, a 64 KiB limit, and a timestamp no older than 30 seconds. Symlinks, other users' files, nonregular files, and nonprivate files are rejected. A live app heartbeat is required; clients time out after 10 seconds. Replies expire after two minutes. Read tools omit settings, credentials, and audio file paths. A transcript tool intentionally exposes its requested transcript text to its calling MCP host.

Local automation is disabled by default. Enabling it authorizes applications running as your macOS user to send the listed actions to JustWisper. Disable it in Configuration to stop the queue consumer.

## Validation

`python3 -m unittest discover -s tools -p 'test_*.py'` checks the private queue request/reply flow, read projections, MCP tool inventory, and benchmark reporting using temporary fixtures. The MCP inventory contains 14 tools: five read tools and nine actions. The Swift suite separately verifies app-side private request handling, expired requests, symlink rejection, and nonprivate file rejection.

For a live check, enable local automation, run `modes`, submit `select_mode` for one returned UUID, and confirm the app changes modes. Add a disposable vocabulary entry or snippet and verify its appearance in both the app and corresponding read command; remove it by its returned UUID. Disable automation and confirm a subsequent mutation fails with an actionable message. Recording commands require the same microphone permissions and idle-state checks as the app's recording button. A same-user synthetic queue test does not establish live microphone or insertion behavior.
