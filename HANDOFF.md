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

---

## 11. Bug sweep queue — 2026-10-19 (branch `bugsweep`)

Source: four read-only wiring audits (shell/window, live session, surfaces/data,
settings/config) plus a feature inventory. **R** = re-checked against code or
on-disk data by the orchestrator; **C** = agent traced in code; **S** =
suspected, needs a runtime check. One fix at a time, snapshot proof +
`./test.sh` per fix. Invariants: screen-share hidden, BYOK, no Pro.

### P0 — data loss, security, core promise
| ID | Issue | Evidence | V |
|---|---|---|---|
| B1 ✅ | History hides every session from earlier launches: the default workspace is never saved, so each launch gets a new UUID (88 sessions, 79 workspace IDs) | WorkspaceStore.swift:19-29, HistoryPanelView:56/150 | R |
| B2 ✅ | A live call keeps recording into a different session after ⌘N, History open, or Delete Session; ⌘N monitor swallows the key unconditionally | AppDelegate.swift:720-731, VM continueSession / startNewSession, SessionStore.delete | R/C |
| B3 ✅ (signed builds) | API keys stored plaintext in the UserDefaults plist, no Keychain | VM:590-640 (e.g. :623) | R |
| B4 ✅ | In-app browser grants mic/camera to any origin; no camera usage string | WebPanelView.swift:184-192 | R |
| B5 ✅ | Screen-share hiding not proven for sheets, NSOpen/SavePanel, popovers, menus; inspector is capturable by design | AppDelegate swizzle :2210-2241 | S |
| B6 ✅ | Any JSON decode error loads an empty store; the next write overwrites sessions.json (no backup) | JSONStore.swift:40-47, SessionStore init | S |

### P1 — core flows broken
| ID | Issue | Evidence | V |
|---|---|---|---|
| B7 ✅ | Start is blocked for Apple on-device (and Type mode) without an ElevenLabs/xAI key | VM:2927 | R |
| B8 ✅ | Placeholders sent raw: `{ROLE}` `{COMPANY}` (+ preset `{TARGET_ROLE}` …); only `{NAME}` replaced | AIController.swift:68, SessionMode.swift:49/60/71 | R |
| B9 | Answer depth ignored once a seeded or custom preset exists (always) | SessionMode.swift:40, PromptStore seeded():206-212 | C |
| B10 ✅ | Default audio source is Mic, so the user's own speech triggers answers (HANDOFF §5 says split capture) | VM:54-55 | R |
| B11 ✅ | Post-call stale THEM caption; it also hides every post-End status ("Writing…", "Summary failed") | VM endCapture, ChatSurfaceView:128-149 | C (seen in snapshot) |
| B12 ✅ | The summary lands up to 90s later and overrides whatever surface the user is on, even a new session | VM:2613-2614 | C |
| B13 ✅ | The summary can't be reopened once left, and is lost on quit; "Saved to Session notes" points to in-memory notes with no UI | NotesManager.swift, CSV:1514, NotesPanelView unreferenced | R |
| B14 ✅ | A ⏳ on the first exchange holds the attached JD/résumé blob as the question fragment | AIController.swift:197-198, VM:1992-1996 | C |
| B15 ✅ | TranscriptCleanup splits `Node.js`, `3.5`, `10:30`, `1,000` | TranscriptCleanup.swift:88-94 | R |
| B16 ✅ | Setup leaks: pendingAttachments duplicate across Start/End/Start; interviewResumeSessionID never cleared; a resumed session overrides sessionMode and the prompt pick | VM:1836/1858-1874/2670-2671, :368 | C |
| B17 ✅ | No text field outside a live session: ⌘N and starter cards lead to a chat with nothing to type into | InputBarView:270-288, CSV:1011 | C (matches §10 snapshot) |
| B18 ✅ | Empty-session litter: 65 of 88 sessions have 0 turns; History lists them | SessionStore.startNewSession:304-314 | R |
| B19 ✅ | "Continue call/interview" starts the mic at once, contrary to its tooltip; it shows for plain chats too | CSV:1229/1244 | C |

