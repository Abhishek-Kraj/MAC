# AGENTS.md — TheCloser (macOS overlay), fork of MAC

Start here, then read `HANDOFF.md` — especially **§11 "State of play —
2026-10-21"**, which is the current status. Sections §0–§1 of HANDOFF.md are
older: feature work is allowed again (the user now asks for enhancements),
and active work is on branch `bugsweep`, not `remove-pro-entirely`.

## What this is

A SwiftUI + AppKit macOS overlay: a floating, screen-share-invisible panel
that listens to interviews and calls (system audio = THEM, mic = YOU),
transcribes them (ElevenLabs / Grok / Apple on-device), answers interview
questions with a model via OpenRouter (bring your own key), and writes an
interview debrief or call notes at the end.

- Sources: `MacOverlay/` — state lives in `OverlayViewModel.swift`
  (`@Observable`), window and harness in `AppDelegate.swift`, the shell in
  `Views/Shell/` (bar, header), screens in `Views/Surfaces/`, Settings in
  `Views/Preferences/PreferencesView.swift`.
- Overlay rules: an `NSPanel` at `.statusBar + 1`, non-activating, hidden from
  screen shares by a swizzle (`sharingType = .none`). Never break screen-share
  invisibility.

## Git

- Branch `bugsweep`; `origin` = `https://github.com/Abhishek-Kraj/MAC.git`
  (the user's fork). **Never push to `upstream` (TheCloserApp/MAC).**
- One commit per fix, message `<type>: <what changed for the user>`.
- Merging `bugsweep` into `remove-pro-entirely`, and deleting anything on the
  HANDOFF §11 P3 cleanup list, need the user's OK.

## Build, test, run

```bash
./build.sh --channel dev                 # → build/TheCloser Dev.app
./test.sh                                # 141 tests; compiles the SOURCES list in test.sh only
open "build/TheCloser Dev.app"
pkill -x thecloser-dev                   # it never exits on its own; ask the user first if they may be using it
```

- A new pure-logic file is untested until it is added to `SOURCES` in
  `test.sh`. UI tests in `Tests/Tests.swift` are source-parsing checks.
- `"invalid or unsupported format for signature"` → `rm -rf "build/TheCloser Dev.app"` and rebuild.
- Launch from a shell with `open -n "build/TheCloser Dev.app" --args …`, not the
  binary directly, whenever the mic or speech is used: otherwise macOS holds
  the shell responsible and TCC kills the app.

## Verify before claiming (the user insists on this)

- **Look at the screen you changed.** Snapshot harness (flags in
  `AppDelegate.swift`, `-snapshot` block):
  ```bash
  "build/TheCloser Dev.app/Contents/MacOS/thecloser-dev" -snapshot /tmp/snap -surface interview -seedtranscript &
  sleep 7; pkill -x thecloser-dev        # PNGs in /tmp/snap
  ```
  Surfaces: `interview`, `regularCall` (+`-seedcall`), `settings`
  (+`-settings-tab "Interview & Calls"`), `sessions`, `chat`, `none`;
  `-fresh` gives the setup form. Seeds write into a throwaway session.
  Popovers, sheets-in-popovers and the call prompt are not captured; render
  them with `ImageRenderer` in a temporary hook. **Remove every TEMP hook
  before committing.**
- **Interview test kit** (`Tests/live/`, uses the user's keys — say so first):
  - `run_scripted_interview.sh [dir]` — script lines through the live path,
    real model, no audio. Last: 13/13.
  - `run_live_interview.sh [dir] [engine]` — plays the script out loud with
    `say`; ~4 min; user must not talk or touch the panel. Last: 13/13.
  - `score.py` prints PASS/FAIL per line, answer length vs depth, debrief checks.
- Never state a number, cost or status you did not measure in this session.
  Label estimates as estimates.

## Working with the user

- Terse answers, no preamble or summaries; challenge bad ideas.
- Plan before touching 3+ files; show what changed; don't refactor or add
  comments to code you weren't asked to change; follow existing patterns.
- BYOK only — no Pro/payment code.
- Secrets: dev (unsigned) builds keep API keys in the preferences plist; never
  re-enable Keychain for them, never read the app's Keychain items with the
  `security` CLI (password prompts), never print key values.
- Don't copy code or prompts from other products (Wispr Flow, Natively,
  GPL/AGPL repos): ideas only.
- Don't make real model calls in tests unless the user agreed (their key pays).

## Open items (see HANDOFF §11 for detail)

- Prepared-bank answers ignore the Brief/Standard/Deep setting.
- Apple on-device engine returned "No speech detected" in a played-audio run
  (low volume suspected, unproven).
- Live session options popover (gear while live) not yet checked on screen.
- Call chips truncate at narrow widths; live session titles come from a
  mid-word transcript cut.
- Grok reconnect counter reset not reviewed.
