# ReCraft Product Principles

## Core Job

**For** one person **when** they have selected text in a supported editable
macOS control, ReCraft helps them transform that text with one global shortcut
and safely replace it in place.

The product optimizes for low friction, reliability, semantic fidelity, and
fast response. It is not a chat product or a general automation platform.
Its longer-term direction is a configurable text rewriting tool, while the
accepted MVP proved one fixed, high-frequency action before configuration. The
approved next milestone adds a small set of configurable rewrite tasks without
changing the core job.

## Product Model

- Core objects: selected text, a rewrite action, and a replacement result.
- Core runtime states: unavailable, idle, processing, delivery sent, and safe
  refusal. Exact success is an acceptance classification established by the
  visible target result and native undo, not by event submission alone.
- Primary workflow: select text, press a shortcut, receive an in-place result.
- Platform concepts reused: menu bar, global shortcuts, Accessibility
  authorization, focused controls, target-app undo, macOS Keychain, and network
  availability.

The first implementation targets only the current Apple Silicon Mac on macOS
26.6. Compatibility with another machine, operating-system version, or user is
outside the current product model.

## Delivery Stages

### Stage A: Walking Slice

The walking slice answers one question:

> Can ReCraft use a registered global shortcut, Accessibility target checks,
> and temporary clipboard copy/paste to transform a selection in multiple real
> apps with acceptable behavior?

It must include:

- a native Swift menu-bar app;
- one fixed `Control-Option-Command-R` shortcut;
- Accessibility trust status and an explicit user-initiated authorization
  prompt;
- one deterministic local transformation that visibly and exactly changes
  the selection without an LLM;
- transient processing, success, and failure feedback that does not steal
  focus;
- Accessibility checks for the original application, focused element, and
  secure fields;
- temporary use of the general pasteboard, simulated Command-C/Command-V, and
  ownership-aware restoration that preserves newer user clipboard content;
- runtime validation in Codex, Google Chrome textarea, Visual Studio Code, and
  Apple Notes;
- content-free diagnostic logging.

It must not contain an LLM, API key, network request, preset management,
settings, provider layer, or another text-delivery mechanism.

### Stage B: Ready-to-use MVP

Stage B starts only after the Stage A checkpoint passes. Its first baseline
adds:

- `Control-Option-Command-P` for organizing rough or dictated text into a
  concise Coding Agent prompt without inventing requirements;
- one built-in, non-editable instruction set;
- OpenAI Responses API using `gpt-5.6-luna` with
  `reasoning.effort = none`, `store=false`, no tools, and no history;
- one minimal API Key entry, update, and delete flow backed only by macOS
  Keychain;
- missing-key, network/API failure, empty-result, changed-selection, and
  concurrency handling.

Faithful English translation is a later action and does not enter this baseline.

Apple Foundation Models are paused because the tested baseline did not meet the
quality threshold. They are not submitted, repaired further, or used as a
fallback. At Stage B acceptance time, custom actions, prompt editing, model
selection, and extended-thinking controls remained later product decisions;
Stage C below records the subsequently approved narrow exception.

### Stage C: Configurable Rewrite Tasks

Stage C begins only from the accepted Stage B baseline. Its detailed
requirement and acceptance contracts (the configurable-task specification, the
owner-selected task-only decision and its test-call allocation) are internal
project records and are not part of this repository; the rules that bind
implementation are restated here and in `AGENTS.md`.
It admits one narrow configuration model:

- saved rewrite tasks with a name, editable task prompt, and one dedicated
  configurable global shortcut;
- initial Coding Agent Prompt, Formal French, and Formal English tasks;
- no artificial task-count cap, while interaction and support claims remain
  limited to the owner's normal three to four daily tasks;
- no invocation-time picker; each task is invoked directly by its shortcut;
- task configuration stored in local preferences, with the API Key still only
  in Keychain;
- one full, editable prompt per task, sent without a shared base (the one
  exception is the fixed Claude source-framing sentence recorded in
  `AGENTS.md`), classifier,
  hidden task-type rule or extra model call; and
- a fresh single-policy default/compatibility/holdout acceptance gate and the
  remaining installed-App checks before this feature is considered complete.

