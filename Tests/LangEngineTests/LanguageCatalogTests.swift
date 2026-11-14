import Testing
import Foundation
import os
import LangCore
@testable import LangEngine

private final class Counter: Sendable {
    let calls = OSAllocatedUnfairLock(initialState: [(StrategyOption?, String?)]())
    var count: Int { calls.withLock { $0.count } }
}

private let full: [LanguageEntry] = [
    LanguageEntry(code: "ko", name: "Korean", targets: ["en"]),
    LanguageEntry(code: "en", name: "English", targets: ["ko", "ja"]),
]

@Suite("E-CAT language catalog")
struct LanguageCatalogTests {
    private func catalog(_ counter: Counter, delayMs: Int = 0, now: @escaping @Sendable () -> Date = { Date() }) -> LanguageCatalog {
        LanguageCatalog(now: now) { strategy, from in
            counter.calls.withLock { $0.append((strategy, from)) }
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            if let from {
                guard let row = full.first(where: { $0.code == from }) else { throw EngineError(.unsupportedLanguage, "x") }
                return [row]
            }
            return full
        }
    }

    @Test("E-CAT-1 two requests compute once; result is sorted")
    func caches() async throws {
        let counter = Counter()
        let c = catalog(counter)
        let a = try await c.languages(strategy: nil, from: nil)
        let b = try await c.languages(strategy: nil, from: nil)
        #expect(counter.count == 1)
        #expect(a == b)
        #expect(a.map(\.code) == ["en", "ko"])
        #expect(a[0].targets == ["ja", "ko"])
    }

