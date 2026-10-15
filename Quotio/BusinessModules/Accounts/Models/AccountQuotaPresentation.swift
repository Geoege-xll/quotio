import SwiftUI

/// 账号融合页专用的额度展示快照，仅承载父页面已经整理好的展示输入。
/// 身份键沿用现有规范键，绝不按展示邮箱猜测匹配；本类型不读取配置、发起刷新或持有任务。
/// Color 是该业务页面的展示信息，因此放在 Accounts 模块，避免混入公共额度数据模型。
struct AccountQuotaPresentation {
    let key: String
    let email: String
    let status: String
    let statusColor: Color
    let authFile: AuthFile?
    let quotaData: ProviderQuotaData?
    let subscriptionInfo: SubscriptionInfo?
}