Coding may add relevant engineering checks through its editable default, but
must not invent project facts, narrow explicit prohibitions or omit required
approval waiting. Requested perspective/role conversion belongs in the task
instruction. Formal French and English remain faithful in their own defaults.
The app enforces structural/request/delivery safety, not hidden semantic rules.
General polishing, if needed, is an ordinary task, not a compulsory base.
V1's failed gate and v2's completed pilot remain historical; neither is rerun or
retrospectively declared a production pass.

This decision supersedes the earlier plan for a separate fixed-English action.
It does not admit a prompt marketplace, task-library organization, model or
provider selection, history, sync, or another delivery mechanism.

### Provider decision (2026-11-19)

The owner later admitted exactly one global provider setting with two fixed
choices, superseding "OpenAI only" wherever this document names a single
provider or model:

- Claude (default when nothing is stored, including after upgrade): Anthropic
  Messages API with `claude-haiku-5-5`, thinking disabled, `max_tokens` 4096;
  the task prompt is the `system` value and the selected text the only user
  message;
- OpenAI: the unchanged Responses API request with `gpt-5.6-luna`,
  `reasoning.effort = none` and `store=false`.

Each provider has its own Keychain item. There is no per-task provider, model
choice, retry, or automatic fallback, and every request, privacy and logging
rule below applies equally to both. The built-in prompts were tuned against the
OpenAI model; their quality on Claude has not been evaluated.

## Technical Baseline

- Swift 6.2 and Xcode 26.1.1.
- One native macOS application target and one XCTest target.
- SwiftUI `MenuBarExtra` for the persistent utility surface.
- AppKit only for lifecycle details and a nonactivating transient HUD.
- ApplicationServices `AXUIElement` for focused-control validation.
- Carbon `RegisterEventHotKey` for approved global chord registration without
  raw global keyboard observation.
- `NSPasteboard.general` plus synthetic Command-C/Command-V for the approved
  copy and replacement path.
- System `URLSession` for OpenAI Responses API requests in Stages B and C,
  and for Claude Messages API requests after the 2026-11-19 provider decision.
- Security framework APIs for one Keychain-backed API Key per provider.
- Xcode Automatic Signing with a stable Apple Development identity for Release
  builds; disposable hosted tests may override signing to ad-hoc.
- `OSLog` for metadata-only diagnostics.
- No third-party packages.
- App Sandbox disabled; local signed execution only.

Shortcut registration must not observe raw keyboard input. The walking slice
must verify that no Input Monitoring permission appears. A conflict during
exclusive shortcut registration is a visible startup failure, not a reason to
install an event tap.

## Safe Replacement Protocol

On a shortcut:

1. Reject the request if another transformation is active.
2. Confirm Accessibility trust; capture the frontmost application, focused
   element, role/subrole, and reject secure controls.
3. Snapshot the current pasteboard in memory, stage a private ownership marker,
   send Command-C, and require a non-empty plain-text selection.
4. For a deterministic action, transform immediately. For a model action,
   restore the original pasteboard and send only the explicitly invoked saved
   complete task prompt as instructions, without any shared instruction, and
   the selected text as input, in one independent,
   non-stored OpenAI request, or one independent Claude request with the
   prompt as `system`, per the provider decision above.
5. Immediately before model delivery, require the original application and
   focused element, repeat Command-C, and compare the selected text exactly with
   the captured selection. Abort without pasting if anything changed.
6. Stage the replacement, recheck target identity and pasteboard ownership, and
   send Command-V once.
   If the deterministic action loses its target or cannot create the paste
   event, it may leave the transformed result on the pasteboard and explicitly
   offer manual paste. The remote action restores/refuses instead.
7. After a short bounded delay, restore the original pasteboard only if ReCraft
   still owns the staged replacement. Preserve newer clipboard content.
8. Clear selected text, model output, and clipboard snapshots from
   application-owned memory when the request ends.

Do not retry an ambiguous paste or claim exact delivery from successful event
posting alone. Native application results, surrounding text, formatting, and
undo behavior remain the runtime evidence.

## Privacy and Permission Boundary

