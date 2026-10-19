# Handoff — The Closer (fork of MAC)

## 0. Read this first

We are **not adding features**. The task is: **fix bugs and fine-tune what
already exists.** The user has explicitly stopped feature work. Every bug in
the "Open issues" list below was found by the user using the real app, not by
inspection.

Two hard rules learned the hard way this week — please keep them:

1. **Verify visually before claiming a fix.** The `-snapshot` harness exists
   for exactly this. Bugs fixed by reading code alone and not looked at:
   the summary sheet rendering light-on-light, the panel clipping its own
   content, a label wrapping to "Assis / tant". Screenshot the state you
   changed.
2. **Pure logic goes in `Tests/Tests.swift`.** UI/audio/networking are not in
   the test target. If a fix is testable as a pure function, pin it — that
   discipline caught three real bugs in one cleanup function.

---

## 1. Repo, branch, state

- **Path:** `/Users/abhishek/dev/MAC`
- **Branch:** `remove-pro-entirely`
- **origin:** `https://github.com/Abhishek-Kraj/MAC.git` (fork)
- **upstream:** `https://github.com/TheCloserApp/MAC.git`
- **Task baseline:** clean at `d545f2d`, immediately after `33ad8e7`.
  See section 10 for the verified fixes from 2026-10-19. **Do not push to `upstream`.**

Rebase/merge target for the fork's PR is `main` on upstream — not started yet,
parked deliberately.

---

## 2. Build, test, run

```bash
cd /Users/abhishek/dev/MAC

./build.sh --channel dev      # builds "build/TheCloser Dev.app"
./test.sh                     # 122 tests, compiles a SUBSET of sources
open "build/TheCloser Dev.app"
```

`./build.sh --channel dev --run` builds and launches in one step.

**Signing matters.** If "TheCloser Dev Signing" is missing from the keychain,
dev builds fall back to ad-hoc and **all TCC permissions (mic, screen
recording) silently die** — the app then looks like capture is broken when it
is not. Check `security find-identity -v` before debugging any audio issue.

**Tests compile an explicit file list** in `test.sh`. A new pure-logic source
file will not be tested until you add it to that `SOURCES` array. This already
bit us once (`TranscriptCleanup.swift` was invisible to the tests).

---

## 3. Visual verification (most important tool here)

There is no pointer in a headless run, so hover-driven behaviour cannot be
tested that way. Instead the app can photograph itself:

```bash
SNAP=/tmp/snap && rm -rf $SNAP && mkdir -p $SNAP
"build/TheCloser Dev.app/Contents/MacOS/thecloser-dev" \
  -snapshot $SNAP -surface regularCall -seedcall -seedminutes > /dev/null 2>&1 &
sleep 8; pkill -x thecloser-dev
```

Then read the PNGs in `$SNAP`. The process **never exits on its own** —
always `pkill -x thecloser-dev`.

**Flags** (all in `AppDelegate.swift`, inside the `-snapshot` block):

| Flag | What it shows |
|---|---|
| `-snapshot <dir>` | writes `thecloser-overlay-*.png`; also `-dumpviews` → `geometry.txt` |
| `-surface interview` | Interview setup form |
| `-surface regularCall` | Regular call setup form |
| `-surface chat` / `sessions` / `none` / `settings` | other surfaces |
| `-fresh` | clears the session so the setup form renders |
| `-seedtranscript` | seeds a live **interview** with 2 answered Q&As |
| `-seedcall` | seeds a **live call in progress** (growing transcript) |
| `-seedminutes` | seeds summary text |
| `-seedafter` | ends the session, to photograph the post-call state |

`saveSnapshots` captures the panel, the inspector, Settings, **and any
attached sheet** — so sheets are photographable, which is how the light-mode
sheet bug was finally caught.

**Warning:** if the app is already running with a live mic session, snapshots
capture *real* audio. That happened once and produced a genuinely useful
capture, but don't rely on it.

---

## 4. Architecture worth knowing

- **`AppDelegate.swift`** — owns the panel window: sizing, drag, 8-edge
  resize, content-height tracking, snapshot harness, permission onboarding.
