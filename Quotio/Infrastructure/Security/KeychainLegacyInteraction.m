//
//  KeychainLegacyInteraction.m
//  Quotio - 传统 macOS 登录钥匙串兼容接口
//

#import "KeychainLegacyInteraction.h"

// Apple 已弃用 SecKeychain，但外部 CLI 的旧登录钥匙串仍通过 ACL 决定是否弹框。
// LAContext.interactionNotAllowed 只处理现代认证流程，不能替代这一进程级开关。
// 将弃用诊断局限在这段必要的兼容实现中，避免掩盖其他文件的迁移警告。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static OSStatus QuotioPerformWithoutKeychainInteraction(OSStatus (^operation)(void)) {
    Boolean previous = true;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&previous);
    if (status != errSecSuccess) {
        return status;
    }

    status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) {
        return status;
    }

    // 即使 SecItem 操作失败，也先恢复调用前的交互状态；恢复失败时向上报告错误。
    OSStatus operationStatus = operation();
    OSStatus restoreStatus = SecKeychainSetUserInteractionAllowed(previous);
    return restoreStatus == errSecSuccess ? operationStatus : restoreStatus;
}

OSStatus QuotioSecItemCopyMatchingWithoutInteraction(CFDictionaryRef query, CFTypeRef *result) {
    return QuotioPerformWithoutKeychainInteraction(^OSStatus {
        return SecItemCopyMatching(query, result);
    });
}

OSStatus QuotioSecItemUpdateWithoutInteraction(CFDictionaryRef query, CFDictionaryRef attributes) {
    return QuotioPerformWithoutKeychainInteraction(^OSStatus {
        return SecItemUpdate(query, attributes);
    });
}

OSStatus QuotioGetLegacyKeychainInteractionAllowed(bool *allowed) {
    if (allowed == NULL) {
        return errSecParam;
    }
    Boolean current = true;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&current);
    if (status == errSecSuccess) {
        *allowed = current;
    }
    return status;
}

#pragma clang diagnostic pop
