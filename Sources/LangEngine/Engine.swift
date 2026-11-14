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
    /// Rejects a strategy this engine cannot honor; cheap and side-effect free, so callers can run it
    /// before consulting any cache.
    func validateStrategy(_ strategy: StrategyOption?) throws(EngineError)
}

extension TranslationEngine {
    public func validateStrategy(_ strategy: StrategyOption?) throws(EngineError) {}
}

public enum LanguageNames {
    /// English display name of a canonical language code.
    public static func name(for code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}

public enum EngineFactory {
    /// `MACLANG_ENGINE=mock` -> `MockEngine`; otherwise the Apple engine. Constructing the Apple
    /// engine is cheap and touches no framework until a call is made.
    public static func make(env: [String: String], timeoutSeconds: Double = 30) -> any TranslationEngine {
        let runtime = RuntimeEnv(env: env)
        switch runtime.engine {
        case .mock: return MockEngine(delayMs: runtime.mockDelayMs)
        case .apple: return AppleTranslationEngine(timeoutSeconds: timeoutSeconds)
        }
    }
}
