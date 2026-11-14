import Testing
import LangCore
@testable import LangEngine

// An omitted strategy resolves to `.highFidelity` explicitly. The framework's implicit default
// and `LanguageAvailability().preferredStrategy` both depend on the calling context: inside the
// long-running server they resolved to a strategy without language packs (`notInstalled`) while
// a top-level probe in the same login session got high fidelity. High fidelity is macOS 27's
// documented default and the strategy with installed packs, so the engine never relies on the
// implicit value when the strategy API exists.
@Suite("E-STR strategy resolution")
struct StrategyResolutionTests {
    @Test("E-STR-1 an explicit request is kept")
    func explicitKept() {
        #expect(resolveStrategy(requested: .lowLatency) == .lowLatency)
        #expect(resolveStrategy(requested: .highFidelity) == .highFidelity)
    }

    @Test("E-STR-2 an omitted request resolves to high fidelity")
    func omittedIsHighFidelity() {
        #expect(resolveStrategy(requested: nil) == .highFidelity)
    }
}
