import XCTest
@testable import QuotioPlus

/// 唯一调整调用方式的空白辅助经真实账号工厂验证，确保分文件后仍保留显示回退与原稳定身份。
/// 所有条目均为内存值，不读取账号文件、环境变量、钥匙串或网络。
final class MonitorAccountNormalizationTests: XCTestCase {
    func testDisplayNameFallbackDoesNotChangeNormalizedAccountIdentity() {
        let expected = MonitorAccount.make(provider: .claude, accountKey: "Work@example.com", source: .nativeCredential)
        let displayNames: [String?] = [nil, "", " \t\r\n", "  Work Label \n"]
        for displayName in displayNames {
            let account = MonitorAccount.make(
                provider: .claude, accountKey: " \tWork@example.com\n", displayName: displayName,
                source: .nativeCredential
            )
            XCTAssertEqual(account.id, expected.id)
            XCTAssertEqual(account.accountKey, "Work@example.com")
            XCTAssertEqual(account.displayName, displayName == "  Work Label \n" ? "Work Label" : "Work@example.com")
        }
    }

    func testLegacyDisplayFallsBackFromEmailToLoginAndFilename() {
        let samples: [(email: String?, login: String?, expected: String)] = [
            (" work@example.com \n", "other", "work@example.com"),
            (nil, " Login Label \n", "Login Label"),
            ("", " \t\n", "fixture.json"),
            (nil, nil, "fixture.json")
        ]
        for sample in samples {
            let file = DirectAuthFile(
                id: "fixture", provider: .claude, email: sample.email, login: sample.login,
                expired: nil, accountType: nil, filePath: "/fixture/fixture.json", source: .cliProxyApi,
                filename: "fixture.json"
            )
            XCTAssertEqual(MonitorAccount.makeLegacy(file).displayName, sample.expected)
        }
    }
}
