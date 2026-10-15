//
//  Quotio-Bridging-Header.h
//  只向 Swift 暴露传统登录钥匙串的最小兼容接口。
//

// 路径相对于当前桥接头所在的 App/Configuration；与构建命令的工作目录无关。
// Objective-C 实现与声明共同归入安全基础设施，原有 Swift 可见接口保持不变。
#import "../../Infrastructure/Security/KeychainLegacyInteraction.h"
