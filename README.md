# ReCraft

ReCraft is a personal macOS menu-bar utility: select text, press a task shortcut, and replace the selection with a rewrite.

## Status

Version 0.2.1 (3). Run `./check` before delivering a change: it runs the full
offline XCTest suite and a Release build with ad-hoc signing. No test calls
the network or needs an API key.

The 2026-11-18 target-recognition fix is documented in
[`docs/VALIDATION.md`](docs/VALIDATION.md). In short:

- Identifying the shortcut target now retries for up to about half a second
  when Accessibility momentarily reports no focused application or control,
  instead of refusing on the first failed read. Revalidation retries failed
  reads only; a confirmed different application or control still refuses.
- A control that answers "no value" for the protected-content flag (WeChat's
  message field does) is no longer treated as an unverifiable secure field.
  Secure roles and a true protected-content flag are still refused.
- Every target refusal logs its step, Accessibility error code and attempt
  count (metadata only) under the `Target` log category.

The quality of the built-in default prompts has **not** passed the project's
own acceptance gate; treat them as starting points to edit.

## Run and configure

```bash
open "/Applications/ReCraft Clipboard Spike.app"
```

ReCraft appears in the menu bar without a main window. Check Accessibility status there. Use **Settings… → API Key** to enter or update the Keychain-backed API Key when needed.

In **Settings… → Rewrite Tasks**, select a task or **Add Task**, edit its name, complete prompt and shortcut, then **Save**. Shortcuts use A–Z with at least two modifiers; reserved or conflicting shortcuts are rejected. Tasks run directly from their shortcuts without a picker.

| Initial shortcut | Action |
| --- | --- |
| Control-Option-Command-P | Coding Agent Prompt |
| Control-Option-Command-F | Formal French |
| Control-Option-Command-E | Formal English |
| Control-Option-Command-R | Local deterministic `[ReCraft] ` prefix; no API call |

Existing catalogs are preserved, so names and shortcuts may differ. Model selection is unavailable: remote tasks use `gpt-5.6-luna`, effort `none`.

## Privacy and delivery

After an explicit shortcut, ReCraft checks Accessibility trust, the foreground
application, the focused control, and recognized secure-field roles before it
snapshots the clipboard in memory and copies the selection. It sends exactly
the saved complete task prompt as instructions and only the selected text as
input, with `store=false`, no shared instruction, tools, history or retry.

Before delivery, it rechecks the original application and focused control, recopies the selection and requires an exact match. It pastes once and restores the prior clipboard only while it still owns the staged content. `Replacement sent` confirms event submission; actual replacement and Undo need visible verification.

In the source candidate, snapshot capture treats an unavailable item list, an
unreadable representation, or a pasteboard change during capture as a safe
refusal. It never interprets an unavailable item list as an empty clipboard and
never overwrites newer content while trying to restore a failed stage.

Accessibility is the only requested macOS privacy permission. API Keys persist only in Keychain; normal reads are noninteractive. Explicit task configuration is plaintext local preferences. Production selections, outputs and clipboard snapshots are not logged or persisted. Provider-side retention follows the account's data controls; `store=false` alone does not establish zero retention.

## Offline verification

```bash
./check
```

`./check` needs macOS with Xcode. It keeps DerivedData and logs under the
ignored `.build/` directory, requires the full suite (100+ tests) to execute,
and fails if Debug-only diagnostics appear in the Release binary. It signs ad
hoc, so it needs no developer certificate.

To build an app you can keep using, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set your own development team: a stable signing
identity keeps the Accessibility grant and the Keychain item valid across
rebuilds.

Debug builds contain a metadata-only diagnostic (`DebugFocusProbe`) that can
sample focus state or post a synthetic shortcut for unattended runtime tests;
it is compiled out of Release. The app uses SwiftUI/AppKit, Carbon hotkeys,
system URLSession and Apple frameworks only. App Sandbox is disabled for the
approved Accessibility workflow.

## Limits and evidence

- Custom and default prompts have no semantic-quality guarantee; review model
  output before relying on it.
- The target check verifies the foreground application, the focused control
  and recognized secure-field signals. It does not prove the control is
  editable, so a copyable read-only control can still reach the request and
  paste steps.
- Replacement uses plain text and does not preserve selection-internal rich formatting.
- In Codex, avoid selecting the trailing paragraph break.
- VS Code remote use requires `"editor.emptySelectionClipboard": false`.
- Evidence covers one user and one Apple Silicon Mac. This is a personal
  development preview, not a notarized release.

See [product principles](docs/PRODUCT_PRINCIPLES.md) and the
[validation record](docs/VALIDATION.md).
