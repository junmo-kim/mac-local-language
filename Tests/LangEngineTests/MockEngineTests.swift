import Testing
import Foundation
import LangCore
@testable import LangEngine

@Suite("E-MOCK mock engine")
struct MockEngineTests {
    @Test("E-MOCK-1 translate output format with explicit source")
    func translate() async throws {
        let out = try await MockEngine().translate("hello", from: "en", to: "ko", strategy: nil)
        #expect(out.text == "[mock en→ko] hello")
        #expect(out.detected == nil)
    }

    // With from=auto the mock labels the output with the NaturalLanguage-detected code and reports it.
    // When nothing can be detected it behaves like the real engine (LibreTranslate parity): source
    // `en`, reported as detected with confidence 0.
    @Test("E-MOCK-1 auto source uses the detected code, or en with confidence 0 when none")
    func autoSource() async throws {
        let out = try await MockEngine().translate("Bonjour tout le monde", from: nil, to: "ko", strategy: nil)
        #expect(out.text == "[mock fr→ko] Bonjour tout le monde")
        #expect(out.detected?.language == "fr")
        let none = try await MockEngine().translate("12345", from: nil, to: "ko", strategy: nil)
        #expect(none.text == "[mock en→ko] 12345")
        #expect(none.detected == Detection(language: "en", probability: 0))
    }

    @Test("E-MOCK-1 target xx is unsupported_language")
    func unsupported() async {
        do {
            _ = try await MockEngine().translate("hello", from: "en", to: "xx", strategy: nil)
            Issue.record("expected failure")
        } catch {
            #expect(error.code == .unsupportedLanguage)
        }
    }

    @Test("E-MOCK-1 languages catalog: en->ja,ko and ko->en, sorted by code")
    func languages() async throws {
        let all = try await MockEngine().languages(strategy: nil, from: nil)
        #expect(all == [LanguageEntry(code: "en", name: "English", targets: ["ja", "ko"]),
                        LanguageEntry(code: "ko", name: "Korean", targets: ["en"])])
        let ko = try await MockEngine().languages(strategy: .highFidelity, from: "ko")
        #expect(ko == [LanguageEntry(code: "ko", name: "Korean", targets: ["en"])])
        do {
            _ = try await MockEngine().languages(strategy: nil, from: "fr")
            Issue.record("expected failure")
        } catch {
            #expect(error.code == .unsupportedLanguage)
        }
    }

    @Test("E-MOCK-1 delay is honored and cancellation maps to timeout")
    func delay() async throws {
        let engine = MockEngine(delayMs: 200)
        let start = ContinuousClock.now
        _ = try await engine.translate("x", from: "en", to: "ko", strategy: nil)
        #expect(ContinuousClock.now - start >= .milliseconds(180))

        let slow = MockEngine(delayMs: 5000)
        let task = Task { () -> ErrorCode? in
            do { _ = try await slow.translate("x", from: "en", to: "ko", strategy: nil); return nil }
            catch let e as LangError { return e.code } catch { return nil }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == .timeout)
    }

    @Test("engine selection from env")
    func factory() {
        #expect(EngineFactory.make(env: ["MACLANG_ENGINE": "mock", "MACLANG_MOCK_DELAY_MS": "7"]) is MockEngine)
    }
}