### P2 — misaligned UX
| ID | Issue | Evidence | V |
|---|---|---|---|
| B20 ✅ | Pill drifts down ~(height−64)pt on each chat/live open-close (expand top-pinned, collapse bottom-pinned); origin persisted | AppDelegate:1519-1521 | S |
| B21 ✅ | Reset panel size always targets 440×800 | AppDelegate:1379-1384 | C |
| B22 | Model-visibility toggles ignored by the overlay picker; each catalogue fetch re-hides user picks | ModelFilterStore:71, OpenRouterCatalog:524-540 | C |
| B23 | ⋯ "Model:" popover inside a Menu likely can't present | TopStripView:241 | S |
| B24 | Header title edit applies to the active session on any surface; commit locks auto-title even when unchanged | TopStripView:40-44/499-505, SessionStore:437 | C |
| B25 | Replay welcome tour from pill/bar-only renders clipped; first-run completion hook never fires | PreferencesView:354, OCV:27-36 | C |
| B26 | Missing-key banner says "open API keys" but lands on General | showPreferences, PreferencesView:8 | C |
| B27 | Hover auto-collapse counts only bar clicks as engagement; a hover-opened form collapses mid-typing | InputBarView:33-39/159/163 | C |
| B28 | Brand hover dwell not cancelled by press/drag; expands mid-drag | InputBarView:388-408 | S |
| B29 | OpenCode-only users: gate, titles, prep and embeddings are hard-wired to the OpenRouter key | VM:2287, AIController:340, EmbeddingService | C |
| B30 | ⌘⏎/⌘⇧⏎ and menu-bar-icon hiding are tied to isRecording, not the session (pause/text-only) | AppDelegate:403-406/2143 | C |
| B31 | ⌃⇧-arrow resize hotkeys grabbed globally even when hidden; hotkey move unclamped | HotkeyManager:82-85, AppDelegate:892 | C/S |
| B32 | Detached browser: closing its window doesn't re-show it; window level set in wrong order (ends at 3) | BrowserWindow.swift:51-53/119-125 | C |
| B33 ✅ | Pause sends the pending transcript ignoring auto-generate and the gate | VM:1802-1806 | C |
| B34 | Screen Recording notice never clears until relaunch | AppDelegate:2127/2131 | C |
| B35 ✅ | Summary: interviews use the meeting-minutes prompt; YOU speech excluded; title follows the tab, not the session | MinutesGenerator, VM:2543 | C |
| B36 | Export/copy status invisible off the chat surface | CSV:143-149 | C |
| B37 | Regenerate on an older bubble retries the last request | AIController:287-298 | S |

| B38 — legacy | ⏳ sentinel leaks into session title/preview in History | History snapshot 2026-10-19 | R |

Decisions (user, 2026-10-19): B13 save the summary with its session and make it
reopenable ("Saved with this session"); B17 show the "Ask anything" field
whenever chat is open; B4 browser media uses WebKit's per-site prompt, camera
stays denied. B10 follows HANDOFF §5 (split capture default).

