# Pi 安装兼容与本地统计读取修复（2026-09-07）

## 现场诊断

- 当前可执行入口是 `~/.local/bin/pi`，符号链接指向 npm 包 `@earendil-works/pi-coding-agent/dist/cli.js`，包版本为 `0.84.2`。Homebrew 常用入口 `/opt/homebrew/bin/pi` 与 `/usr/local/bin/pi` 均不存在。因此能确定当前使用 npm 包形式，不能仅凭该路径区分最初运行的是 npm 命令还是基于 npm 的官方安装脚本。
- Pi 的默认提供商为 `openai-codex`，没有注册 CPA provider 插件。“已安装”是可执行文件存在的状态；Quotio 的“已配置”指代理接入完成，不等于 Pi 已登录任意提供商。旧状态徽标直接输出 `Installed` 等英文，没有经过本地化。
- 默认会话目录中有 28 个 JSONL 文件：12 个正式会话文件，16 个 pi-subagents 辅助转录。正式会话采用 `type`、`id`、`timestamp`、`message`；扩展转录采用 `recordType`、`runId` 等协议。旧的两种读取器要求每行都有 `type`，因此将正常扩展转录标成 `read_partial` / `hasErrors`，页面显示读取或分析失败。
- 用户提供的日志是 SwiftUI/AppKit 首响应者跨窗口错误，没有 Pi 文件路径或解析诊断。当前没有证据将焦点问题与统计读取失败关联，本次没有据此修改全局焦点逻辑。

## 修改内容

### 安装发现及运行环境

新增 `PiAgentInstallation`，由 Pi 的检测和自动配置共同使用：

- 保留应用继承的 PATH 优先级；补充 Apple Silicon / Intel Homebrew、`~/.local/bin`、`~/bin`、npm、Bun、pnpm、Yarn、Volta、asdf、mise 的常见入口。
- 支持 `HOMEBREW_PREFIX`、`NPM_CONFIG_PREFIX` / `npm_config_prefix`、`PNPM_HOME`、`BUN_INSTALL`、`VOLTA_HOME`、`ASDF_DATA_DIR` 等显式前缀。
- 枚举 nvm / fnm 的 Node 版本目录，支持 `NVM_DIR`、`FNM_DIR`、XDG 和 macOS 的 `~/Library/Application Support/fnm`，采用数字排序，避免 v9 优先于 v22。
- 新旧 npm 命名空间 `@earendil-works` 与 `@mariozechner` 均能通过实际包元数据取得版本。独立二进制或包装器回退到 `--version`，限制为 3 秒及短版本输出，失败输出不作为版本。
- 探测和 CPA 插件安装共用补全后的 PATH，使 GUI 启动也能找到 Node/npm。检测不运行交互 shell、不执行安装、不修改 Pi 配置。

状态徽标使用既有本地化键；Pi 卡片显示检测到的版本，并解释“已安装”和“已配置”的区别。

### 两类统计共用协议识别

新增 `PiSessionEntry.decode`：

- 正式 `type` 记录继续进入现有解析器，包括深层嵌套的正式子会话；不按整个 artifacts 目录排除文件。
- 只有匹配已验证的 pi-subagents v1 辅助协议时才按非正式会话忽略，包括 message、tool_start、tool_end、stdout、stderr、truncated。
- 损坏 JSON、不支持的辅助类型和错误版本仍报告部分失败，保留可读取的正式记录。
- 正式会话及其副本继续使用稳定事件身份去重。用量仍包含已保存的压缩/分支摘要消耗，不重复将 reasoning 加入 output。

Pi 的用量错误文件本来就会重读，本次恢复协议识别后能清除旧错误。调用分析增加 Pi 专属解析版本标记，使旧成功指纹失效一次，随后继续复用 SQLite 日摘要。没有另建缓存系统，也不需要用户删除 SQLite 或旧缓存。

## 明确的统计覆盖范围

本次恢复的是**正式保存的 Pi 会话和子会话**。第三方扩展转录不保证总有对应正式会话，也没有可直接复用的 SessionEntry 身份，不能强行转换后相加。

现场只读比对发现，一部分转录中的 assistant 用量在当前正式会话扫描范围内没有匹配项。因此代码注释与界面均不再将全部转录称为“已有重复副本”：

- 用量统计选择 Pi，或综合统计存在 Pi 来源时，显示已保存会话的统计范围及扩展转录排除说明。
- 调用分析选择 Pi/综合时，也明确提示仅保存在扩展转录中的调用未纳入。
- 提示不依赖是否存在统计事件；只有转录、没有正式会话的目录也会看到范围说明。“读取成功”表示文件按当前协议处理成功，不代表所有第三方扩展都完整覆盖。

自定义目录通过应用环境中的 `PI_CODING_AGENT_DIR` / `PI_CODING_AGENT_SESSION_DIR` 生效。未进入应用环境的 shell 私有变量及任意 `--session-dir` 路径不能自动推断。独立转录导入、跨正式会话/转录的持久化身份映射不属于本次实现。

## 验证

`PiCompatibilityTests` 使用临时文件覆盖安装路径、显式前缀、Node 版本排序、符号链接、新旧 npm 包、GUI Node 查找、失败/超时版本探测、状态键、正式子会话去重、坏记录、仅转录目录、自定义目录、SQLite 旧错误恢复和调用指纹复用。

最终结果：**26 项通过、0 失败、0 跳过**（Pi 兼容 15 项、SQLite 迁移 9 项、调用生命周期 2 项），应用编译成功；`git diff --check` 通过。独立复核的统计覆盖提示与语言缺失问题均已修复，没有待处理的阻塞项。

最终测试命令：

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO \
  -only-testing:QuotioTests/PiCompatibilityTests \
  -only-testing:QuotioTests/ClientUsageSQLiteMigrationTests \
  -only-testing:QuotioTests/CallAnalyticsLifecycleTests \
  -resultBundlePath /tmp/quotio-pi-compat-tests-20260907-final.xcresult test
```

另用独立 Swift 命令行验证程序链接实际构建的 Quotio 模块，只读本机 Pi 日志，索引写入临时 SQLite 并在完成后删除。现场结果：

| 项目 | 结果 |
| --- | --- |
| 已读取文件 | 28 |
| 用量记录 | 231 |
| Token 合计 | 29,624,704 |
| 工具调用 | 477 |
| 用量读取错误 | 无 |
| 调用读取错误 | 无 |
| 临时 SQLite 重开结果 | 与首次读取一致，无错误 |

以上是验证时正式会话范围内的数值，不包含仅存在于第三方扩展转录的记录。验证未安装或重新配置 Pi，未删除、重写用户会话及真实统计数据库。独立评审复核了安装、解析、错误恢复、统计范围提示和语言覆盖。

## 对照来源

- [Pi 官方安装文档](https://pi.dev/docs/latest)：npm、官方脚本及其他 JS 包管理器。
- [Homebrew pi-coding-agent](https://formulae.brew.sh/formula/pi-coding-agent)：`pi` 入口及 Node 依赖。
- [Pi coding-agent 官方源码](https://github.com/earendil-works/pi/tree/main/packages/coding-agent)：会话、配置目录及包命名空间。
- 本机 `pi-subagents/src/shared/child-transcript.ts`、`src/runs/shared/pi-args.ts`、`src/extension/index.ts`：辅助记录结构及会话保存策略。