- **`OverlayContentView.swift`** — the shell. `stageStack` picks
  `liveFocusStack` (one card: header / transcript / answer / composer) vs
  `standardStack` (floating bar + surface). `upperLayer` dispatches
  `PrimarySurface`.
- **`OverlayViewModel.swift`** — all state. `@Observable`.
- **`ChatSurfaceView.swift`** — chat surface, live-interview focus card, live
  call transcript, transcript history, summary surface.
- **`TranscriptFilter.swift` / `TranscriptCleanup.swift`** — pure logic, unit
  tested.
- **`Stores/MinutesGenerator.swift`** — transcript → summary prompt.
- **`Controllers/AIController.swift`** — streaming, sentinel handling.

**Surfaces:** `chat`, `interview`, `summary`, `sessions`, `resumes`,
`prompts`, `calendar`, `browser`. Any switch over `PrimarySurface` must stay
exhaustive — adding a case breaks several switches (the header title is one).

### Hard-won invariants — do not regress these

- `.preferredColorScheme(.dark)` is applied to the panel's content view, but a
  `.sheet` is presented in its **own window** and does NOT inherit it. The
  panel now pins `NSAppearance(named: .darkAqua)` so sheets inherit it. Any new
  sheet must be checked for light-mode rendering.
- The Interview prompt uses a **bare trailing comma as "still talking"**.
  Transcript cleanup must never add a final full stop, or the model answers
  mid-thought.
- A live session must **never auto-collapse** to the pill (hover collapse).
- A **manual panel size is sticky for the whole run** — that's deliberate. It's
  also why `Reset panel size` exists in the `⋯` menu.
- Only the **THEM** (system-audio) lane may trigger an answer. The YOU lane is
  display-only.

---

## 5. Product decisions already made (don't relitigate)

- BYOK only. No Pro, no payment code, no Ollama.
- Flash-class models by default. `OpenRouterDefaults.defaultModel` =
  `google/gemini-3.8-flash`; `utilityModel` = `google/gemini-3.5-flash-lite`
  (response gate + titles).
- Split capture: system audio owns questions/answers; mic is display-only.
- Role auto-derived from JD. Prep bank + live lookup + coverage gaps.
- Screen-share hiding stays.
- Editor audio: ElevenLabs preferred, Apple on-device fallback.

---

## 6. Open issues (user-reported, all unfixed except where noted)

### A. Panel geometry — original report; repaired 2026-10-19 (section 10)
1. **Panel can be dragged/resized inconsistently.** The user reports being
   unable to move or resize things and it differing per tab. Not diagnosed.
   Suspect area: `PanelResizeEdge` bands (25pt horizontal / 14pt vertical,
   34pt corners) + `windowWillResize` clamping + `minimumPanelSize(for:)`.
   Note the grab strips are invisible — the user can't tell where.
2. **Panel sometimes too short and clips its own content.** The expanded
   minimum was raised 80→160pt; the post-call clipping fix is in `b161a77`
   but the general case may remain.

### B. Summary surface — `33ad8e7`, visually verified 2026-10-19 (section 10)
   - Summary is now `SummarySurfaceView` (a primary surface) instead of a
     sheet, so it can move and resize. **Check the snapshot renders correctly
     and that drag/resize work on it.**
   - Check the header title shows `vm.minutesTitle` and switches correctly.

### C. Other known
3. Transcript cleanup applies when a question **commits to a turn**, so "um"
   is still visible mid-sentence. Acceptable for now; user has seen it.
4. Live **answers** don't yet follow the call's language (only the summary
   does). One-line prompt change; not done because it's feature work.

---

## 7. What was fixed recently (context, don't redo)

| Commit | Fix |
|---|---|
| `33ad8e7` | summary as surface, not sheet (WIP, unverified) |
| `b161a77` | post-call showed a bare bar; session flush so history isn't lost |
| `c0874b6` | all sheets rendered light-mode; added Reset panel size |
| `9c63ec9` | a call is a continuous transcript, not a Q&A card |
| `1308aba` | end-of-call summary now fires; call-tab wording |
| `fa5f70c` | TranscriptCleanup (pure, tested) |
| `06b1824` | live focus reads as a transcript; manual size sticks |
| `da60c1a` | hover-collapse triggered mid-call (close/open flap) |
| `605abd3` | flash-class default + utility models |

