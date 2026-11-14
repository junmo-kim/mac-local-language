import Testing
@testable import LangCore

@Suite("U-ERR error code table")
struct ErrorCodeTests {
    @Test("U-ERR-1 every code maps to the exact (HTTP, exit) pair")
    func table() {
        let expected: [(ErrorCode, String, Int?, Int32)] = [
            (.invalidRequest, "invalid_request", 400, 64),
            (.unsupportedLanguage, "unsupported_language", 400, 69),
            (.notInstalled, "not_installed", 400, 69),
            (.unableToDetect, "unable_to_detect", 400, 65),
            (.payloadTooLarge, "payload_too_large", 413, 64),
            (.notFound, "not_found", 404, 64),
            (.methodNotAllowed, "method_not_allowed", 405, 64),
            (.timeout, "timeout", 504, 75),
            (.sessionUnavailable, "session_unavailable", nil, 75),
            (.invalidConfig, "invalid_config", nil, 78),
            (.internalError, "internal", 500, 1),
        ]
        #expect(ErrorCode.allCases.count == expected.count)
        for (code, raw, http, exit) in expected {
            #expect(code.rawValue == raw)
            #expect(code.httpStatus == http)
            #expect(code.exitCode.rawValue == exit)
        }
    }

    @Test("U-ERR-1 unknown code falls back to the HTTP status class")
    func fallback() {
        #expect(ErrorCode.exitCode(forCode: "weird", httpStatus: 400).rawValue == 64)
        #expect(ErrorCode.exitCode(forCode: nil, httpStatus: 404).rawValue == 64)
        #expect(ErrorCode.exitCode(forCode: "weird", httpStatus: 502).rawValue == 1)
        #expect(ErrorCode.exitCode(forCode: nil, httpStatus: 500).rawValue == 1)
        // A known code wins over the status.
        #expect(ErrorCode.exitCode(forCode: "timeout", httpStatus: 400).rawValue == 75)
    }

    @Test("ExitCode raw values")
    func exitCodes() {
        #expect(ExitCode.success.rawValue == 0)
        #expect(ExitCode.runtimeError.rawValue == 1)
        #expect(ExitCode.usage.rawValue == 64)
        #expect(ExitCode.dataError.rawValue == 65)
        #expect(ExitCode.unavailable.rawValue == 69)
        #expect(ExitCode.tempFail.rawValue == 75)
        #expect(ExitCode.config.rawValue == 78)
    }

    @Test("every ErrorCode has a non-empty, deterministic default fix")
    func defaultFixes() {
        for code in ErrorCode.allCases {
            #expect(!code.defaultFix.isEmpty)
            #expect(code.defaultFix == code.defaultFix)
            #expect(LangError(code, "m").fix == code.defaultFix)
        }
        // Distinct codes give distinct advice.
        #expect(Set(ErrorCode.allCases.map(\.defaultFix)).count == ErrorCode.allCases.count)
    }
}
