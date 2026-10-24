# JustWhisper for Windows and Linux

This desktop port is under development. The installed native Mac app is separate and keeps its existing data. Android, iOS, and video capture are on hold.

## Development

Use Node.js 22 or later. Run `npm ci`, `npm test`, and `npm start` in this directory. The interface uses local HTML, CSS, and JavaScript inside a sandboxed Electron renderer. Files, credentials, subprocesses, and provider requests belong to the main process.

The speech runtime is whisper.cpp 1.9.4, downloaded from its official release with a pinned SHA-256. Build on the target operating system:

```sh
cmake -S native -B native-build -DCMAKE_BUILD_TYPE=Release
cmake --build native-build --config Release --target justwhisper-live whisper-cli --parallel 2
cmake --install native-build --config Release --component JustWhisperRuntime --prefix runtime/linux-x64
npm run package:linux
```

For Windows, use `runtime/win32-x64` and `npm run package:win` instead. A C++ toolchain and CMake are required. The workflow in `.github/workflows/desktop.yml` builds each platform on its own runner. It cannot run until this repository is hosted on GitHub and Actions is enabled.

Packaging refuses to proceed without both native executables. Models are separate downloads or user-selected local files; packaging does not include personal recordings, credentials, or Mac libraries.

## Acceptance gates

Passing tests on a Mac does not establish Windows or Linux compatibility. Release requires successful target-host builds and manual tests for microphone selection, recording cancellation, long recordings, live speech continuity, keyboard navigation, shortcuts, secure key storage, and package launch on clean machines.

Linux desktop environments differ in global shortcut and secure key storage support. Unsupported capabilities must be visible in the interface. Copying a transcript remains available when automatic insertion cannot be supported safely. Screen/system audio, speaker labeling, window placement, and exact feature parity with the native Mac app are not release claims for this preview.

## Privacy

Local speech is explicit and does not silently fall back to cloud processing. Cloud speech requires a user-configured provider. API credentials must stay in operating-system protected storage; Linux configurations without a secure key store must not persist credentials as plaintext. Audio files and exported transcripts require separate retention choices; encrypted library storage does not mean exports or audio are encrypted.
