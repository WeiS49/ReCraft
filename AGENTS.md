# ReCraft Agent Instructions

The durable product and engineering rationale lives in
[`docs/PRODUCT_PRINCIPLES.md`](docs/PRODUCT_PRINCIPLES.md). Read it before
changing product behavior, permissions, data access, supported applications,
or the model strategy. The latest runtime evidence and what remains unverified
are in [`docs/VALIDATION.md`](docs/VALIDATION.md).

## Mission

ReCraft is a personal macOS utility that transforms selected text in a
supported editable control after a global shortcut and replaces it in place
without disrupting the user's work.

## Current State

The app ships the clipboard replacement path, saved rewrite tasks with
editable prompts and dedicated configurable global shortcuts, and one local
deterministic test action (`Control-Option-Command-R`). The built-in default
prompts have not passed the project's quality gate; do not describe them as
accepted. Paid model experiments need an explicit owner decision and budget
before any request is made.

## Fixed Technical Baseline

- Target Apple Silicon Macs running macOS 26 or later.
- Use Swift 6.2 and Xcode 26.1.1.
- Build a native menu-bar app with SwiftUI, AppKit where needed,
  ApplicationServices Accessibility APIs for target validation, Carbon
  `RegisterEventHotKey`, and the approved clipboard copy/paste path.
- Rewrite tasks use exactly one of two remote providers, chosen by one global
  Settings value (owner decision 2026-11-19); without a stored choice the
  provider is Claude. Each provider has one fixed model and request shape,
  called through system `URLSession`:
  - Claude: the Anthropic Messages API with `claude-haiku-5-5`,
    `thinking` disabled and `max_tokens` 4096;
  - OpenAI: the Responses API with `gpt-5.6-luna` and
    `reasoning.effort = none`.
  There is no per-task provider, model choice, retry, or automatic fallback to
  the other provider.
- Store each provider's API Key only in macOS Keychain, one item per provider.
  Apple Foundation Models are paused and are not a fallback.
- Use no third-party dependency or SDK, and no speculative provider
  abstraction beyond the two concrete clients and their enum.
- Disable App Sandbox because the core Accessibility behavior is incompatible
  with it. Do not target the Mac App Store in the current scope.
- Do not casually rename the App, Bundle ID, Keychain service or log
  subsystem: they participate in the Accessibility grant and Keychain
  identity of installed copies.
- Machine-specific signing lives in the untracked `Config/Local.xcconfig`.
  Never commit a team identifier, certificate name or machine path.

## Safety and Privacy Invariants

- Accessibility remains the only approved macOS privacy permission. After an
  explicit shortcut, ReCraft may temporarily use the general pasteboard and
  simulate Command-C/Command-V; this delivery route is an approved product
  decision and must not introduce another system permission.
- Do not add Input Monitoring, Automation, Screen Recording, Full Disk Access,
  or another permission without a new user decision.
- Act only after an explicit shortcut on the current focused editable control.
- Reject secure fields, missing copied text, changed applications, changed
  focused elements, and unavailable targets before pasting. A momentarily
  failed Accessibility read may be retried for a short bounded time; a
  confirmed different application or focused element may not.
- Keep the prior pasteboard snapshot and selected text in memory only. Restore
  the snapshot only while ReCraft still owns the staged content; never overwrite
  newer user clipboard content. A task request may send exactly the explicitly
  invoked saved complete task prompt as `instructions`, and the explicitly
  selected text as input. In a Claude request the `system` value is the task
  prompt followed by one fixed framing sentence
  (`AnthropicMessagesClient.sourceFraming`), and the only user message is the
  selected text wrapped byte for byte in `<source_text>` tags (owner decision
  2026-11-19: without them Claude answers a selection that reads like a
  request instead of transforming it). That sentence and the tags are the only
  text ReCraft adds, they are shown where a task prompt is edited, and they
  must not grow into per-task or per-type rules. The only
  user-controlled remote text is that saved task prompt and selected source.
  For both providers, never send task names, shortcuts, unselected text,
  surrounding content, clipboard snapshots, or prior requests, and never log,
  persist, hash, or otherwise analyze production selected text or model output.
