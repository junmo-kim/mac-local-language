import Foundation

/// Single source of truth for error code -> (HTTP status, exit code).
public enum ErrorCode: String, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case unsupportedLanguage = "unsupported_language"
    case notInstalled = "not_installed"
    case unableToDetect = "unable_to_detect"
    case payloadTooLarge = "payload_too_large"
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case timeout = "timeout"
    /// CLI only (no HTTP status).
    case sessionUnavailable = "session_unavailable"
    /// CLI only (no HTTP status).
    case invalidConfig = "invalid_config"
    case internalError = "internal"

    public var httpStatus: Int? {
        switch self {
        case .invalidRequest, .unsupportedLanguage, .notInstalled, .unableToDetect: return 400
        case .payloadTooLarge: return 413
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .timeout: return 504
        case .internalError: return 500
        case .sessionUnavailable, .invalidConfig: return nil
        }
    }

    public var exitCode: ExitCode {
        switch self {
        case .invalidRequest, .payloadTooLarge, .notFound, .methodNotAllowed: return .usage
        case .unsupportedLanguage, .notInstalled: return .unavailable
        case .unableToDetect: return .dataError
        case .timeout, .sessionUnavailable: return .tempFail
        case .invalidConfig: return .config
        case .internalError: return .runtimeError
        }
    }

    /// Map a server response to an exit code: a known `code` wins, otherwise the HTTP status
    /// class decides (4xx -> 64, anything else -> 1).
    public static func exitCode(forCode code: String?, httpStatus: Int) -> ExitCode {
        if let code, let known = ErrorCode(rawValue: code) { return known.exitCode }
        return (400..<500).contains(httpStatus) ? .usage : .runtimeError
    }
}
