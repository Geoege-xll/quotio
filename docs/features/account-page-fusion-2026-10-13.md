# 账号额度与管理深度融合

## 页面与兼容规则

- 侧栏统一为“账号”，页面内没有额度／管理 Tab。旧 `NavigationPage.quota` 归一到 `.providers`，旧 `QuotaScreen` 保留为兼容入口。
- 顶部使用项目标准 `QuotioCapsuleSegmentedControl` 筛选全部或某个服务商，保留账号数量与最低剩余额度信息。
- 同一账号的身份、来源、管理操作、套餐、更新时间、完整额度和专属工具直接放在同一个服务商卡片中。套餐紧跟名称；预热、刷新与删除位于同一行，不重复展示第二行工具栏。
- 筛选只影响普通账号列表。自定义提供商仍在同页；按用户追加要求移除顶部快速添加摘要，添加账号继续从工具栏进入，原来的授权与配置流程仍由原宿主持有。
- 额度样式继续使用原来的偏好键，保留卡片、环形、最低额度条和已用／剩余切换，隐私及菜单栏偏好继续生效。

## 原功能保留矩阵

| 原功能 | 融合后的实现入口 |
| --- | --- |
| 添加账号、OAuth 授权、手动授权码、Vertex 服务账号导入、认证文件上传 | `ProvidersScreen` 原 toolbar、授权弹窗和导入处理 |
| IDE 扫描、自定义提供商添加及配置同步 | 原添加弹窗／扫描弹窗及 `CustomProviderSheet` |
| 编辑、删除确认、启停、认证文件导出、菜单栏固定及数量／低额度提示 | 同卡 `AccountRow` 的按钮与右键菜单 |
| 全量刷新、服务商刷新、单账号刷新及加载／阻塞状态 | 顶部刷新按钮、服务商刷新菜单、同卡 `AccountQuotaContent` |
| 套餐、所有模型与额度桶、重置时间、独立金额／数量、错误、未知额度、缓存更新时间 | 复用原额度内容和数值规则，不将完整模型数据改成简化摘要 |
| Antigravity 当前 IDE 账号、切换、预热、分组额度和全部模型详情 | 身份行保留 IDE 操作，额度区域保留预热与详情弹窗 |
| Claude 禁用额度后的重新授权／打开授权链接 | 原额度组件内授权状态与按钮 |
| Kiro Token 到期时间 | 同卡额度元信息 |
| GLM 多密钥独立额度及配置编辑／删除 | 连接 UUID 保持管理身份，`quotaAccountKeys` 在一个连接下关联所有密钥额度 |
| Warp、ClinePass 及监控 API Key 专属配置 | 原专属连接弹窗与存储处理 |
| 泛用自定义提供商编辑、删除、启停 | 同页自定义提供商区域 |

## 身份与权限

`AccountPageData` 只拼装传入快照，不读写凭据，也不启动网络请求。

- 代理运行时使用 CPA 认证文件及原有权限；监控模式使用监控账号；代理停止时使用直读认证文件。
- 刷新与额度关联使用现有规范键，不以邮箱猜测。同邮箱 CPA 凭据、Codex Plus／Team 保持独立。
- 额度键已无歧义匹配账号时不另建缓存条目。非 Codex 旧直读文件如果共享邮箱键，保留各自管理入口，但将无法判定归属的额度单独显示为只读缓存，不能在多个凭据下复制同一份额度。
- 未匹配的额度继续显示为“额度缓存”，不暗示认证有效，不赋予编辑、删除凭据或启停权限。自动来源也先排除已被当前连接目录覆盖的规范键。
- 监控或直读账号不携带上一次代理会话的错误；认证文件详情仅按本次代理账号 ID 与规范键双重匹配。
- GLM 配置的全部 API Key 以稳定 UUID 键关联，额度请求不按配置名称默认选第一个密钥。配置级编辑／删除行为保持原语义，行内刷新菜单可分别刷新每个 Key。子标题遵守隐私掩码，安全序号独立展示。

## 验证

