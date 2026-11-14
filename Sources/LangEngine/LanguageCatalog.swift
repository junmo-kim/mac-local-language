import Foundation
import LangCore

/// Caches language-pair catalogs per strategy for one hour and shares in-flight computations.
/// A request with `from` computes only that row unless the full catalog is cached or in flight.
public actor LanguageCatalog {
    public typealias Compute = @Sendable (StrategyOption?, String?) async throws -> [LanguageEntry]

    private struct Key: Hashable {
        /// Resolved (an omitted strategy and explicit high fidelity are the same entry).
        let strategy: StrategyOption
        let from: String?
    }
    private struct Cached {
        let entries: [LanguageEntry]
        let expires: Date
    }

    private let compute: Compute
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let computeTimeout: Double
    private let validate: (@Sendable (StrategyOption?) throws(EngineError) -> Void)?
    private var cache: [Key: Cached] = [:]
    private var inflight: [Key: Task<[LanguageEntry], Error>] = [:]

    public init(ttl: TimeInterval = 3600, computeTimeout: Double = 120, now: @escaping @Sendable () -> Date = { Date() },
                validate: (@Sendable (StrategyOption?) throws(EngineError) -> Void)? = nil, compute: @escaping Compute) {
        self.ttl = ttl
        self.computeTimeout = computeTimeout
        self.validate = validate
        self.now = now
        self.compute = compute
    }

    /// Start computing the default-strategy catalog in the background.
    public func warmUp() {
        let key = Key(strategy: resolveStrategy(requested: nil), from: nil)
        if cached(key) == nil, inflight[key] == nil { start(key, requested: nil) }
    }

    public func languages(strategy: StrategyOption?, from: String?) async throws(EngineError) -> [LanguageEntry] {
        // Before any cache lookup: an unsupported explicit strategy is an error whatever the cache holds.
        try validate?(strategy)
        let resolved = resolveStrategy(requested: strategy)
        let fullKey = Key(strategy: resolved, from: nil)
        if let from {
            let canonicalFrom = LanguageCode.canonical(from)
            // Prefer the full catalog when it is already there (or being computed).
            if cached(fullKey) != nil || inflight[fullKey] != nil {
                let all = try await resolve(fullKey, requested: strategy)
                return try Self.row(canonicalFrom, in: all)
            }
            return try await resolve(Key(strategy: resolved, from: canonicalFrom), requested: strategy)
        }
        return try await resolve(fullKey, requested: strategy)
    }

    // MARK: -

    private func cached(_ key: Key) -> [LanguageEntry]? {
        guard let hit = cache[key] else { return nil }
        if hit.expires <= now() {
            cache[key] = nil
            return nil
        }
        return hit.entries
    }

    /// `requested` is what the client asked for (nil when omitted). The cache is keyed by the resolved
    /// strategy, but the computation gets the original value: on macOS < 26.4 an omitted strategy must
    /// not become an explicit one (the strategy API does not exist there).
    private func start(_ key: Key, requested: StrategyOption?) {
        let compute = self.compute
        let timeout = computeTimeout
        // The task records its own outcome (cache or failure) before completing, so a caller
        // that awaits it can never observe a finished computation that is not yet cached.
        inflight[key] = Task<[LanguageEntry], Error> { [weak self] in
            let result: Result<[LanguageEntry], EngineError>
            do { result = .success(Self.normalize(try await withTimeout(seconds: timeout) { try await compute(requested, key.from) })) }
            catch let e as EngineError { result = .failure(e) }
            catch { result = .failure(EngineError(.internalError, "catalog computation failed")) }
            await self?.finish(key, result)
            return try result.get()
        }
    }

    private func finish(_ key: Key, _ result: Result<[LanguageEntry], EngineError>) {
        inflight[key] = nil
        if case .success(let entries) = result {
            cache[key] = Cached(entries: entries, expires: now().addingTimeInterval(ttl))
        }
    }

    private func resolve(_ key: Key, requested: StrategyOption?) async throws(EngineError) -> [LanguageEntry] {
        if let hit = cached(key) { return hit }
        if inflight[key] == nil { start(key, requested: requested) }
        guard let task = inflight[key] else {
            // finish() already ran between start and here only if the task completed instantly.
            if let hit = cached(key) { return hit }
            throw EngineError(.internalError, "catalog computation unavailable")
        }
        do { return try await task.value }
        catch let e as EngineError { throw e }
        catch { throw EngineError(.internalError, "catalog computation failed") }
    }

    private static func row(_ code: String, in all: [LanguageEntry]) throws(EngineError) -> [LanguageEntry] {
        guard let row = all.first(where: { $0.code == code }) else {
            throw EngineError(.unsupportedLanguage, "unsupported source language: \(code)", field: "from", received: code)
        }
        return [row]
    }

    /// Canonical codes, merged duplicates, sorted rows and targets.
    static func normalize(_ entries: [LanguageEntry]) -> [LanguageEntry] {
        var names: [String: String] = [:]
        var targets: [String: Set<String>] = [:]
        for entry in entries {
            let code = LanguageCode.canonical(entry.code)
            if names[code] == nil { names[code] = entry.name }
            for t in entry.targets {
                let tc = LanguageCode.canonical(t)
                if tc != code { targets[code, default: []].insert(tc) }
            }
            if targets[code] == nil { targets[code] = [] }
        }
        return names.keys.sorted().map {
            LanguageEntry(code: $0, name: names[$0]!, targets: targets[$0]!.sorted())
        }
    }
}
