import Foundation
import NaturalLanguage
@preconcurrency import Translation
import LangCore

/// Maps Translation framework errors onto the error table.
public func mapTranslationError(_ error: Error) -> ErrorCode {
    switch error {
    case TranslationError.unsupportedSourceLanguage,
         TranslationError.unsupportedTargetLanguage,
         TranslationError.unsupportedLanguagePairing:
        return .unsupportedLanguage
    case TranslationError.unableToIdentifyLanguage:
        return .unableToDetect
    case TranslationError.nothingToTranslate:
        return .invalidRequest
    case TranslationError.alreadyCancelled:
        return .timeout
    case TranslationError.notInstalled:
        return .notInstalled
    case TranslationError.internalError:
        return .internalError
    case is CancellationError:
        return .timeout
    default:
        return .internalError
    }
}

/// Real engine. `TranslationSession` instances are confined to this actor and cached per
/// (source, target, strategy); an error or timeout evicts the key (no retry).
///
/// Never call this outside a GUI login session: the Translation framework blocks forever there.
public actor AppleTranslationEngine: TranslationEngine {
    private struct Key: Hashable {
        let source: String
        let target: String
        let strategy: StrategyOption?
    }

    private var sessions: [Key: TranslationSession] = [:]
    private let timeoutSeconds: Double
    private let strategyAPI: Bool

    /// `strategyAPI` defaults to the real `#available(macOS 26.4)`; tests may inject `false`.
    public init(timeoutSeconds: Double = 30, strategyAPI: Bool = AppleTranslationEngine.strategyAPIAvailable) {
        self.timeoutSeconds = timeoutSeconds
        self.strategyAPI = strategyAPI
    }

    public nonisolated func validateStrategy(_ strategy: StrategyOption?) throws(EngineError) {
        try Self.validateStrategy(strategy, apiAvailable: strategyAPI)
    }

    /// An explicit strategy needs the API (macOS 26.4+); an omitted one never does.
    public static func validateStrategy(_ strategy: StrategyOption?, apiAvailable: Bool) throws(EngineError) {
        if strategy != nil, !apiAvailable {
            throw EngineError(.invalidRequest, "strategy requires macOS 26.4 or later",
                              fix: "omit --strategy (HTTP: omit \"strategy\"); maclang then uses the system default", field: "strategy", received: strategy?.rawValue)
        }
    }

    /// Fixed, input-free messages (server logs and responses must never carry request text).
    nonisolated static func message(for code: ErrorCode) -> String {
        switch code {
        case .unsupportedLanguage: return "unsupported language or language pairing"
        case .notInstalled: return "language pack or strategy not installed; install it in System Settings > General > Language & Region > Translation Languages"
        case .unableToDetect: return "could not detect the source language"
        case .invalidRequest: return "nothing to translate"
        case .timeout: return "translation timed out"
        default: return "translation failed"
        }
    }

    public func translate(_ text: String, from: String?, to: String, strategy: StrategyOption?) async throws(EngineError) -> TranslationOutput {
        try Self.validateStrategy(strategy, apiAvailable: strategyAPI)
        var detected: Detection?
        let source: String
        if let from {
            source = from
        } else {
            let d = NLDetector.detectOrFallback(text)
            detected = d
            source = d.language
        }

        let key = Key(source: source, target: to, strategy: strategy)
        let session = session(for: key)
        let seconds = timeoutSeconds
        do {
            let response = try await withTimeout(seconds: seconds, onTimeout: { await self.evict(key) }) {
                do { return try await session.translate(text) }
                catch let e as EngineError { throw e }
                catch {
                    let code = mapTranslationError(error)
                    let pairRelated = code == .unsupportedLanguage || code == .notInstalled
                    throw EngineError(code, Self.message(for: code), field: pairRelated ? "language pair" : nil,
                                      received: pairRelated ? "\(source)→\(to)" : nil)
                }
            }
            return TranslationOutput(text: response.targetText, detected: detected)
        } catch {
            evict(key)
            if error.code == .internalError {
                throw EngineError(.internalError, Self.message(for: .internalError))
            }
            throw error
        }
    }

    public func languages(strategy: StrategyOption?, from: String?) async throws(EngineError) -> [LanguageEntry] {
        try Self.validateStrategy(strategy, apiAvailable: strategyAPI)
        return try await AppleAvailability.compute(strategy: strategy, from: from)
    }

    // MARK: - sessions

    public nonisolated static var strategyAPIAvailable: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    private func session(for key: Key) -> TranslationSession {
        if let cached = sessions[key] { return cached }
        let source = Locale.Language(identifier: key.source)
        let target = Locale.Language(identifier: key.target)
        let created: TranslationSession
        if #available(macOS 26.4, *) {
            let strategy = resolveStrategy(requested: key.strategy)
            created = TranslationSession(installedSource: source, target: target,
                                         preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
        } else {
            created = TranslationSession(installedSource: source, target: target)
        }
        sessions[key] = created
        return created
    }

    private func evict(_ key: Key) {
        sessions.removeValue(forKey: key)?.cancel()
    }
}

/// An omitted strategy resolves to `.highFidelity` explicitly. The framework's implicit default
/// depends on the calling context (inside the server it resolved to a strategy without packs),
/// so it is never relied on when the strategy API exists (macOS 26.4+).
public func resolveStrategy(requested: StrategyOption?) -> StrategyOption {
    requested ?? .highFidelity
}

/// Availability queries against `LanguageAvailability` (47 languages -> ~2200 pair lookups).
public enum AppleAvailability {
    public static func compute(strategy: StrategyOption?, from: String?) async throws(EngineError) -> [LanguageEntry] {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            let resolved = resolveStrategy(requested: strategy)
            availability = LanguageAvailability(preferredStrategy: resolved == .highFidelity ? .highFidelity : .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let supported = await availability.supportedLanguages

        var variants: [String: [Locale.Language]] = [:]
        for language in supported {
            variants[LanguageCode.canonical(language.minimalIdentifier), default: []].append(language)
        }
        var sources = variants.keys.sorted()
        if let from {
            guard variants[from] != nil else {
                throw EngineError(.unsupportedLanguage, "unsupported source language: \(from)", field: "from", received: from)
            }
            sources = [from]
        }

        var entries: [LanguageEntry] = []
        for code in sources {
            var targets = Set<String>()
            for source in variants[code] ?? [] {
                for target in supported {
                    if Task.isCancelled { throw EngineError(.timeout, "language lookup cancelled") }
                    let targetCode = LanguageCode.canonical(target.minimalIdentifier)
                    guard targetCode != code, !targets.contains(targetCode) else { continue }
                    if await availability.status(from: source, to: target) == .installed {
                        targets.insert(targetCode)
                    }
                }
            }
            entries.append(LanguageEntry(code: code, name: LanguageNames.name(for: code), targets: targets.sorted()))
        }
        return entries
    }
}

extension AppleAvailability {
    /// Status of the en -> ko pair for `doctor` (only call inside a GUI login session).
    public static func englishToKoreanStatus() async -> String {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .highFidelity)  // = resolveStrategy(requested: nil)
        } else {
            availability = LanguageAvailability()
        }
        switch await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko")) {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }
}
