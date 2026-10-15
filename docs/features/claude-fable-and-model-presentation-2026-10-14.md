# Claude Code Fable 与模型菜单展示调整

## 页面与配置行为

- 模型槽增加 Fable，排列为 Opus、Fable、Sonnet、Haiku。新增槽沿用搜索、代理别名、手动输入和独立 1M 设置。
- 新配置以及旧三槽配置没有选择 Fable 时，不写 `ANTHROPIC_DEFAULT_FABLE_MODEL`。Default 或子代理引用未映射的 Fable 时保存原生 `fable`，实际版本由 CLI 解析，预览不宣称固定某个官方模型。
- 固定角色的 `_DESCRIPTION` 使用 `平台/模型名称`，例如 `zhipu/glm-5.3[1m]`；`_MODEL` 仍保存实际请求 ID。已有平台前缀不会重复添加。
- 裸模型使用模型目录明确返回的归属，或之前保存且匹配同一模型的说明提示。缺失或冲突的归属不会被臆测为 OpenAI；展示归属不能当成实际服务账号。
- Default 在 Quotio 预览中只显示一行有效目标，不复制 CLI 自身的推荐与来源长句。
- 子代理保持位于模型槽同一张卡片底部。没有重新增加精选列表卡片、名称输入框或内部 Tab，其余布局和功能保持。

Fable 明确使用时，已知 CLI 版本低于 2.1.257 会提示升级；旧三槽配置继续正常保存。恢复旧三槽备份时，回填会删除表单原有的 Fable 映射，之后再次保存不会重新写回它。

## Magpie 菜单与已有数据保护

仅格式化带有明确 `via magpie` 说明标记的已有条目：左侧显示原模型名称，右侧显示平台和该条目已有的账号昵称或邮箱。例如：

```text
GPT-6.1-Sol       Codex · work@example.com
GLM-5.3[1m]      智谱 · 工作账号
```

没有账号资料时仅显示平台；路由组显示为路由组，不伪造账号。用户原有独立标题与说明保留，已有角色自定义 `_NAME` 也保留。

保存时直接处理磁盘当前菜单对象，只调整可识别行的 `label` 和 `description`，不重建菜单。原请求 ID、条目顺序、同模型不同账号、`behavesAs`、未知扩展字段、整数精度和菜单归属保持。只读预览同样保留同模型的多个账号；明确调用旧菜单编辑功能时，继续沿用既有的选择器去重规则。

Magpie 的归属判断使用独立 `claude.model_picker` stash，不依赖说明中的 `via magpie`。Magpie 自己刷新时会重新生成菜单文本；再次保存 Quotio 的 Claude 配置会应用本次展示规则。本轮没有改写外部程序。

## 原生 Default 实测结论

使用本机 Claude Code **2.1.287**，临时配置目录、假 API Key、关闭的本机端口，以及 `--bare --setting-sources '' --settings` 隔离测试。只打开 `/model` 查看菜单，不选择模型、不修改用户真实配置。

| 实验 | 结果 |
| --- | --- |
| 原生四槽与 `ANTHROPIC_DEFAULT_MODEL=sonnet` | 保留 `Default (recommended)` 与原生长描述，目标为 `gemini-3.8-flash-high` |
| 试加 `ANTHROPIC_DEFAULT_MODEL_NAME` 和 `_DESCRIPTION` | 内置 Default 标题与描述完全不变；这些探测字段不进入生产输出 |
| `replaceBuiltInOptions=true`，追加 `model=default` 的短标题条目 | 内置 Default 仍保留，短标题成为额外一行，无法覆盖或隐藏内置项 |
| 删除 `ANTHROPIC_DEFAULT_MODEL` | 仅去掉来源后缀，长描述仍在；同一夹具的 Default 目标从 Gemini 改为 Opus 槽的 `glm-5.3[1m]` |
| 已有 Magpie 追加菜单 | 四槽右侧显示平台/模型；追加行左侧模型名、右侧平台和账号；独立自定义行保持 |

结论：当前原生公开配置不能删除、改名或覆盖内置 Default 的描述。建议保留它作为返回默认模型的入口，并保留指定默认目标的变量；不能仅为去掉来源文案而改变 Default 的实际解析目标。Quotio 的简洁预览属于本应用展示，不应冒充已经修改 CLI 原生行。

## 构建与回归结果

- Debug 构建成功；最终 10 组相关回归 **170 项通过，0 失败，0 跳过，运行时警告为空**。
- 验证覆盖 Fable 映射、1M、Default、子代理、版本提示、旧字段解码、旧备份恢复再保存、平台缺失与冲突、Magpie 原 JSON 合并及多个账号预览。
- Claude 凭据归属、备份删除、模型目录，以及 Codex、OpenCode、Pi 相关回归全部通过。
- 使用真实 SwiftUI/AppKit 渲染新配置、已有菜单与旧三槽配置的浅色/深色截图，渲染前后配置对象一致。

结果与产物：

- 回归结果：`/tmp/quotio-fable-presentation-final-tests.xcresult`
- 最终构建和测试日志：`/tmp/quotio-fable-presentation-final-tests.log`
- CLI 对照结果：`/tmp/quotio-fable-presentation-visuals/cli-default-probe-results.json`
- CLI 菜单文本：`/tmp/quotio-fable-presentation-visuals/cli-native-panel.txt`、`cli-magpie-panel.txt`
- 界面截图：`/tmp/quotio-fable-presentation-visuals/light-native.png`、`dark-existing.png` 等六张
- 构建应用：`/tmp/quotio-account-identity-derived/Build/Products/Debug/QuotioPlus.app`

## 参考

- [Claude Code 模型配置](https://code.claude.com/docs/en/model-config)
- [Claude Code modelPicker 配置](https://code.claude.com/docs/en/settings-reference#modelpicker)
- [Magpie 配置实现](https://github.com/yetone/magpie/blob/15105161e0ad23d022f823ece3ed78fb9090a503/internal/agent/claude.go)
