# Notelore

A calm, literary meeting recorder and notes companion for iOS — a second memory.
Notelore records the room, transcribes on this device, and keeps every
conversation as readable minutes you can return to, search, and ask about.

It is built like stationery, not software: ivory paper, ink, hairline rules,
one vermillion accent. No cards, no shadows, no noise.

## What it does

- **Record** — capture meetings with the microphone, including in the
  background; recordings survive calls and route changes.
- **Transcribe** — speech recognition runs on-device wherever the language
  allows, producing a timestamped transcript as you go.
- **Minutes** — distill a transcript into a two-sentence summary, key points,
  decisions, action items, and open questions.
- **Library** — every session kept, searchable, with margin notes.
- **Ask the lore** — ask a question across your past sessions; answers cite
  the transcript excerpts they drew from.
- **Prep** — paste an agenda or job description beforehand and study a quiet
  guide of likely questions and points worth making. Preparation only.

## Requirements

- Xcode 26 or later
- iOS 17.0 or later

## Setup

1. Open `Notelore.xcodeproj` in Xcode.
2. Select the Notelore target → **Signing & Capabilities** → choose your Team
   (bundle identifier `com.owaiskhan.notelore`).
3. Build and run on a device or simulator.

Building from the command line? If `xcode-select` points at the Command Line
Tools, prefix invocations with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...
```

## Permissions

Notelore asks for exactly two permissions, and the descriptions say what they
mean:

- **Microphone** — listens only while you record, so your conversations can be
  kept as written minutes.
- **Speech recognition** — turns your recordings into readable transcripts, on
  this device whenever your language allows.

The `audio` background mode keeps a recording going when you leave the app or
lock the screen.

## The Gemini key

Notelore works without any account or key. Recording, on-device transcription,
the library, and search are all fully functional out of the box — the app is
completely reviewable without signing up for anything.

A Gemini key unlocks the written features: **Minutes**, **Ask the lore**, and
**Prep**. Get a free key from [Google AI Studio](https://aistudio.google.com/apikey)
and paste it in Settings. The key is stored only in the iOS Keychain — never
in defaults, files, or logs — and is sent only with requests you initiate.

## Offline

Recording and transcription are fully offline (on-device recognition where the
language supports it). Minutes, Ask, and Prep need a connection; everything
you've already recorded and distilled remains readable offline.

## Architecture

```
SwiftUI views  →  @Observable view models  →  protocol-typed services
```

- **Views** stay dumb; each feature view takes `init(services: AppServices)`.
- **View models** are `@MainActor @Observable` classes holding all logic.
- **Services** are protocol-typed and injected through `AppServices`:
  `AudioRecordingService`, `TranscriptionService`, `LLMService`, `NotesStore`,
  and `Distiller`.
- **Persistence** is SwiftData (`Session`, `Utterance`, `Note`, `ActionItem`);
  audio files live in the app's documents directory; the Gemini key lives in
  the Keychain.
- `LLMService` is provider-agnostic — only Gemini ships today, but an
  Anthropic or OpenAI backend can be added without touching feature code.
- Apple frameworks only. Zero third-party dependencies.

## Tests

`NoteloreTests` covers Gemini response parsing and search ranking. Run with
**Cmd-U** in Xcode.
