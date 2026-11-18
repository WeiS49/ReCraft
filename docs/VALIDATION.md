# ReCraft Validation Record

This file separates automated evidence, observed runtime evidence and what is
not verified. A successful build or a posted key event never substitutes for a
visible result in the target application.

## Target-recognition fix — 2026-11-18

Report: in Apple Notes the first shortcut press sometimes shows
"No focused application / text control" and an identical second press works;
"Selection changed; original text preserved" also occurs. Environment at test
time: macOS 27.2.1, Xcode 26.1.1.

| Check | Result | Evidence boundary |
| --- | --- | --- |
| Full offline suite via `./check` | **PASS** | 102 executed, 0 skipped, 0 failures; Release build; no Debug-only strings in the Release binary |
| Metadata focus probe, Debug build launched through LaunchServices | **Observed** | Steady-state focus reads succeeded in Notes, Claude, Chrome, VS Code and Ghostty. During application activation the focused application and control were unreadable (`-25212`/`-25204`) for 0.4–1.8 s |
| WeChat message field | **Defect confirmed and fixed** | Protected-content read returns `kAXErrorNoValue` (`-25212`), which the old code classified as unverifiable and always refused |
| Deterministic shortcut in a new Notes test note | **Exact success** | Synthetic Control-Option-Command-R; the selected word gained the `[ReCraft] ` prefix and the clipboard was restored. Repeated on the Debug build, the Release candidate and the installed app |
| Remote task shortcut in the same note | **Replacement sent** | One request, 5.0 s, clipboard restored; output quality not judged |
| Shortcut 0–3000 ms after activating Notes, fixed build | **No capture failure in 12 presses** | Capture succeeded on the first attempt each time |
| Same presses against the previous build | **No capture failure in 10 presses** | The reported first-press failure was **not reproduced** with either build |
| Shortcut after 7 min idle | **No capture failure in 2 presses** | A stale-frontmost-application-after-idle cause was not supported |

What this does and does not establish:

- The reported first-press failure was not reproduced. Synthetic presses lack
  a physical keyboard, the user's input method, and other running tools
  (dictation overlays, launchers) that may take keyboard focus for a moment.
- The fix addresses the failure class rather than a proven trigger: a refusal
  that disappears on an immediate second press is a transient read, and
  capture now repeats that read for up to about 0.5 s (20 attempts, 25 ms
  apart) before refusing.
- The safety rules are unchanged except one classification: "no value" for
  the protected-content flag now counts as "attribute not published". A
  confirmed different application or focused element, a secure role, or a
  true protected-content flag still refuses.
- If a refusal recurs, the `Target` log category records the failing step,
  Accessibility error code and attempt count:

  ```bash
  log show --last 10m --info --predicate 'subsystem == "com.weis49.ReCraft"'
  ```

- Not exercised: physical-keyboard runs, the "Selection changed" report,
  Chrome / VS Code / Codex end-to-end runs, and Undo.

## Rename to ReCraft — 2026-11-18

Version 0.3.0 (4) renames the app from "ReCraft Clipboard Spike" to "ReCraft"
and the bundle identifier, log subsystem and Keychain service prefix from
`com.local.ReCraftClipboardSpike` to `com.weis49.ReCraft`.

- `./check` passes from a clean build: 102 executed, 0 failures.
- A renamed app is a new application to macOS: the Accessibility grant must be
  given again and the API key entered again. Saved rewrite tasks live in the
  preferences domain of the bundle identifier and have to be copied once.
- Not verified at commit time: any shortcut run of the renamed app, because
  that needs the new Accessibility grant from the user.

## Unattended runtime testing

A Debug build signed with a stable development identity and launched through
LaunchServices (`open -n -g <app> --args ...`) keeps the Accessibility grant;
running the executable directly from a shell does not. `DebugFocusProbe`
accepts:

- `--focus-probe-output <file>`: sample focus metadata of the frontmost app;
- `--debug-post-hotkey <virtual keycode>`: post a synthetic
  Control-Option-Command shortcut (15 = R, the local test action);
- `--debug-poster-only`: drive another running instance without registering
  shortcuts;
- `--debug-activate <bundle id>` with `--debug-activate-leads-ms <list>`:
  activate a target and press after the given delays.

## Earlier evidence

Before this repository was started, the clipboard replacement path and the
first fixed remote action were accepted for one user on one Apple Silicon Mac
across Codex, Apple Notes, a Chrome textarea and Visual Studio Code, within
the limits listed in the README. The default rewrite-task prompts later failed
their semantic quality gate and remain unaccepted. Those records, including
raw benchmark material, are kept privately and are not part of this
repository.