Fixed log: B1 — WorkspaceStore persists its seed; orphaned workspace ids are
migrated at launch. Verified over two relaunches: 1 workspace, 88/88 sessions
on it, History Interview 24 / Regular call 64 (was 0).
B2: startNewSession/continueSession refuse while a session is live; ⌘N, the
pencil and ⋯ New Session share `requestNewSession()`; ⌘N monitor is exact ⌘N
in the overlay only; Delete Session and History rows disabled while live.
Harness-verified: live requestNewSession/continueSession/⌘N keep the active
session; ⌘⇧N ignored; idle ⌘N opens a new chat.
B7: Apple on-device and a typed Regular call no longer need a transcription
key (`missingTranscriptionKey`); Automatic still asks for one — open question.
Harness ran all 32 preference/key combinations.
B15: only detached marks are re-spaced; a dot glued inside a token is never split or capitalised after. Pinned by testTranscriptCleanupKeepsDottedAndNumericTokens.
B10: fresh installs default to You + Them (`AudioSource.saved`); a saved choice wins. Pinned by testAudioSourceDefaultsToSplitCapture.
B8: `PromptPreset.resolvingPlaceholders` fills {NAME} and drops lines with any other unfilled placeholder; built-in "User context: {ROLE} at {COMPANY}" lines removed. Checked on real presets (Interview drops 3 template lines, Meeting/Call 1). Pinned by testPromptPlaceholdersResolveOrDrop.
B3: keys live in the login Keychain (`SecretStore`, service = bundle id, not synced, cached); launch migrates plist copies, removing each only after read-back matches. Verified over two launches: plist keys gone, Keychain items present and equal to the originals, no prompt, keys load. Correction (user decision): Keychain only when the build has an Apple Team ID (`SecretStore.usesKeychain`). A self-signed dev build's Keychain identity is its binary hash, so every rebuild asked for the login password; dev builds keep keys in the plist as before. The two dev keys were restored to the plist (stale Keychain copies left in place). B7b (user decision): Automatic with no cloud key starts on Apple; the gear stays amber (`lacksCloudTranscriptionKey`).
B4: browser mic requests get WebKit's per-site prompt; camera and camera+mic are denied (`WebPanelView.Coordinator.mediaDecision`).
B6: confirmed worse than suspected: the launch migration saved the empty store at once. `JSONStore.load` now moves an undecodable file to `<name>.corrupt-<time>.json` (all stores). Pinned by testJSONStoreKeepsUndecodableFile; not reproduced on real data.
B5: probe (alert sheet, popover, NSOpenPanel, read via CGWindowListCopyWindowInfo) found the sheet and popover capturable (sharing=1); swizzling `order(_:relativeTo:)` too makes all of them 0. Menu-bar item stays capturable (hidden during calls by design). Note: the dev build's saved "Hide from screen sharing" is OFF on this Mac (user setting, left as is).
B11: `stopInterviewSession` clears `transcription`; snapshot shows no THEM strip after End and the "Writing call summary…" status visible.
B18: `ChatSession.isUntouched` / `prunedUntouched`; new sessions replace an untouched active one, launch drops untouched ones except the active. History on real data: Interview 24→16, Regular call 64→7. Pinned by testUntouchedSessionsArePruned.
B38: not a current bug — the 12 stored ⏳ turns all predate 24b3fb6 (the drop logic, 2026-10-19 05:51Z); current code removes them. Legacy rows left as is.
B20 (+ part of B31): expanding from the pill now pins the bottom, like collapsing; programmatic frames (animate, restore, ⌘⇧-arrow move) are clamped on screen (`ScreenPlacement.clamp(_:screenFrame:visibleFrame:)`). The user's pill had ended 33pt below the screen. Harness: 3 open/close cycles keep the pill at y=300 on the response-panel path (was −296pt per cycle); a pill at y=−33 returns to 0. Pinned by testPanelIsClampedOnScreen.
B39 (new, user-reported): History was reachable only via ⋯ inside an open surface — now a History button on the bar.
B40 (new, user-reported): during a live session the bar showed only "Ask anything" + send; End call, Settings and History were only in ⋯, so a live call read as an unclosable window. The live bar now has Pause/Resume (hidden for typed sessions), a red End button (same action as ⋯ → End call) and the Settings gear (user decision), in interview and call alike.
B41 (user request): ✕ on a non-live surface goes to the home bar instead of the pill, and reopening stays home (`goHome`, `wentHome`); summary → chat and live → minimize are unchanged; Esc still minimizes and reopen restores.
B42 (user decision, reverses 5c97480): Settings is an overlay surface again (`PrimarySurface.settings`, `openSettings`). The panel takes `settingsSize` 720×640 while it is open (min 640×520), never records it as the user's size, and restores the exact previous frame on close; ✕ returns to the surface it opened over; a mid-call auto-send does not close it; no separate window. Harness: opened from chat, interview setup, live and home — always 720×640, back to the same frame. Resize probe: settings PASS; the 8 edge checks need the real mouse idle (a live cursor shifted the synthesized down point by 10pt during this run).
Settings reorganized by use: General = Privacy (screen-share hiding) → Recording (engine, audio source — was ⋯-only — call offer) → Appearance → Onboarding; AI tab renamed "Keys & Models"; key fields show "✓ Saved" / "Not set" (non-empty check, no network test); OpenCode hint shortened. All five tabs snapshot-checked at 720×640.
B43 (user decision): one panel size for every screen — `expandedSize` 640×720 (or the user's manual size) for Interview, History, Browser, Settings, Chat and Summary; the home bar shares the width. Only the live focus card still hugs its content height. Replaces the 440×800 default, the 440×360 answer height and Settings' own 720×640; Reset panel size targets the same size (fixes B21). Harness: all screens 640×720, home 640×160. Setup form scrolls with Start pinned below it.
B44 (user decision): a Regular call no longer sends each finished line to the AI (the Call prompt turned every line into a 3-bullet mini-MOM). Lines are committed to the call transcript with no reply (`commitCallLine`, Apple segment reset like a send), also on Pause and End, so the minutes include the last line; questions typed or sent with ⌘⏎ during a call carry a "[Call transcript so far]" block (sent, not stored); End still writes the MOM. Interview mode unchanged. Harness: two lines + End → 3 transcript lines, no AI requests. Asking with context not exercised against a live model.
B17: `showsConversationComposer` — Chat, or a past interview/call opened from History, shows Ask anything + send beside the bar buttons; a question about a past Regular call carries its transcript. Snapshot-checked on a past interview, a past call, chat (field shown) and home (not shown).
Calls, modelled on Wispr Flow's Notetaker (behaviour studied via REA and the user's own Wispr notes; nothing copied): the call prompt closes itself after 20s; minutes are a TL;DR, one section per topic, Next steps owner-first, Decisions, Open questions only if any; a live call has one-tap "What did I miss? / Suggest a question / What should I say?" chips (answered from the transcript) and labels the user's asked lines YOU; when the call app releases the mic during a recorded session a 15s "Call ended? Writing notes in Ns · Keep recording" countdown ends the session (the call app returning, Keep recording or End cancel it). Each harness-verified; no live model call made.
Interview reliability: B14 holds only the spoken words of a ⏳ fragment and carries its turn's résumé/JD context to the next turn (harness-verified); B16 Start keeps interview mode and the form's prompt pick when resuming, consumes the picked session, End clears unsent staged context (harness-verified: cleared); B19 Continue is offered only on interview/call sessions (legacy .normal calls via mode), tooltip says it starts listening; B33 Pause only answers when auto-answer is on and the line warrants a reply (code-reviewed — mic path not exercised).
Interview answers (research: 8 open-source copilots, ideas only): answer length follows Brief / Standard / Deep via `AnswerDepth.lengthRule`, appended last to the model prompt so a saved preset's own length rule no longer wins (sent, not stored). Detection: a long unpunctuated line or a tag question ("…, right?") is no longer answered on word count alone; it goes to a small act check (utility model, 2.5s, last 2 interviewer lines as context) returning question / request / scenario / follow-up → answer, confirmation / small talk → one sentence, statement → nothing, incomplete → wait; on failure `looksLikeQuestion` decides. B35/B13/B12: interviews get their own debrief (takeaway, Questions asked, What they cared about, How you answered — from the user's own captured speech, else "Not captured" — Strengths, Gaps, To research, Thank-you email); every summary is saved with its session (`ChatSession.minutes`, old files still load) and reopened from the conversation's "View summary" button, History included; it only opens itself if that session is still on screen, otherwise "Summary saved with the session". Harness: seeded debrief saved to disk, button and debrief snapshot-checked. Act check, length rule and debrief not yet exercised against a live model.
Controls rearranged (user request: "a lot of features, but the placement is not correct"). Rule: one home in Settings, plus at most one quick place where it is used. New Settings tab Interview & Calls = Recording (engine, audio source, language, call offer) + Answers (depth, auto-answer, model, think-first); General gains You (Your name); Keys & Models is keys + model list; Prompts has a "Use for" mode picker instead of following `vm.sessionMode`. Setup forms keep per-interview inputs (session, résumé, context, prompt, prep last) and show one Options summary line with Change → `vm.openSettings(tab: .interviewCalls)`; the call form's subtitle no longer claims it answers as they talk. While live, the bar's gear opens a quick-options popover (`LiveSessionOptions`: answers, auto-answer, model, listen to, transcript strip, focus — only what applies — and All Settings…; user decision). ⋯ trimmed from 20–24 items to session items + a Window submenu + Settings/Quit. The pencil, ⋯ New and ⌘N are refused while a session is live (`requestNewInterviewSession` no longer ends it). Snapshot-checked: both setup forms, all Settings tabs, live interview/call. The popover itself is not photographable by the harness (bitmap capture has no popover backdrop; the bar clips overlays) — check it in the app. Harness data hygiene: `-seedtranscript`, `-seedcall` and `-fresh` now write into one throwaway session that is deleted after capture, and the active session is restored (they had appended fixture turns to the real active session on every run, and `-fresh` used the view model's startNewSession, which asks the AI to retitle the closed session). The store was cleaned with a backup first (`sessions.backup-20261020-171306.json`): 52 exact fixture Q&A pairs removed from 8 sessions, 4 sessions that held only fixtures dropped (29 → 25 sessions, 792 → 688 messages). Verified: three seeded runs leave the store and active session unchanged. Titles of the 4 trimmed sessions were generated while fixtures were present (e.g. "…and Fabric Rollout") and were left as they are.
Interview test kit (Tests/live): `run_scripted_interview.sh` feeds interview_script.json (12 interviewer lines, 3 candidate lines, an expected outcome each) through `handleThemSilence` — the engines' own silence path — with real model calls, the setup form's résumé/context, and a throwaway session; `run_live_interview.sh` plays the same script out loud with `say` into a real interview (system audio → THEM) and matches turns back to lines with timing; `score.py` prints PASS/FAIL per line, answer length against the depth band, the say-aloud first line, and the debrief's sections. `testObserver` reports each auto-answer decision. Fixed from the first run: a line judged not to need an answer stayed in the strip and was judged — and sent — with the next one, so "Can you hear me okay?" was answered together with the statement after it (`judgedPrefix` + `TranscriptFilter.unjudgedTail`). Scripted runs 2 and 3: detection 12/12, debrief 9/9, Deep answers 193–286 words, store unchanged. Open: the prepared bank answers off-target questions without calling the model ("structure the rollout plan across the four entities?" → the bank's "legacy ERP version mismatches" answer; "a time you disagreed with a stakeholder" → "pushback on departmental data silos"), and bank answers ignore the depth setting. The played-audio run has not been done yet.

### P3 — cleanup (ask before deleting)
Dead or orphaned: NotesPanelView, ManualInputPanelView, ScreenshotPanelView,
TranscriptionPanelView, AIResponsePanelView, ModePickerView,
WorkspaceSwitcherView; `.prompts`/`.calendar` surfaces; `pillAnchor` (written,
never read); `.captureScreenshot` observer; Pro token relay in
TranscriptionManager; direct-provider branches and keys with no UI;
`showMinutesSheet`; stale comments (AppDelegate:382/672, README grip,
"We handle everything"). Peer server (flag off) has open-LAN HTTP, a 6-digit
code with no rate limit, and JS injection via `code`. Fix it before ever
enabling the flag.
