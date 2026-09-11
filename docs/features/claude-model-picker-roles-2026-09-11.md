# Claude Code 会话内模型面板修复

## 复现与原因

用户的复现流程为：刚进入 Claude Code 时输入 `/model`，随后提交一个需求，再在会话工作页面执行 `/model`。问题是前面的命令补全保留 `opus / sonnet / haiku`，后面的选择面板却使用模型 ID 作为标题；两个角色指向同一个 ID 时会出现两个相同标题。

本机 Claude Code 2.1.236 的命令补全读取角色的 `value` 和说明，选择面板读取 `ANTHROPIC_DEFAULT_*_MODEL_NAME`。旧生成器把实际请求 ID 作为缺省名称写入 `_NAME`，导致两种界面的标题不一致。此问题与会话中使用的需求内容无关，不以截图中终端标签页是否相同作为判断依据。

## 修复规则

- 未填写自定义名称时，分别生成 `Opus`、`Sonnet`、`Haiku`；说明仍包含实际请求模型。
- 用户自定义名称继续用于面板标题，不影响角色标识、实际请求 ID 和 1M 上下文。
- 旧名称为空、等于自动角色标题或等于实际 ID（兼容末尾 `[1M]`）时，统一作为自动名称处理；回填、切换目标和直接生成共用同一个规则。
- 配置弹窗仅更新名称输入框的缺省提示和说明文字，保持现有结构和样式。
- `ANTHROPIC_DEFAULT_MODEL` 不接受 `haiku` 角色及其上下文后缀。默认跟随 Haiku 时，顶层 `model` 保留角色关系，环境变量的 Default 回退展开为实际目标与有效 1M 后缀。
- 恢复原生配置时，若顶层保存角色且该角色存在受管映射，一并移除角色选择；不存在受管映射的原生角色选择继续保留。

当前选择与 Default 回退可以不同。例如 CLI 保存的 `model=haiku` 和原先配置的 `ANTHROPIC_DEFAULT_MODEL=gpt-6-astra` 各有含义，单独迁移旧名称时不应重写这两个字段。

## 验证

使用独立 DerivedData 完成 Debug 构建及 55 项测试，0 失败：Claude 配置 38 项、Codex 模型配置 11 项、备份删除 6 项。覆盖同 ID 的多个角色、旧配置回填、自定义名称、角色及默认行的独立 1M、JSON/Shell 输出和恢复原生配置。独立代码复核通过。

测试日志：`/tmp/quotio-claude-role-picker-verified-tests.log`。

原生 CLI 验证使用真实配置生成器、临时 HOME、测试凭据和仅监听本机的模拟 Anthropic 接口；不使用用户登录态，不请求真实模型服务，不修改用户现有会话。

四组原生交互验证均通过：普通 Haiku、Haiku 槽开启 1M、显式 `haiku[1m]` 和三个自定义标题。每组先完成一个模拟需求，再打开会话内 `/model`，选择 Sonnet 并确认请求目标为 `glm-5.3`，然后选择 Default 并确认回退至配置的 Gemini 目标。两组 1M 在选择 Default 后用 `/context` 确认窗口为 1M。显式 `haiku[1m]` 会由 Claude 原生增加一个当前自定义模型项，这是 CLI 的保留行为，不把它改写为普通角色。

原生验证记录位于 `/tmp/quotio-claude-picker-review.5azwa5pt/`。应用已从 `build/ClaudeRolePickerVerified/Quotio.app` 启动，实际打开配置弹窗确认：三个自动名称为空值并显示角色占位名称，自定义名称说明和补全说明使用新规则，当前模型回填仍跟随 Haiku。

本机 `~/.claude/settings.json` 仅迁移三个 `_NAME` 为角色名，其余配置做语义一致性校验并保留。迁移前原文件备份到 `~/.quotio/config_backups/claude-model-picker-20260911-120234/settings.json`，权限为仅用户读写。已有 Claude 进程可能缓存环境变量，需要新启动 Claude Code 加载新名称。

## 参考

- [Claude Code 自定义模型名称与能力](https://code.claude.com/docs/en/model-config#customize-pinned-model-display-and-capabilities)
- [Claude Code 新会话默认模型](https://code.claude.com/docs/en/model-config#set-a-default-model-for-new-sessions)
