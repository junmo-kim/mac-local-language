import Foundation
import LangCore

/// Deterministic engine for tests (`MACLANG_ENGINE=mock`). Never touches system frameworks.
public struct MockEngine: TranslationEngine {
    let delayMs: Int

    public init(delayMs: Int = 0) { self.delayMs = delayMs }

    static let pairs: [String: [String]] = ["en": ["ja", "ko"], "ko": ["en"]]

    public func translate(_ text: String, from: String?, to: String, strategy: StrategyOption?) async throws(EngineError) -> TranslationOutput {
        try await pause()
        guard to != "xx" else { throw EngineError(.unsupportedLanguage, "unsupported target language: \(to)") }
        return TranslationOutput(text: "[mock \(from ?? "auto")→\(to)] \(text)")
    }

    public func languages(strategy: StrategyOption?, from: String?) async throws(EngineError) -> [LanguageEntry] {
        try await pause()
        let codes: [String]
        if let from {
            guard Self.pairs[from] != nil else { throw EngineError(.unsupportedLanguage, "unsupported source language: \(from)") }
            codes = [from]
        } else {
            codes = Self.pairs.keys.sorted()
        }
        return codes.map { LanguageEntry(code: $0, name: LanguageNames.name(for: $0), targets: Self.pairs[$0]!) }
    }

    private func pause() async throws(EngineError) {
        guard delayMs > 0 else { return }
        do { try await Task.sleep(for: .milliseconds(delayMs)) }
        catch { throw EngineError(.timeout, "engine call cancelled") }
    }
}