- Each model invocation is one independent request to the selected provider
  only: for OpenAI a Responses API request with `store=false`, for Claude a
  single Messages API request; both have no tools and no conversation history.
  An API Key must never appear in logs, project files, preferences, or UI after
  entry; persist each only in Keychain and allow the user to update or delete
  it.
- Before model delivery, revalidate the original application and focused
  element, then repeat Command-C and require the selected text to match exactly.
  If anything changed, discard the model result without pasting.
- Treat a posted paste event as attempted delivery, not proof of an exact
  replacement. Use real application results as acceptance evidence.
- Codex may merge a following paragraph after a partial multiline paste, and VS
  Code may copy the current line for an empty selection. These are accepted
  limitations; do not add speculative adapters or newline fixes without a new
  decision.
- The remote action is supported in VS Code only when
  `"editor.emptySelectionClipboard": false`; otherwise an empty selection may
  copy and upload the current line, so that configuration is outside the remote
  support claim.
- Logs may contain only app identifiers, element role/subrole, processing
  stage, provider name (log categories `OpenAI` and `Claude`), duration,
  attempt counts, Accessibility error codes and error category. They must never contain user text, prompts, responses, or full
  control values.
- Production text inspection and remote work begin only after an explicit
  registered shortcut. The Debug-only `DebugFocusProbe` may sample
  Accessibility metadata or post a synthetic shortcut for unattended tests; it
  must stay compiled out of Release and must never read values, selections or
  the pasteboard.
- Runtime tests in real applications use newly created notes or files only,
  never the user's existing content.

## Scope and Admission

Each task contains its full editable prompt; apart from the single fixed
Claude source-framing sentence above there is no shared base, automatic
classification, hidden name/ID/type rule or extra model call is admitted.
Existing user prompts must not be silently overwritten.

Do not add chat, history, accounts, teams, cloud sync, RAG, prompt marketplaces,
task-library categories/search/import/export, providers or models other than
the two fixed above,
app adapters, databases, telemetry, launch-at-login, auto-update, public
distribution, or broader OS/device support in the current scope. Do not
generalize prompt and shortcut editing into a prompt library, scripting system,
or provider layer.

Any feature that adds a permission, service, screen, dependency, persistence
type, top-level concept, recurring configuration, or continuing cost requires
an explicit product decision. Prefer a smaller solution and evidence from the
current slice.

## Evidence and Positive Loop

Support claims are limited to the scenarios actually tested. Classify runtime
evidence as:

1. exact success;
2. safe refusal before mutation;
3. blocking defect.

Make the narrowest repair supported by evidence, then rerun the affected
checks. After three attempts at the same failure class without new evidence,
stop and either mark the application unsupported or request a new product or
risk decision. Never weaken the evidence threshold or expand scope to claim
completion.

<!-- dev-repo-init:begin (managed block; edit outside it) -->
## 检查与交付

- 交付前运行 `./check`，必须通过。CI 跑的是同一条命令。
- 项目规则在 `checks/rules.tsv`，违反时报错信息会告诉你怎么改。改代码，不要改规则。
- 不要为了通过检查而修改 `check`、`checks/`、`.github/` 或删改测试；也不要加 `noqa`、`type: ignore`、`skip` 之类的豁免。确实需要时停下来，在 issue 里说明原因。
- 改了行为就补测试。能运行的入口要有真实运行它的测试。
- 只走新分支，不直接推默认分支；不改历史。
- 不提交密钥；不加「由 AI 生成」之类的署名。
- 最后用简体中文总结：改了哪些文件、实际跑的命令和输出、没做的部分。
<!-- dev-repo-init:end -->
