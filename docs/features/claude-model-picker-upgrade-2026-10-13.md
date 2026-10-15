# Claude Code 模型配置与页面调整

2026-10-14 追加的 Fable、平台/账号展示与原生 Default 实测，见 [Fable 与模型菜单展示调整](claude-fable-and-model-presentation-2026-10-14.md)。以下保留首轮升级的实现与验证记录。

## 已实现行为

- 新配置使用 CLI 原生 `/model` 菜单，不生成额外 `modelPicker`；已有自定义菜单原样保留。
- 页面移除精选列表编辑卡片；后台继续兼容原生、旧精选、追加与外部结构，旧菜单的条目、顺序和未知字段不会因重新配置而丢失。
- 默认模型、角色实际请求目标、菜单条目和子代理模型分别存储，不因刷新模型目录互相覆盖。
- 角色改用可搜索选择器，支持 CPA 别名和手动输入；实际请求槽不提供角色自引用选项。后续已增加可选的 Fable 槽。
- 模型槽表格只保留用途、实际模型和 1M；移除显示名称输入列，但保留配置中的存量 `_NAME`。新配置自动使用 Opus、Sonnet、Haiku 角色名称。
- 会话内 `/model` 面板预览、命令补全切换与网关发现开关保留在原高级设置卡片。
- 子代理设置放在模型槽同一张卡片底部，使用原分段控件；新配置跟随当前会话，也可以指定角色或完整模型 ID。Haiku 后台任务与子代理分开设置。
- 扩大 Claude 配置弹窗；快速修改表单时取消旧手动 JSON 预览任务，防止过期结果覆盖新配置。
- 预览切换、子代理模式以及手动 JSON／Shell 格式切换继续复用 `QuotioCapsuleSegmentedControl`，遵循项目胶囊样式、主题色与滑块动画。

## 兼容与配置归属

旧 Codable 草稿缺少新字段时，不接管磁盘中的 `modelPicker`，并继续固定旧生成器原来使用的 Haiku 请求目标。新格式草稿经过编码和解码后仍保持子代理继承语义。

从现有 `settings.json` 读取的菜单会保留条目顺序、用户标题、说明、`behavesAs` 及未知扩展字段；整数扩展字段不经过浮点转换。结构无法识别时，整段外部 JSON 原样保留，用户主动选择其他模式后才重新生成菜单。

Quotio 新建的菜单带 `quotioManaged=true` 归属标记。恢复官方连接仅删除受管菜单，保留外部菜单；手动恢复说明也明确相同条件。页面回填菜单时设置 `shouldWrite=false`，保留原标题、说明与扩展字段；修改模型槽不会重新生成存量菜单。只有明确调用旧菜单编辑功能时才启用写入，仍保留原验证与恢复逻辑。

主动编辑并写入菜单时，同一个完整模型选择器只保留第一项，普通与 `[1m]` 变体保持独立。已有磁盘菜单与只读预览保留同一模型的不同账号条目。不同角色即使指向同一实际模型，也保留各自语义。配置不新增 `availableModels` 限制，已有权限、Hooks 和其他配置继续按原合并方式保留。

子代理切换到继承时，会删除 JSON 中的旧 `CLAUDE_CODE_SUBAGENT_MODEL`，Shell 输出也会清除旧变量。仅 Shell 保存无法撤下已有 JSON 菜单或清理其中的固定子代理设置，因此提交前提示改用 JSON 或双写保存。

## CLI 边界

自定义 `modelPicker` 的写入需要 Claude Code 2.1.242 或更新版本，并保存到用户 JSON 配置中。新配置使用原生列表，保留而不改写的已有菜单不会阻止模型槽配置；明确写入菜单时仍执行原版本及 JSON 校验。Shell 导出不能承载菜单结构。

精选模式仍保留 CLI 自身的 Default，并可能附加当前会话模型。追加模式可能合并已被原生列表覆盖的条目。CLI 版本、组织限制及网关发现还会影响最终面板，预览不会把这些动态内容当作已验证结果。