- Accessibility is the sole approved macOS privacy permission. Temporary use of
  the general pasteboard and simulated Command-C/Command-V after an explicit
  shortcut is approved and must not add another system permission.
- Only the saved task snapshot, selected text, model output, and prior pasteboard
  snapshot may exist transiently in application memory for the active operation.
- After the user presses a task shortcut, only that saved task's complete prompt
  may be sent as instructions, without a hidden prefix/suffix, and only
  the explicitly selected text may be sent as input. The only user-controlled
  remote text is the saved task prompt and selected source. Task names,
  shortcuts, clipboard snapshots, unselected text, surrounding control content,
  and prior requests must never enter a request.
- Text captured by the running App and production model output must never enter logs,
  files, preferences, analytics, or persistence. A user may explicitly provide
  and approve credential-free test fixtures for a versioned benchmark report;
  approved synthetic prompt-gate inputs and outputs may be retained for audit as
  required by the Stage C spec. The production App must never create that
  evidence automatically. Saved task names and prompts are explicit local
  configuration stored in preferences and are not captured source text. The API
  Key persists only in macOS Keychain and must never be displayed again, logged,
  or written to the project.
- Startup status checks and shortcut-triggered Keychain reads must not present
  authentication UI. An inaccessible item fails safely; credential changes
  remain explicit Settings actions.
- Secure fields always fail closed.
- The application must not inspect text on startup, on focus changes, or in
  the background. Inspection begins only after an explicit ReCraft shortcut.
- The sole non-production exception is the Stage C spec's explicitly invoked
  benchmark harness. It may send only approved synthetic fixtures, must not
  inspect focus or pasteboard state, and cannot read or send user-selected text.
- Use `store=false`, no tools, and no conversation history. Do not create
  feedback attachments containing user text.
- `store=false` disables storage of the Response for later API retrieval; it is
  not a promise of zero provider-side abuse-monitoring retention. Applicable
  retention follows the OpenAI account's data controls and policy. Claude
  requests likewise carry no tools or history; their retention follows the
  Anthropic account's data controls and policy.

## Interaction Rules

- The primary action is always one dedicated configured global shortcut on an
  existing selection; invocation never requires a picker.
- ReCraft must not activate itself or remove focus from the target control.
- Processing, success, and failure feedback is brief and nonactivating.
- Failure messages identify actionable categories such as permission denied,
  missing API Key, no selection, unsupported control, changed selection,
  network/API failure, or empty model output. They do not reveal selected
  content.
- Only one request may run at a time. Additional shortcuts during processing
  are safely refused rather than queued.
- After success, the caret ends after the replacement. Target-app undo must be
  tested before an application is declared supported.

## Quality Floor and Acceptance Evidence

### Stage A gate

- Codex, Chrome textarea, Visual Studio Code, and Apple Notes each receive a
  real single-line and multiline smoke test with mixed English, Chinese, emoji,
  and line breaks.
- Missing copied text, secure controls, and focus changes do not produce a
  wrong-target paste.
- Nonselected text, native undo, formatting, and pasteboard restoration remain
  acceptable in the tested scenarios.
- Build and unit tests pass, and System Settings shows no new Input Monitoring,
  Automation, Screen Recording, or Full Disk Access permission.

Known accepted limitations are: Codex may merge the following paragraph after a
partial multiline paste, and VS Code may copy the current line when no text is
selected. The remote action is supported in VS Code only with
`"editor.emptySelectionClipboard": false`, because the default empty-selection
copy behavior could otherwise send the current line without an explicit text
selection. Do not broaden the implementation to hide these limits.

### Stage B gate

- The Coding Agent Prompt action is evaluated on 8–10 representative
  personal-use samples.
- At least 80 percent of outputs are directly usable or need only a minor
  edit.
- Preserve the input's primary language unless the selected text explicitly
  requests translation.
- No accepted sample reverses meaning, invents a requirement, or corrupts a
  code fragment, name, number, or constraint.
- Preserve API benchmark timing for every request and record observed
  end-to-end timing for representative real-use samples. Do not invent an
  unmeasured service-level objective or a complete runtime distribution when
  only part of the manual set was timed.
