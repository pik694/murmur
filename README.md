# Murmur

Local, private dictation for macOS. Press a shortcut, talk, press Return: the text is pasted where
you were typing. Speech is transcribed on the Mac with [whisper.cpp](https://github.com/ggml-org/whisper.cpp);
nothing leaves the machine except the one-time model download.

- **Shortcut** (default <kbd>⌥ Space</kbd>) starts recording. While recording: <kbd>⏎</kbd> pastes,
  <kbd>⇧⏎</kbd> pastes using the accurate model, <kbd>⎋</kbd> cancels.
- **Live preview** in a floating panel (fast model re-run as you speak), with Paste / Copy / Cancel buttons.
- **Models**: whisper small (fast, default) and large-v3-turbo (accurate, optional download), plus Silero VAD
  so silence isn't transcribed into invented text. Downloaded on first launch into
  `~/Library/Application Support/Murmur/Models` and checked against pinned SHA-256s.
- **Permissions**: Microphone, and Accessibility for auto-paste (without it Murmur copies instead).
  Hotkeys use Carbon `RegisterEventHotKey`, so **no Input Monitoring** is needed.

Requires Apple Silicon and macOS 14+.

## Build

Everything comes from the Nix flake (nixpkgs Swift + macOS SDK, pinned whisper.cpp v1.8.4 framework);
no Xcode needed.

```sh
nix build            # result/Applications/Murmur.app
```

To run a local build, copy it out of the store and sign it ad-hoc (macOS needs a signed bundle to grant
microphone access):

```sh
rm -rf build && mkdir build && cp -R result/Applications/Murmur.app build/ && chmod -R u+w build
codesign --force --deep -s - build/Murmur.app && open build/Murmur.app
```

## Release

```sh
nix run .#dist       # dist/Murmur-<version>.dmg
```

The app and the disk image are signed with the self-signed **"Murmur Code Signing"** identity from the
login keychain (override with `MURMUR_SIGN_IDENTITY`). Keeping the same certificate across releases is what
lets users keep their Microphone/Accessibility permissions after updating, so back it up. The build isn't
notarized: on first launch users go through System Settings → Privacy & Security → **Open Anyway** once.
The disk image includes `docs/install.html` as "Read me first".

## Layout

| Path | What |
|---|---|
| `Sources/AppDelegate.swift` | Menu bar item, dictation flow, live preview loop |
| `Sources/HotKeys.swift` | Carbon global hotkeys |
| `Sources/Recorder.swift` | Microphone capture, resampled to 16 kHz mono |
| `Sources/Whisper.swift` | whisper.cpp wrapper |
| `Sources/Models.swift` | Model specs, download and checksum |
| `Sources/Panel.swift` | Floating live-transcript panel |
| `Sources/Paster.swift` | Paste via ⌘V with clipboard restore |
| `nix/murmur.nix` | App bundle derivation |
| `docs/install.html` | End-user install guide |
