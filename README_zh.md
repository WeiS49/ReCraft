# ReCraft

ReCraft 是一个个人使用的 macOS 菜单栏小工具：在支持的可编辑控件里选中文字，按下任务快捷键，选区会被改写结果原地替换。英文版说明见 [README.md](README.md)。

## 使用

```bash
open "/Applications/ReCraft Clipboard Spike.app"
```

- 菜单栏图标里可以查看辅助功能（Accessibility）授权状态。
- **Settings… → API Key**：录入或更新 OpenAI API Key（只存在钥匙串里）。
- **Settings… → Rewrite Tasks**：新增或编辑任务的名称、完整 Prompt 和快捷键，然后 **Save**。任务直接由各自的快捷键触发。
- `Control-Option-Command-R` 是本地测试动作：给选区加 `[ReCraft] ` 前缀，不调用模型。

## 工作方式与隐私

按下快捷键后，ReCraft 先用辅助功能确认前台应用和焦点控件（密码框会被拒绝），在内存里备份剪贴板，发送 Command-C 取得选中文字；远程任务只把保存的完整 Prompt 和选中文字发给 OpenAI Responses API（`gpt-5.6-luna`，`store=false`，无历史、无工具）。粘贴前会再次确认目标和选区没有变化，之后只在剪贴板仍归 ReCraft 所有时恢复原内容。

辅助功能是唯一申请的系统权限。日志只包含应用标识、控件角色、阶段、耗时和错误类别，不包含任何文字内容。

## 开发与验证

```bash
./check
```

`./check` 需要 macOS 和 Xcode：运行完整的离线测试并构建 Release，测试不联网、不需要 API Key，也不需要开发者证书。要构建可长期使用的应用，把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig` 并填入自己的开发团队：稳定的签名身份才能让辅助功能授权和钥匙串条目在重新构建后继续有效。项目规则见 [AGENTS.md](AGENTS.md)，最新的运行证据和未验证项见 [docs/VALIDATION.md](docs/VALIDATION.md)。

排查“按了快捷键却提示找不到焦点”一类问题时，可以查看只含元数据的日志：

```bash
log show --last 10m --info --predicate 'subsystem == "com.local.ReCraftClipboardSpike"'
```

## 已知限制

- 替换为纯文本，不保留选区内的富文本格式。
- 内置默认 Prompt 的质量评估尚未通过，请当作可编辑的起点；自定义 Prompt 不保证语义质量。
- 只在一台 Apple Silicon Mac 和少数应用上验证过；这是个人开发预览版，不是公开发行版本。