- Codex completes one real single-line and one real multiline model replacement;
  failures and changed selections preserve the original text.
- Disconnecting the network, an API failure, or a missing Key safely preserves
  the original selection.
- Inspection confirms that user text is absent from logs and persistence.

### Stage C gate

- The fresh task-only per-task quality gates, compatibility probes and holdout
  in the approved completion contract pass without a Critical result or an
  unresolved critical anchor. The owner-approved budget is phased and bounded;
  existing v1/v2 outputs do not replace these gates.
- Three-task and four-task catalogs survive editing and relaunch, and shortcut
  conflicts do not damage the last working configuration.
- Coding Agent Prompt, Formal French, and Formal English each complete a real
  runtime replacement, and the unchanged delivery path passes the supported-app
  smoke matrix.
- Existing selection, clipboard ownership, target revalidation, single-operation,
  native Undo, request privacy, Release build, and signature checks do not regress.
- Arbitrary user-authored prompts receive no semantic-quality guarantee; support
  claims apply only to the tested initial tasks and request/delivery boundaries.

## Intention, Trade-off, Evidence, and Next Action

Each implementation loop must state:

- **Intention:** one observable outcome or high-risk assumption.
- **Trade-off:** reliability and text safety outrank coverage; semantic
  fidelity outranks creativity; current-machine simplicity outranks
  compatibility.
- **Evidence:** the exact automated check or runtime matrix that decides the
  outcome.
- **Next action:** promote an exact success, keep a safe refusal unsupported,
  or stop on a blocking defect.

The loop is:

`high-risk assumption -> smallest complete slice -> fixed evidence -> narrowest
repair -> rerun -> pass or stop`

After three repair attempts at the same failure class without new evidence,
stop. Mark the app unsupported or request a new product or risk decision.
Never weaken the evidence threshold, add a fallback, or expand the scope to
manufacture completion.

## Feature Admission and Reopening Triggers

A new feature enters scope only when it improves the core job or removes a
demonstrated blocker without crossing the quality floor.

- The approved remote baseline is Luna with `reasoning.effort = none`. Reopen
  model choice only if representative real-use evidence misses the quality or
  latency threshold. Since the 2026-11-19 provider decision, Claude Haiku 5.5
  with thinking disabled is the second fixed, globally selectable baseline.
- Reconsider Apple Foundation Models only after a new model or measured prompt
  result clears the same fidelity threshold; never add it silently as fallback.
- Configurable tasks, prompt editing, and dedicated shortcut editing are approved
  only within the Stage C spec because the fixed Coding Agent Prompt passed its
  end-to-end gate. Reopen extended thinking or a broader task-library model only
  after representative use produces a new blocking need.
- Reconsider another delivery mechanism only if the approved clipboard path
  produces a new blocking defect and the user accepts the added complexity or
  privacy cost.
- Reconsider punctuation/function-key shortcuts, cross-layout guarantees, or
  global keyboard observation only after the approved A–Z recorder proves
  insufficient; never add a new permission silently.
- Reconsider launch at login only if manual launch repeatedly prevents use.
- Reconsider wider compatibility, signing, notarization, installation, and
  updates only when another machine or user enters the intended audience.

## Durable Non-Goals

- Chat, conversation memory, transformation history, accounts, teams, sharing,
  cloud sync, RAG, knowledge bases, and prompt marketplaces.
- Preset marketplaces, task categories, search, import, export, sync, sharing,
  or discovery beyond the approved small saved-task list.
- Multiple model providers, routing, provider SDKs, and generic model
  protocols built for hypothetical future services. (The two fixed providers
  of the 2026-11-19 decision are the only exception.)
- Delivery mechanisms beyond the approved Command-C/Command-V path, raw
  keyboard event monitoring, application-specific adapters, and GUI automation
  frameworks.
- Databases, analytics, telemetry, user-text logging, and background text
  observation.
- General rich-text editing, batch processing, streaming replacement, queues,
  plugins, scripting, and extensibility points.
- Intel support, older macOS support, public distribution, Mac App Store,
  launch at login, auto-update, and deployment infrastructure.
