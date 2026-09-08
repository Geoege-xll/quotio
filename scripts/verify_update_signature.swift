import CryptoKit
import Foundation

// 此工具只接收公开验证材料，不接触发布私钥。只有归档签名能被包内公钥验证时才允许生成 appcast。
// 单独放置便于对匹配与不匹配的密钥做离线验证，不需要打包或上传真实应用。
do {
    guard CommandLine.arguments.count == 4,
          let key = Data(base64Encoded: CommandLine.arguments[2]),
          let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: archive) else { throw CocoaError(.fileReadCorruptFile) }
    print("Sparkle archive signature matches the bundled public key.")
} catch {
    fputs("error: archive signature does not match the application's Sparkle public key\n", stderr)
    exit(1)
}