此次没有增加推理请求验证，也没有将菜单标签、`[1m]` 后缀或上下文配置当作上游能力保证。

## 首轮升级验证记录（历史）

- Debug 构建通过；相关回归覆盖 Claude 配置、菜单配置、凭据保护、备份删除和界面渲染，共 71 项。
- 中文浅色、深色界面通过 SwiftUI/AppKit 实际渲染检查，检查了角色名称、长说明及子代理布局。
- Claude Code 2.1.287 在隔离配置目录中正确显示三个角色和额外自选模型的中文名称、说明及顺序。
- 在实际 `/model` 面板选择 Opus，CLI 保存 `model=opus`；重启后使用对应实际模型目标，菜单结构和独立子代理设置仍保留。
- 独立只读审查发现的 ShellOnly 清理、外部菜单归属、手动恢复说明问题已修复。提交测试在校验缺失时立即抛错退出，避免测试回归触碰真实 Shell。

测试和 CLI 核验使用临时配置、假凭据和本机关闭端口，不发送推理请求。语言截图测试仅修改测试进程的易失偏好，不持久化用户语言设置。

结果与产物：

- 最终结果：`/tmp/quotio-claude-upgrade-complete-tests.xcresult`
- 最终日志：`/tmp/quotio-claude-upgrade-complete-tests.log`
- 界面截图：`/tmp/quotio-claude-upgrade-visuals/light.png`、`dark.png`
- CLI 面板记录：`/tmp/quotio-claude-upgrade-visuals/cli-panel.txt`
- 构建应用：`/tmp/quotio-claude-upgrade-derived/Build/Products/Debug/QuotioPlus.app`

## 参考

- [Claude Code modelPicker](https://code.claude.com/docs/en/settings-reference#modelpicker)
- [Claude Code 模型配置](https://code.claude.com/docs/en/model-config)
- [CC Switch 模型列表编辑器](https://github.com/farion1231/cc-switch/blob/d9a62313c8a276216ed40245c638753606831e95/src/components/providers/forms/ClaudeStackModelsField.tsx)
- [Magpie Claude Code 配置实现](https://github.com/yetone/magpie/blob/30869e35a7cddfaa349c036d8f517298ab7713cd/internal/agent/claude.go)

## 三处页面调整的回归范围

本轮保持自动／手动配置方式、JSON／Shell 存储、默认模型、角色映射、1M、CPA 别名、模型搜索及手动输入、高级上下文参数、连接测试和备份布局不变。移除的两个入口不会清空旧数据；子代理仅移动位置。

新增真实文件回归覆盖原生默认行为、旧受管菜单、追加菜单与未知外部结构，以及存量名称、独立默认模型、独立子代理和权限字段的保留。明暗渲染使用新配置与已有配置两种夹具，验证三列表格、同卡片子代理和高级区预览；渲染前后配置数据必须完全一致。

本轮完成验证：

- Debug 构建通过；最终 74 项相关回归全部通过，无失败、跳过或运行时警告。
- 真实文件验证新配置不生成菜单、旧菜单/名称/独立子代理不被重写，以及旧后台明确菜单编辑仍能保存。
- 新配置和已有配置的浅色、深色原生截图均已检查。
- 独立只读审查提出的后台编辑写入标记与旧注释问题均已修复并复核，无遗留问题。

产物：

- 构建日志：`/tmp/quotio-claude-three-changes-build.log`
- 最终结果：`/tmp/quotio-claude-three-changes-final-tests.xcresult`
- 最终日志：`/tmp/quotio-claude-three-changes-final-tests.log`
- 界面截图：`/tmp/quotio-claude-three-changes-visuals/light-native.png`、`dark-native.png`、`light-existing.png`、`dark-existing.png`
- 构建应用：`/tmp/quotio-account-identity-derived/Build/Products/Debug/QuotioPlus.app`