    @Test("E-CAT-1 from computes only that row, and is served from the full catalog when available")
    func fromRow() async throws {
        let counter = Counter()
        let c = catalog(counter)
        let ko = try await c.languages(strategy: nil, from: "ko")
        #expect(ko.map(\.code) == ["ko"])
        #expect(counter.calls.withLock { $0.first?.1 } == "ko")
        _ = try await c.languages(strategy: nil, from: "ko")
        #expect(counter.count == 1)

        _ = try await c.languages(strategy: nil, from: nil)
        #expect(counter.count == 2)
        let en = try await c.languages(strategy: nil, from: "en")
        #expect(en.map(\.code) == ["en"])
        #expect(counter.count == 2)
        do { _ = try await c.languages(strategy: nil, from: "fr"); Issue.record("expected failure") }
        catch { #expect(error.code == .unsupportedLanguage) }
    }

    @Test("strategies are cached separately")
    func perStrategy() async throws {
        let counter = Counter()
        let c = catalog(counter)
        _ = try await c.languages(strategy: nil, from: nil)
        _ = try await c.languages(strategy: .lowLatency, from: nil)
        _ = try await c.languages(strategy: .lowLatency, from: nil)
        #expect(counter.count == 2)
    }

    @Test("catalog-key an omitted strategy and an explicit high-fidelity share one cache entry")
    func omittedEqualsHighFidelity() async throws {
        let counter = Counter()
        let c = catalog(counter)
        _ = try await c.languages(strategy: nil, from: nil)
        _ = try await c.languages(strategy: .highFidelity, from: nil)
        _ = try await c.languages(strategy: nil, from: "ko")
        _ = try await c.languages(strategy: .highFidelity, from: "ko")
        #expect(counter.count == 1)
        // The computation gets what the client asked for: nil when omitted (macOS < 26.4 has no strategy API).
        #expect(counter.calls.withLock { $0.first?.0 } == nil)
    }

    @Test("catalog-omitted-strategy an explicit strategy is passed through to the computation")
    func explicitPassedThrough() async throws {
        let counter = Counter()
        let c = catalog(counter)
        _ = try await c.languages(strategy: .lowLatency, from: nil)
        #expect(counter.calls.withLock { $0.first?.0 } == .lowLatency)
    }

    @Test("catalog-omitted-strategy without the strategy API an omitted strategy is fine and an explicit one is invalid_request")
    func noStrategyAPI() throws {
        try AppleTranslationEngine.validateStrategy(nil, apiAvailable: false)
        try AppleTranslationEngine.validateStrategy(.highFidelity, apiAvailable: true)
        do { try AppleTranslationEngine.validateStrategy(.highFidelity, apiAvailable: false); Issue.record("expected failure") }
        catch { #expect(error.code == .invalidRequest) }
    }

    @Test("catalog-strategy-validation an unsupported explicit strategy is rejected even when the cache is warm")
    func validatesBeforeCache() async throws {
        let counter = Counter()
        let engine = AppleTranslationEngine(strategyAPI: false)
        let c = LanguageCatalog(validate: { (s: StrategyOption?) throws(EngineError) in try engine.validateStrategy(s) }) { s, f in
            counter.calls.withLock { $0.append((s, f)) }
            return full
        }
        _ = try await c.languages(strategy: nil, from: nil)
        for from in [nil, "ko"] as [String?] {
            do { _ = try await c.languages(strategy: .highFidelity, from: from); Issue.record("expected invalid_request") }
            catch { #expect(error.code == .invalidRequest) }
        }
        _ = try await c.languages(strategy: nil, from: "ko")
        #expect(counter.count == 1)
    }

    @Test("catalog-deadline a stuck computation times out so a later request can retry")
    func computeTimeout() async throws {
        let counter = Counter()
        let c = LanguageCatalog(computeTimeout: 0.3) { strategy, from in
            counter.calls.withLock { $0.append((strategy, from)) }
            if counter.count == 1 {
                // Ignores cancellation, like a wedged framework call.
                let end = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            }
            return full
        }
        let start = ContinuousClock.now
        do { _ = try await c.languages(strategy: nil, from: nil); Issue.record("expected timeout") }
        catch { #expect(error.code == .timeout) }
        #expect(ContinuousClock.now - start < .seconds(2))
        let second = try await c.languages(strategy: nil, from: nil)
        #expect(second.map(\.code) == ["en", "ko"])
        #expect(counter.count == 2)
    }

    @Test("concurrent requests share the in-flight computation")
    func shared() async throws {
        let counter = Counter()
        let c = catalog(counter, delayMs: 200)
        async let a = c.languages(strategy: nil, from: nil)
        async let b = c.languages(strategy: nil, from: nil)
        async let d = c.languages(strategy: nil, from: nil)
        let results = try await [a, b, d]
        #expect(counter.count == 1)
        #expect(results[0] == results[2])
    }

    @Test("entries expire after the one-hour ttl; failures are not cached")
    func ttlAndFailure() async throws {
        let counter = Counter()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let c = catalog(counter, now: { clock.withLock { $0 } })
        _ = try await c.languages(strategy: nil, from: nil)
        clock.withLock { $0 = $0.addingTimeInterval(3599) }
        _ = try await c.languages(strategy: nil, from: nil)
        #expect(counter.count == 1)
        clock.withLock { $0 = $0.addingTimeInterval(2) }
        _ = try await c.languages(strategy: nil, from: nil)
        #expect(counter.count == 2)

        let failing = LanguageCatalog { _, _ in throw EngineError(.notInstalled, "n") }
        for _ in 0..<2 {
            do { _ = try await failing.languages(strategy: nil, from: nil); Issue.record("expected failure") }
            catch { #expect(error.code == .notInstalled) }
        }
    }

    @Test("results are canonicalized, de-duplicated and sorted")
    func normalizes() async throws {
        let c = LanguageCatalog { _, _ in
            [LanguageEntry(code: "pt-BR", name: "Portuguese", targets: ["en-US", "ko", "ko"]),
             LanguageEntry(code: "pt", name: "Portuguese", targets: ["ja", "pt"]),
             LanguageEntry(code: "en", name: "English", targets: ["pt-BR"])]
        }
        let r = try await c.languages(strategy: nil, from: nil)
        #expect(r.map(\.code) == ["en", "pt"])
        #expect(r[1].targets == ["en", "ja", "ko"])
        #expect(r[0].targets == ["pt"])
    }

    @Test("warmUp populates the default-strategy cache")
    func warm() async throws {
        let counter = Counter()
        let c = catalog(counter, delayMs: 50)
        await c.warmUp()
        _ = try await c.languages(strategy: nil, from: nil)
        #expect(counter.count == 1)
    }
}
