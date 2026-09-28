//
//  KeychainLegacyInteraction.h
//  Quotio - 传统 macOS 登录钥匙串兼容接口
//

#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <stdbool.h>

// 外部 CLI 凭据可能位于基于文件的登录钥匙串，其 ACL 授权弹窗不受 LAContext 控制。
// 这些函数只包裹已有的 SecItem 读写操作，不改变查询条件或凭据的存储位置。
OSStatus QuotioSecItemCopyMatchingWithoutInteraction(CFDictionaryRef _Nonnull query, CFTypeRef _Nullable * _Nullable result);
OSStatus QuotioSecItemUpdateWithoutInteraction(CFDictionaryRef _Nonnull query, CFDictionaryRef _Nonnull attributes);

// 仅供回归测试验证进程级交互标志在调用后恢复。
OSStatus QuotioGetLegacyKeychainInteractionAllowed(bool * _Nonnull allowed);
