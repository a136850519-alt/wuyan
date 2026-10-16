import Foundation
import Testing
@testable import Wuyan

@Suite("macOS optimization regression")
struct MacOSOptimizationTests {
    @Test("year themes persist by stable identifier and recover unknown values")
    func yearThemePersistence() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            #expect(AppSettings.yearTheme(2026) == YearTheme.default.rawValue)
            AppSettings.setYearTheme(YearTheme.rose.rawValue, for: 2026)
            AppSettings.setYearTheme(YearTheme.mist.rawValue, for: 2025)
            #expect(AppSettings.yearTheme(2026) == "rose")
            #expect(AppSettings.yearTheme(2025) == "mist")
            AppSettings.setYearTheme("unknown-value", for: 2024)
            #expect(AppSettings.yearTheme(2024) == YearTheme.default.rawValue)
        }
    }

    @Test("AI endpoint validation rejects incomplete or unsupported addresses")
    func endpointValidation() {
        #expect((try? ProviderFactory.validateHTTPURL("localhost:11434", service: "Ollama")) == nil)
        #expect((try? ProviderFactory.validateHTTPURL("ftp://example.com", service: "Ollama")) == nil)
        #expect((try? ProviderFactory.validateHTTPURL("http://localhost:11434", service: "Ollama")) != nil)
    }

    @Test("missing API key errors identify the service")
    func missingAPIKeyMessage() {
        #expect(AIError.missingAPIKey(service: "Claude").localizedDescription.contains("Claude API Key"))
        #expect(AIError.authenticationFailed(service: "智谱").localizedDescription.contains("身份验证失败"))
    }

    @Test("AI service errors keep status classification even when a provider returns JSON")
    func providerErrorClassification() {
        #expect(AIError.rateLimited(service: "Claude").localizedDescription.contains("请求过于频繁"))
        #expect(AIError.permissionDenied(service: "Claude").localizedDescription.contains("无权使用"))
    }
}
