import Testing
@testable import LangCore

@Suite("U-LANG language codes")
struct LanguageCodeTests {
    @Test("U-LANG-1 canonical output uses the minimal identifier",
          arguments: [
            ("zh-Hans", "zh"), ("zh-Hant", "zh-TW"), ("en-US", "en"), ("pt-BR", "pt"),
            ("pt-PT", "pt-PT"), ("en_US", "en"), ("ko", "ko"), ("ja", "ja"),
          ])
    func canonical(input: String, expected: String) throws {
        #expect(try LanguageCode.normalize(input) == expected)
        #expect(LanguageCode.canonical(input) == expected)
    }

    @Test("U-LANG-2 alias zt maps to zh-Hant -> zh-TW")
    func alias() throws {
        #expect(try LanguageCode.normalize("zt") == "zh-TW")
    }

    @Test("U-LANG-3 syntax errors are unsupported_language", arguments: ["k", "ko!", "", " ", "a-", "123", "en-U"])
    func syntax(input: String) {
        #expect(throws: LangError.self) { try LanguageCode.normalize(input) }
        do { _ = try LanguageCode.normalize(input) } catch let e as LangError {
            #expect(e.code == .unsupportedLanguage)
        } catch {}
    }
}