---

## 8. Environment gotchas

- Mac is in **light mode**, app is dark — this is why the sheet bug existed.
- Panel is at `.statusBar + 1` and non-activating; hover events don't fire
  while another app is frontmost (that's why resize uses cursor rects).
- A background `rea-agents analyze-javascript-application` job once ate 100%
  CPU for 2h and produced a 0-byte file, starving builds. **Don't leave
  long jobs running in the foreground.**
- `./build.sh` can leave a stale code signature if interrupted:
  `"invalid or unsupported format for signature"`. Fix:
  `rm -rf "build/TheCloser Dev.app" && ./build.sh --channel dev`.
- Live sessions are not flushed to `sessions.json` mid-session; they persist
  on turn writes (debounced ~400ms) and on terminate.

---

## 9. Original first suggested moves (completed; see section 10)

1. Snapshot-verify `33ad8e7` (the WIP commit) before anything else.
2. Reproduce the drag/resize complaint in every tab and find the actual cause
   before changing code — this is the user's biggest frustration and it is
   still undiagnosed.
3. Consider making the resize grab strips visible on hover (a legitimate
   fine-tune of existing behaviour, not a feature).

---

## 10. Verified fixes — 2026-10-19

Feature work remains stopped. The summary surface from `33ad8e7` renders
readably in dark mode, including the Call summary title, scrollable markdown,
Copy and Conversation actions. It was photographed before and after changes.

Panel issues diagnosed and repaired:

- Standard header/composer were hidden with hover-dependent hit testing.
  Hover is unreliable while this nonactivating panel is inactive, so its move
  handle disappeared and the bottom resize band sat below the only visible
  card, in transparent space. Both rows now remain visible.
- Empty header/composer space now uses `PanelDragArea.DragView`, an AppKit view
  tracking the entire press in screen coordinates derived from each event.
  The brand button retains its original simultaneous click/drag gesture.
- Manual sizing only disabled content tracking if the resize started in Live
  Focus, and normal surfaces restored an 800pt default. `PanelSizePreference`
  now records any manual expanded size independently of temporary surface
  minima and pill frames. Reset clears it and restores both default dimensions.
  The pure source is explicitly included in `test.sh` and covered in
  `Tests/Tests.swift`.
- A small manually sized live window could center its oversized intrinsic
  content outside the window, losing both header and composer. Manual live
  sizing now uses a constrained scrolling viewport inside the fixed chrome.

Verification:

- `./build.sh --channel dev` succeeded with the stable local dev signing identity.
- `./test.sh`: 123 passed, 0 failed.
- `-resizeprobe` now checks all eight edges/corners using multiple event samples,
  with separate run-loop turns and a pause after restoring frames. This pause
  prevents false corner failures from stale window-server geometry.
- The probe also checks all eight surface transitions at a manual 440×420,
  photographs each state with geometry, and checks collapse/reopen retention.
  Each of the eight initial surfaces, plus live interview and live call, passed:
  180 checks, no failures. Allow 12 seconds before stopping a full probe.
- Native UI verified header movement (100pt left, 40pt down), summary bottom
  resize (800→540pt), scrolling through the final summary section, retaining the
  size when switching to Browser, and Reset panel size restoring 440×800.
- Visually inspected minimum-sized surfaces and live states; header, composer,
  summary footer and whole-word Assistant labels remain readable.

Snapshot corrections: `-seedminutes` now survives the recurring surface
assertions instead of being overwritten by `-surface regularCall`. Interview
fixtures explicitly select Interview mode instead of inheriting saved Call mode.

Limits: no real audio/model/network validation was attempted. Coordinate clicks
on this nonactivating app were unreliable in CUA even for unchanged buttons;
AX button actions worked. The brand gesture was preserved rather than inferring
a product regression from that automation behavior. Keep using the app's own
snapshot/event harness and inspect the rendered images.
