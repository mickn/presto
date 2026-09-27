# Presto

Voice commands for your Mac that run while you are still talking. Say "open Calculator and then
set the volume to 30" and Calculator is open before you reach "volume".

Tap **⌃⌥Space** and speak (it stops when you pause), or hold it while you talk.

## How it works

```
mic ─▶ SpeechAnalyzer ─▶ partial transcript ─▶ clauses ─▶ Jev (per clause) ─▶ engine ─▶ executor
        (on-device)       every ~250 ms          "and", "then",   verb / app /     fires when      NSWorkspace,
                                                 "no, I mean"     volume level     sure enough     keys, AppleScript
```

- **Speech**: two on-device recognizers share one `SpeechAnalyzer`. `DictationTranscriber`
  reports a new word every ~250 ms and drives everything live. `SpeechTranscriber` is slower
  (batches about once a second) but more accurate, so its final text is used for searches, web
  addresses, and typing.
- **Jev** ([TypeSafe](https://typesafe.ai)) is a decision model: text in, probabilities out. Each
  partial clause is one request with three questions answered in parallel: which action
  (28 choices), which installed app (all ~180), and which volume level. About 170 ms and
  $0.00007 per call. When the two recognizers disagree on free text, Jev also picks the likelier
  version.
- **The engine** (`Packages/PrestoCore`) decides when to act, by risk:
  - *instant* (open/hide an app, volume, media keys, new tab, full screen, dark mode): as soon as
    Jev is ≥ 0.8 sure, mid-word if need be. A wrong early guess is undone when the words firm up.
  - *end of clause* (quit, close, lock, set volume to N, screenshot): when the next clause starts,
    or at a short pause if Jev is already sure.
  - *end of utterance* (search, type, go to a website): these take the rest of what you say.
  - Clauses run in order, so "open Safari and new tab" puts the tab in Safari.
  - "Open Safari, no, Chrome" undoes Safari and opens Chrome.
  - "Never mind" cancels, and "undo that" reverses the last action.

## What you can say

| | Examples |
| --- | --- |
| Apps | open / launch / switch to / bring up *app*, quit *app*, hide *app*; "open Notes and Messages" |
| Windows and tabs | new tab, close tab, new window, close window, minimize, full screen |
| Sound and media | louder, quieter, set the volume to 40, mute, unmute, pause the music, next song, previous song |
| Web | search for *anything*, go to *site dot com* |
| Text | type *anything* (into the app you're in) |
| System | lock the screen, turn off the display, take a screenshot, dark mode |
| Control | never mind, undo that |

## Setup

1. **API key.** Get a key from [TypeSafe](https://typesafe.ai). Launch Presto once with
   `TYPESAFE_API_KEY` in its environment and it saves the key to your login keychain; after that it
   starts normally from Finder or at login. From a shell where the variable is set (for example via
   your secrets manager):
   ```bash
   ~/Applications/Presto.app/Contents/MacOS/Presto --render-hud /dev/null
   ```
2. **Microphone**: macOS asks the first time you use the shortcut.
3. **Accessibility** (System Settings → Privacy & Security → Accessibility → Presto): needed
   for keyboard shortcuts, media keys, and typing. Opening apps, volume, search, and websites work
   without it.
4. **Automation → System Events**: macOS asks the first time you say "dark mode".

The menu bar bolt shows what's granted, and has a dry-run switch, the search engine, the shortcut,
and Open at Login.

## Build and test

Needs Xcode 27, macOS 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Set
`DEVELOPMENT_TEAM` in `project.yml` to your own team to sign it.

```bash
xcodegen generate && xcodebuild -project Presto.xcodeproj -scheme Presto -derivedDataPath build build
```

```bash
cd Packages/PrestoCore && swift test                                        # engine, offline (30 tests)
```

```bash
cd Packages/PrestoCore && swift run presto-eval   # live Jev at speaking pace; needs TYPESAFE_API_KEY set
```

```bash
scripts/simulate.py --suite             # `say` audio through the real app pipeline, dry run
```

```bash
scripts/simulate.py --execute "open calculator and then open chess"   # really does it
```

Every run writes JSON lines to `~/Library/Logs/Presto/events.jsonl`: each transcript update, each
Jev answer with latency, each action and how early it fired.

App launch flags: `--simulate-audio <file>`, `--simulate-text "<sentence>"`, `--dry-run`,
`--exit-when-done`, `--render-hud <png>`.

## Known limits

- Recognizers mishear some brand names from synthetic speech ("github" came out as "gitub").
  Web addresses are the weakest command.
- Actions that finish a sentence (quit, search, type) wait about 0.7 s of silence to be sure
  you've stopped. Only mid-sentence actions run before you finish.
- English only for now. Jev and the speech models support more; the command words don't yet.
