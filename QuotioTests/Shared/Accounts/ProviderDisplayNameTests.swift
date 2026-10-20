import XCTest
@testable import QuotioPlus

/// 服务商展示名归一规则：协议家族规范名、第三方品牌识别与兜底大写。
final class ProviderDisplayNameTests: XCTestCase {

    // MARK: - 已知品牌与协议家族的规范大小写

    func testNormalizeAppliesCanonicalBrandCasing() {
        XCTAssertEqual(ProviderDisplayName.normalize("anthropic"), "Anthropic")
        XCTAssertEqual(ProviderDisplayName.normalize("openai"), "OpenAI")
        XCTAssertEqual(ProviderDisplayName.normalize("google"), "Google")
        XCTAssertEqual(ProviderDisplayName.normalize("github-copilot"), "GitHub Copilot")
        XCTAssertEqual(ProviderDisplayName.normalize("openrouter"), "OpenRouter")
        // 已是规范名的输入保持稳定，不重复变形
        XCTAssertEqual(ProviderDisplayName.normalize("GLM"), "GLM")
        XCTAssertEqual(ProviderDisplayName.normalize("DeepSeek"), "DeepSeek")
    }

    func testNormalizeMapsOpenAICompatibilityToLocalizedPhrase() {
        // 协议家族不是品牌：中文界面显示“OpenAI 兼容”，其他语言回退英文目录。
        let value = ProviderDisplayName.normalize("openai-compatibility")
        XCTAssertTrue(["OpenAI 兼容", "OpenAI 相容", "OpenAI Compatible", "Compatible OpenAI",
                       "Tương thích OpenAI"].contains(value))
    }

    func testNormalizeCapitalizesUnknownEnglishIdentifiers() {
        XCTAssertEqual(ProviderDisplayName.normalize("siliconflow"), "Siliconflow")
        XCTAssertEqual(ProviderDisplayName.normalize("my-proxy-lab"), "My Proxy Lab")
        XCTAssertEqual(ProviderDisplayName.normalize("custom_upstream"), "Custom Upstream")
        XCTAssertEqual(ProviderDisplayName.normalize("  padded name  "), "Padded Name")
    }

    // MARK: - 模型 ID 品牌特征（与可用模型目录同一口径）

    func testBrandHintResolvesThirdPartyModelFamilies() {
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "glm-5.3"), "GLM")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "glm/glm-5.3"), "GLM")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "deepseek-chat"), "DeepSeek")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "moonshot-v1-8k"), "Moonshot")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "kimi-k2"), "Moonshot")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "abab6.5s-chat"), "MiniMax")
        XCTAssertEqual(ProviderDisplayName.brandHint(in: "qwen-max"), "Qwen")
        // 原生模型不含第三方特征，保持 nil 以便回退协议家族
        XCTAssertNil(ProviderDisplayName.brandHint(in: "claude-sonnet-4-5"))
        XCTAssertNil(ProviderDisplayName.brandHint(in: "gpt-5.2"))
    }

    // MARK: - 用量事件侧的上游品牌校准

    func testEventProviderNameResolvesCrossProtocolUpstreamBrands() {
        // 用户实际场景：GLM 挂在 Anthropic 协议族、自定义服务商挂在 openai-compatibility
        XCTAssertEqual(ProviderDisplayName.eventProviderName(provider: "claude", model: "glm-5.3"), "GLM")
        XCTAssertEqual(ProviderDisplayName.eventProviderName(provider: "openai-compatibility", model: "glm-4.6"), "GLM")
        XCTAssertEqual(ProviderDisplayName.eventProviderName(provider: "openai-compatibility", model: "deepseek-chat"), "DeepSeek")
    }

    func testEventProviderNameFallsBackToCanonicalFamilyName() {
        // 原生模型回退协议家族；未知模型沿 openai-compatibility 显示本地化兼容短语
        XCTAssertEqual(ProviderDisplayName.eventProviderName(provider: "claude", model: "claude-sonnet-4-5"), "Claude")
        XCTAssertEqual(ProviderDisplayName.eventProviderName(provider: "openai", model: "gpt-5.2"), "OpenAI")
        let compat = ProviderDisplayName.eventProviderName(provider: "openai-compatibility", model: nil)
        XCTAssertTrue(compat.contains("OpenAI"))
    }
}
