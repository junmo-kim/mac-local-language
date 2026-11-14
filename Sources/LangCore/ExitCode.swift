import Foundation

/// Process exit codes (sysexits-style). Retrying `usage` is pointless; `tempFail` is retryable.
public enum ExitCode: Int32, Sendable {
    case success = 0
    case runtimeError = 1
    /// EX_USAGE
    case usage = 64
    /// EX_DATAERR
    case dataError = 65
    /// EX_UNAVAILABLE
    case unavailable = 69
    /// EX_TEMPFAIL
    case tempFail = 75
    /// EX_CONFIG
    case config = 78
}
