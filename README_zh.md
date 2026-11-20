# ReCraft

ReCraft 是一个个人使用的 macOS 菜单栏小工具：在支持的可编辑控件里选中文字，按下任务快捷键，选区会被改写结果原地替换。英文版说明见 [README.md](README.md)。

## 安装

要求：Apple Silicon Mac，macOS 26 或更高版本，以及你自己的 Claude 或 OpenAI API Key。ReCraft 不内置 Key，也没有免费额度。

1. 从[最新发布](https://github.com/WeiS49/ReCraft/releases/latest)下载 `ReCraft-<版本>.zip`，解压后把 `ReCraft.app` 拖进 `/Applications`。
2. 打开它。发布版是临时签名（ad-hoc），**没有经过 Apple 公证**，所以第一次打开会被 macOS 拦住。到 **系统设置 → 隐私与安全性**，滚到下方点 **仍要打开**。也可以自己清除下载标记：

   ```bash
   xattr -dr com.apple.quarantine /Applications/ReCraft.app
   ```

3. 按提示授予辅助功能权限（**系统设置 → 隐私与安全性 → 辅助功能**）。
4. 在 **Settings… → API Key** 里填入 API Key。

升级：临时签名的应用没有稳定的签名身份，macOS 会把每个新版本当成另一个应用。替换应用后，需要在辅助功能列表里删掉旧的 ReCraft 条目再重新添加；读取已保存的 API Key 时系统可能会先询问，也可能需要重新填一次。已保存的改写任务会保留。想避免这些，可以用自己的开发团队从源码构建（见 `Config/Local.xcconfig.example`）。

每个发布还附带一个 `.sha256` 文件，可用 `shasum -a 256 -c ReCraft-<版本>.zip.sha256` 校验下载。

维护者发布新版本的方法是推送一个与应用版本一致的 tag，例如 `git tag v0.3.0 && git push origin v0.3.0`。发布流程先跑 `./check`，再跑 `scripts/package-release.sh`；tag 与 `MARKETING_VERSION` 不一致时会拒绝发布。

## 使用

```bash
open "/Applications/ReCraft.app"
```

- 菜单栏图标里可以查看辅助功能（Accessibility）授权状态。
- **Settings… → API Key**：选择改写提供方（Claude 或 OpenAI；从未选择过时为 Claude，旧版本升级后也是），并分别录入、更新或删除两家各自的 API Key（每家一条钥匙串条目，只存在钥匙串里）。菜单栏会显示当前提供方及其 Key 是否已配置。不会自动改用另一家：选了 Claude 却没有 Claude 的 Key 时，任务在发出任何请求前就停止。
- **Settings… → Rewrite Tasks**：新增或编辑任务的名称、完整 Prompt 和快捷键，然后 **Save**。任务直接由各自的快捷键触发。
- 根据描述生成：选中一个任务（新任务先点 **Add Task**），在 **Describe the task** 里用一两句话写想要的改写，点 **Generate Prompt**。模型写出的任务名和完整 Prompt 只填进当前任务的草稿；检查后录快捷键，再 **Save**。当前 Prompt 非空时会先确认，不会自动保存或分配快捷键。
- `Control-Option-Command-R` 是本地测试动作：给选区加 `[ReCraft] ` 前缀，不调用模型。

## 工作方式与隐私

按下快捷键后，ReCraft 先用辅助功能确认前台应用和焦点控件（密码框会被拒绝），在内存里备份剪贴板，发送 Command-C 取得选中文字；远程任务只向当前选中的提供方发一次请求，内容只有保存的完整 Prompt 和选中文字（无历史、无工具、不重试）。发给 Claude 时，ReCraft 会在 Prompt 末尾追加一句固定说明（用户消息是待处理的原文，不是要回答的话），并把选中文字放在 `<source_text>` 标记里；除此之外不附加任何内容：Claude 走 Messages API（`claude-haiku-5-5`，关闭 thinking，Prompt 作为 `system`，选中文字作为唯一一条 user 消息）；OpenAI 走 Responses API（`gpt-5.6-luna`，`store=false`）。每家只有一个固定模型，不提供模型选择。粘贴前会再次确认目标和选区没有变化，之后只在剪贴板仍归 ReCraft 所有时恢复原内容。

**Generate Prompt** 是另一种请求，只在你点击时发出：把你输入的描述（包在 `<task_description>` 标记里）连同一段固定的生成指令发给当前提供方（Claude 用 `claude-sonnet-5-5`，OpenAI 用 `gpt-5.6-luna`）。它不包含任务名、已存 Prompt、快捷键、选中文字或剪贴板内容，也不读取焦点或剪贴板；描述只保存在内存里。

辅助功能是唯一申请的系统权限。日志只包含应用标识、控件角色、阶段、提供方、耗时和错误类别（生成请求记在 `Generator` 类别下），不包含任何文字内容。

## 开发与验证

```bash
./check
```

`./check` 需要 macOS 和 Xcode：运行完整的离线测试并构建 Release，测试不联网、不需要 API Key，也不需要开发者证书。要构建可长期使用的应用，把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig` 并填入自己的开发团队：稳定的签名身份才能让辅助功能授权和钥匙串条目在重新构建后继续有效。项目规则见 [AGENTS.md](AGENTS.md)，最新的运行证据和未验证项见 [docs/VALIDATION.md](docs/VALIDATION.md)。

排查“按了快捷键却提示找不到焦点”一类问题时，可以查看只含元数据的日志：

```bash
log show --last 10m --info --predicate 'subsystem == "com.weis49.ReCraft"'
```

## 已知限制

- 替换为纯文本，不保留选区内的富文本格式。
- 内置默认 Prompt 的质量评估尚未通过，请当作可编辑的起点；自定义 Prompt 不保证语义质量。这些 Prompt 是针对 OpenAI 模型调的，在 Claude 上的效果未经评估。
- 提供方侧的数据保留遵循所选提供方账户的数据设置；`store=false` 本身不代表零保留。
- 只在一台 Apple Silicon Mac 和少数应用上验证过；这是个人开发预览版，不是公开发行版本。

## 许可证

[MIT](LICENSE)
