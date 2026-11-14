import Foundation

/// `service install` runs as three phases: validate (no side effects), quiesce (stop what runs) and
/// apply (write and load). When quiesce or apply fails, `compensation` says what to undo.
public enum InstallPhase: Sendable, Equatable {
    case validate, quiesce, apply
}

public enum CompensationStep: Sendable, Equatable {
    /// Best-effort unload of the agent that the failed apply phase may have bootstrapped.
    case bootoutNewAgent
    case restoreConfig
    case restorePlist
    case removeNewPlist
    case rebootstrapOldAgent
    case restartNonAgentServer
}

public enum InstallPlan {
    public static func compensation(wasLoaded: Bool, hadPlist: Bool, stoppedNonAgent: Bool,
                                    failedPhase: InstallPhase) -> [CompensationStep] {
        guard failedPhase != .validate else { return [] }
        var steps: [CompensationStep] = []
        if failedPhase == .apply {
            steps.append(.bootoutNewAgent)
            steps.append(.restoreConfig)
            steps.append(hadPlist ? .restorePlist : .removeNewPlist)
        }
        // Quiesce never touched config or plist, so only the stopped things need reviving.
        if wasLoaded && hadPlist {
            steps.append(.rebootstrapOldAgent)
        } else if stoppedNonAgent {
            steps.append(.restartNonAgentServer)
        }
        return steps
    }
}
