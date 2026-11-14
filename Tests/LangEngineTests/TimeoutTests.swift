import Testing
import Foundation
import os
import LangCore
@testable import LangEngine

@Suite("E-TO timeout")
struct TimeoutTests {
    @Test("E-TO-1 a 2s mock bounded by 0.5s returns timeout within 1s and fires onTimeout")
    func timesOut() async {
        let fired = OSAllocatedUnfairLock(initialState: false)
        let engine = MockEngine(delayMs: 2000)
        let start = ContinuousClock.now
        do {
            _ = try await withTimeout(seconds: 0.5, onTimeout: { fired.withLock { $0 = true } }) {
                try await engine.translate("x", from: "en", to: "ko", strategy: nil)
            }
            Issue.record("expected timeout")
        } catch {
            #expect(error.code == .timeout)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(fired.withLock { $0 })
    }

    @Test("a fast operation returns its value and does not fire onTimeout")
    func succeeds() async throws {
        let fired = OSAllocatedUnfairLock(initialState: false)
        let out = try await withTimeout(seconds: 5, onTimeout: { fired.withLock { $0 = true } }) {
            try await MockEngine().translate("x", from: "en", to: "ko", strategy: nil)
        }
        #expect(out.text == "[mock en→ko] x")
        #expect(!fired.withLock { $0 })
    }

    @Test("operation errors pass through unchanged")
    func passthrough() async {
        do {
            _ = try await withTimeout(seconds: 5) {
                try await MockEngine().translate("x", from: "en", to: "xx", strategy: nil)
            }
            Issue.record("expected failure")
        } catch {
            #expect(error.code == .unsupportedLanguage)
        }
    }

    @Test("an operation that ignores cancellation still cannot hold the caller past the deadline")
    func uncooperative() async {
        let start = ContinuousClock.now
        do {
            _ = try await withTimeout(seconds: 0.2) { () async throws -> Int in
                let deadline = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < deadline { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
                return 1
            }
            Issue.record("expected timeout")
        } catch {
            #expect(error.code == .timeout)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
