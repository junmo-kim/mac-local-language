import Foundation
import LangCore

/// Engine failures carry a table code, same type as LangCore's `LangError`.
public typealias EngineError = LangError

public struct TranslationOutput: Sendable, Equatable {
    public var text: String
    /// Present only when the source was auto-detected.
    public var detected: Detection?
    public init(text: String, detected: Detection? = nil) {
        self.text = text
        self.detected = detected
    }
}

public protocol TranslationEngine: Sendable {
    /// `from == nil` means auto-detect.
    func translate(_ text: String, from: String?, to: String, strategy: StrategyOption?) async throws(EngineError) -> TranslationOutput
    /// `from` limits the result to that language's row.
    func languages(strategy: StrategyOption?, from: String?) async throws(EngineError) -> [LanguageEntry]
}

public enum LanguageNames {
    /// English display name of a canonical language code.
    public static func name(for code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}

public enum EngineFactory {
    /// `MACLANG_ENGINE=mock` -> `MockEngine`; otherwise the Apple engine (added in step 2.4).
    public static func make(env: [String: String]) -> any TranslationEngine {
        let runtime = RuntimeEnv(env: env)
        return MockEngine(delayMs: runtime.mockDelayMs)
    }
}
