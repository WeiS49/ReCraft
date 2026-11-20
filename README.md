# ReCraft

ReCraft is a personal macOS menu-bar utility: select text, press a task shortcut, and replace the selection with a rewrite.

## Status

Version 0.3.0 (4). Run `./check` before delivering a change: it runs the full
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

## Install

Requirements: an Apple Silicon Mac running macOS 26 or later, and your own
Claude or OpenAI API key. ReCraft has no bundled key and no free tier.

1. Download `ReCraft-<version>.zip` from the
   [latest release](https://github.com/WeiS49/ReCraft/releases/latest), unzip
   it and move `ReCraft.app` to `/Applications`.
2. Open it. Release builds are ad-hoc signed and **not notarized by Apple**,
   so macOS blocks the first launch. Go to **System Settings → Privacy &
   Security**, scroll down and click **Open Anyway**. Alternatively, clear the
   download flag yourself:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ReCraft.app
   ```

3. Grant Accessibility when ReCraft asks for it (**System Settings → Privacy &
   Security → Accessibility**).
4. Enter your API key under **Settings… → API Key**.

Updating: an ad-hoc signed app has no stable signing identity, so macOS treats
every new release as a different application. After replacing the app, remove
the old ReCraft entry from the Accessibility list and add it again; macOS may
also ask before the new build can read the saved API key, or you may have to
enter the key again. Saved rewrite tasks are kept. To avoid this, build from
source with your own development team (see `Config/Local.xcconfig.example`).

Each release also carries a `.sha256` file; verify the download with
`shasum -a 256 -c ReCraft-<version>.zip.sha256`.

Maintainers publish a release by pushing a tag that matches the app version,
for example `git tag v0.3.0 && git push origin v0.3.0`. The workflow runs
`./check`, then `scripts/package-release.sh`, and refuses a tag that does not
match `MARKETING_VERSION`.

## Run and configure

```bash
open "/Applications/ReCraft.app"
```

ReCraft appears in the menu bar without a main window. Check Accessibility status there. Use **Settings… → API Key** to choose the rewrite provider (Claude or OpenAI; Claude when nothing has been chosen, including after an upgrade) and to enter, update or delete each provider's Keychain-backed API Key. The menu shows the selected provider and whether its key is configured. A task never falls back to the other provider: with Claude selected and no Claude key, the task stops before any request.

In **Settings… → Rewrite Tasks**, select a task or **Add Task**, edit its name, complete prompt and shortcut, then **Save**. Shortcuts use A–Z with at least two modifiers; reserved or conflicting shortcuts are rejected. Tasks run directly from their shortcuts without a picker.

To write a task from a short description, select a task (use **Add Task** first for a new one), type what the rewrite should do under **Describe the task**, and click **Generate Prompt**. The model's task name and complete prompt fill only the selected task's draft: review them, record a shortcut, then **Save**. Generating over a non-empty prompt asks for confirmation first, and nothing is saved or registered automatically.

| Initial shortcut | Action |
| --- | --- |
| Control-Option-Command-P | Coding Agent Prompt |
| Control-Option-Command-F | Formal French |
| Control-Option-Command-E | Formal English |
| Control-Option-Command-R | Local deterministic `[ReCraft] ` prefix; no API call |

Existing catalogs are preserved, so names and shortcuts may differ. Each provider has one fixed model and there is no model selection: Claude uses `claude-haiku-5-5` with thinking disabled; OpenAI uses `gpt-5.6-luna`, effort `none`. The built-in prompts were tuned against the OpenAI model and have not been evaluated on Claude.

## Privacy and delivery

After an explicit shortcut, ReCraft checks Accessibility trust, the foreground
application, the focused control, and recognized secure-field roles before it
snapshots the clipboard in memory and copies the selection. It sends one
request, only to the selected provider, containing exactly the saved complete
task prompt and only the selected text, with no tools, history or retry. To
Claude (`api.anthropic.com/v1/messages`) the `system` value is the prompt plus
one fixed sentence saying the user message is source text to transform, not a
message to answer, and the selection is the only user message, wrapped in
`<source_text>` tags; to OpenAI
(`api.openai.com/v1/responses`) they are `instructions` and input, with
`store=false`.

**Generate Prompt** is a separate request sent only when you click it: the
description you typed, wrapped in `<task_description>` tags, plus one fixed
generation instruction text go to the selected provider (Claude:
`claude-sonnet-5-5`; OpenAI: `gpt-5.6-luna`). It never contains task names,
saved prompts, shortcuts, selected text or clipboard content, and it does not
read the focused control or the pasteboard. The description stays in memory
only.

Before delivery, it rechecks the original application and focused control, recopies the selection and requires an exact match. It pastes once and restores the prior clipboard only while it still owns the staged content. `Replacement sent` confirms event submission; actual replacement and Undo need visible verification.

In the source candidate, snapshot capture treats an unavailable item list, an
unreadable representation, or a pasteboard change during capture as a safe
refusal. It never interprets an unavailable item list as an empty clipboard and
never overwrites newer content while trying to restore a failed stage.

Accessibility is the only requested macOS privacy permission. API Keys persist only in Keychain, one item per provider; normal reads are noninteractive. Explicit task configuration and the provider choice are plaintext local preferences. Production selections, outputs and clipboard snapshots are not logged or persisted. Provider-side retention follows the selected provider account's data controls; `store=false` alone does not establish zero retention.

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
  development preview; release builds are not notarized.

See [product principles](docs/PRODUCT_PRINCIPLES.md) and the
[validation record](docs/VALIDATION.md).

## License

[MIT](LICENSE)
