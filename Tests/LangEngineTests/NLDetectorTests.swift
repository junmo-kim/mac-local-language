import Testing
import LangCore
@testable import LangEngine

@Suite("E-NL NaturalLanguage detector (safe outside GUI sessions)")
struct NLDetectorTests {
    @Test("E-NL-1 top language with canonical codes", arguments: [
        ("The quick brown fox jumps over the lazy dog.", "en"),
        ("今日はとても良い天気ですね。散歩に行きましょう。", "ja"),
        ("안녕하세요, 오늘 날씨가 정말 좋네요.", "ko"),
        ("我今天去商店买了一些苹果和香蕉，天气很好。", "zh"),
        ("我今天去商店買了一些蘋果和香蕉，天氣很好。", "zh-TW"),
        ("Bonjour tout le monde", "fr"),
    ])
    func top(text: String, expected: String) {
        let result = NLDetector.detect(text, max: 3)
        #expect(result.first?.language == expected)
        #expect(result.count <= 3)
        #expect(result == result.sorted { $0.probability > $1.probability })
        #expect(result.allSatisfy { $0.probability > 0 && $0.probability <= 1 })
    }

    @Test("E-NL-2 nothing detectable yields an empty array", arguments: ["   ", "12345", ""])
    func none(text: String) {
        #expect(NLDetector.detect(text, max: 3).isEmpty)
    }

    @Test("max limits the result count")
    func limit() {
        #expect(NLDetector.detect("Bonjour tout le monde", max: 1).count == 1)
    }

    @Test("E-NL-3 detectOrFallback never fails: undetectable text is en with confidence 0")
    func fallback() {
        #expect(NLDetector.detectOrFallback("12345") == Detection(language: "en", probability: 0))
        #expect(NLDetector.detectOrFallback("   ") == Detection(language: "en", probability: 0))
        #expect(NLDetector.detectOrFallback("Bonjour tout le monde").language == "fr")
        #expect(NLDetector.detectOrFallback("12345").confidence == 0)
    }
}