- 新增 `AccountPageFusionTests`：账号／缓存归并、同邮箱多凭据、Codex 套餐、监控状态与权限、停服状态隔离、IDE 删除语义、GLM 多密钥、专属连接存储身份及旧导航兼容。
- 新增 `AccountPageRenderingTests`：使用真实 `NSHostingView` 渲染生产筛选和账号组，检查浅／深主题、三种额度样式、服务商筛选、1000／660 点宽度及单份纵向滚动容器。
- 相关既有回归涵盖额度未知值、三种展示口径、菜单栏额度对、Antigravity、GLM、CPA 响应及 IDE 刷新。
- 原生渲染夹具关闭 ViewModel 后台服务，只使用内存账号与额度；没有启动真实代理或在线授权。

### 最终结果

- `QuotioPlus` Debug 构建成功；相关 16 类回归共 **186 项通过，0 失败、0 跳过、0 运行时警告**。
- 报告：`/tmp/quotio-account-fusion-complete-tests.xcresult`；构建及测试日志：`/tmp/quotio-account-fusion-complete-tests.log`。
- 原生截图目录：`/tmp/quotio-account-fusion-visuals`，覆盖浅／深主题、三种样式、普通账号／GLM 多 Key 筛选及 1000／660 点宽度。
- `light-card-compact.png` 确认普通套餐紧跟账号名、IDE 按钮完整显示、预热／刷新与删除同一行；`light-card-glm.png` 确认不同 Key 的 Lite／Pro 套餐及独立安全序号。
- 身份边界回归包含非 Codex 直读同邮箱碰撞、Grok 自动来源重计、多 Key 隐私标题以及首 Key 无额度时保留第二 Key 套餐。

## CPA 启动后磁盘／运行记录重复修复

官方参考：[EasyCLIProxyAPI 的认证文件去重](https://github.com/router-for-me/EasyCLIProxyAPI/blob/10b4a4561464f30554bbcc475031b6ec7739b008/src/services/authFiles.ts)，以及[账号管理列表与额度缓存关联](https://github.com/router-for-me/EasyCLIProxyAPI/blob/10b4a4561464f30554bbcc475031b6ec7739b008/src/pages/AuthFileManagementPage.tsx)。检查版本为 `10b4a4561464f30554bbcc475031b6ec7739b008`。

上一轮只在运行模式间选择目录，漏掉了两个不同层级的重复：CPA 响应可同时包含同一文件的磁盘元数据和运行期记录；同一凭据的本地邮箱／文件名额度键，又可能与 CPA 当前索引键并存。未匹配缓存被当成额外账号，造成重复条目和计数。

新增 `AuthFileIdentity` 后采用以下规则：

1. 先按提供商和文件名分组。仅有一个有效索引时吸收无索引记录，保留运行状态及路由索引，并补充磁盘邮箱、路径与套餐元数据。存在多个有效索引时保持独立。
2. 缺失 `id` 的不同索引或提供商不能共享文件名作为内存查找 ID；生成稳定唯一 ID，实际管理请求仍使用原 `name`／`authIndex`，不回写凭据。
3. 无歧义的邮箱、文件名和旧无索引快照迁入当前规范槽位。已有 CPA 精确快照优先；只有旧快照时选最新值，不能相加或平均。仍有归属歧义的条目保留只读缓存。
4. 停服时只有文件路径兼容、索引无冲突、直读键唯一的记录才迁回本地键。不同目录或不同有效索引的快照、套餐和固定项保持独立。
5. 目录发布、单项／批量刷新收尾同步归一额度、套餐和菜单栏固定项。固定项保序且幂等，避免别名移除后已固定账号变成空白。

新增 `AuthFileIdentityTests` 覆盖上述混合响应、无 ID 冲突、数字索引零、明确不同目录、启停往返及固定项迁移。原生渲染增加 `testNativeCPAStartShowsOneCredentialWithAttachedLegacyQuota`，截图为 `/tmp/quotio-account-fusion-visuals/cpa-disk-runtime-one-card.png`。这些验证只使用离线响应和内存快照。

本次去重修复的 Debug 构建及 **208 项相关回归全部通过，0 失败、0 跳过、0 运行时警告**。报告为 `/tmp/quotio-account-identity-regression.xcresult`，日志为 `/tmp/quotio-account-identity-regression.log`；构建使用独立缓存 `/tmp/quotio-account-identity-derived`。只读代码审查确认本次限定范围没有未解决问题。
