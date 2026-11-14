import Testing
@testable import LangCore

@Suite("install-validation install compensation plan")
struct InstallPlanTests {
    typealias S = CompensationStep
    private func plan(_ loaded: Bool, _ plist: Bool, _ stopped: Bool, _ phase: InstallPhase) -> [S] {
        InstallPlan.compensation(wasLoaded: loaded, hadPlist: plist, stoppedNonAgent: stopped, failedPhase: phase)
    }

    @Test("validation failures have nothing to undo", arguments: [true, false])
    func validate(flag: Bool) {
        #expect(plan(flag, flag, flag, .validate).isEmpty)
        #expect(plan(true, false, true, .validate).isEmpty)
    }

    @Test("quiesce failure: revive only what was stopped")
    func quiesce() {
        #expect(plan(true, true, false, .quiesce) == [.rebootstrapOldAgent])
        #expect(plan(true, true, true, .quiesce) == [.rebootstrapOldAgent])
        #expect(plan(false, false, true, .quiesce) == [.restartNonAgentServer])
        #expect(plan(false, true, true, .quiesce) == [.restartNonAgentServer])
        #expect(plan(false, true, false, .quiesce).isEmpty)
        #expect(plan(false, false, false, .quiesce).isEmpty)
    }

    @Test("apply failure with a loaded agent and a plist: restore config and plist, reload the old agent")
    func applyLoaded() {
        #expect(plan(true, true, false, .apply)
                == [.bootoutNewAgent, .restoreConfig, .restorePlist, .rebootstrapOldAgent])
        #expect(plan(true, true, true, .apply)
                == [.bootoutNewAgent, .restoreConfig, .restorePlist, .rebootstrapOldAgent])
    }

    @Test("apply failure on a fresh install: remove the new plist, restart a stopped non-agent server")
    func applyFresh() {
        #expect(plan(false, false, false, .apply) == [.bootoutNewAgent, .restoreConfig, .removeNewPlist])
        #expect(plan(false, false, true, .apply)
                == [.bootoutNewAgent, .restoreConfig, .removeNewPlist, .restartNonAgentServer])
    }

    @Test("apply failure with a plist that was not loaded")
    func applyUnloaded() {
        #expect(plan(false, true, false, .apply) == [.bootoutNewAgent, .restoreConfig, .restorePlist])
        #expect(plan(false, true, true, .apply)
                == [.bootoutNewAgent, .restoreConfig, .restorePlist, .restartNonAgentServer])
    }

    @Test("loaded without a plist file cannot be re-bootstrapped; falls back to the server restart")
    func loadedWithoutPlist() {
        #expect(plan(true, false, true, .apply)
                == [.bootoutNewAgent, .restoreConfig, .removeNewPlist, .restartNonAgentServer])
        #expect(plan(true, false, false, .quiesce).isEmpty)
    }

    @Test("own-agent only our own bundle executable counts as our agent")
    func ownProgram() {
        #expect(AgentSpec.isOwn(program: "/h/MacLang.app/Contents/MacOS/maclang", expected: "/h/MacLang.app/Contents/MacOS/maclang"))
        #expect(AgentSpec.isOwn(program: "/h/x/../MacLang.app/Contents/MacOS/maclang", expected: "/h/MacLang.app/Contents/MacOS/maclang"))
        #expect(!AgentSpec.isOwn(program: "/other/maclang", expected: "/h/MacLang.app/Contents/MacOS/maclang"))
        #expect(!AgentSpec.isOwn(program: nil, expected: "/h/MacLang.app/Contents/MacOS/maclang"))
    }

    @Test("probe-retry only a drop or a post-connect hang is retried once")
    func retry() {
        #expect(HealthClassifier.needsRetry(.dropped))
        #expect(HealthClassifier.needsRetry(.timedOutAfterConnect))
        #expect(!HealthClassifier.needsRetry(.refused))
        #expect(!HealthClassifier.needsRetry(.response(status: 404, body: .init())))
    }
}
