// Adapted from mac-local-vision (MIT, same author).
import Foundation
import LangCore
import Darwin

/// Error raised by command handlers. Printed on stderr as `error: <message> (<code>)` followed by
/// `fix: <next action>` and, when known, `field:` / `received:` echoing the offending input.
struct CLIError: Error {
    let message: String
    /// Table code (or whatever `code` string a server sent).
    let codeName: String
    let exitCode: Int32
    let fix: String?
    let field: String?
    let received: String?

    init(_ message: String, code: ErrorCode = .invalidRequest, fix: String? = nil, field: String? = nil, received: String? = nil) {
        self.message = message
        self.codeName = code.rawValue
        self.exitCode = code.exitCode.rawValue
        self.fix = fix ?? code.defaultFix
        self.field = field
        self.received = received
    }

    init(message: String, codeName: String, exitCode: Int32, fix: String?, field: String?, received: String?) {
        self.message = message
        self.codeName = codeName
        self.exitCode = exitCode
        self.fix = fix
        self.field = field
        self.received = received
    }

    /// Same code, fix and exit status, with extra context appended to the message.
    func appending(_ note: String) -> CLIError {
        CLIError(message: "\(message); \(note)", codeName: codeName, exitCode: exitCode, fix: fix, field: field, received: received)
    }

    init(_ error: LangError) {
        self.init(error.message, code: error.code, fix: error.fix, field: error.field, received: error.received)
    }

    /// Error answered by the server: its `code` maps through the table, unknown codes fall back to the
    /// HTTP class; the server's fix/field/received are passed through.
    init(serverStatus: Int, body: Data) {
        let d = Wire.decodeError(body)
        self.message = d.message
        self.codeName = d.code ?? "http_\(serverStatus)"
        self.exitCode = ErrorCode.exitCode(forCode: d.code, httpStatus: serverStatus).rawValue
        self.fix = d.fix ?? d.code.flatMap { ErrorCode(rawValue: $0) }?.defaultFix
        self.field = d.field
        self.received = d.received
    }

    /// The stderr text (no trailing newline).
    var report: String {
        var lines = ["error: \(message) (\(codeName))"]
        if let fix { lines.append("fix: \(fix)") }
        if let field { lines.append("field: \(field)") }
        if let received { lines.append("received: \(received)") }
        return lines.joined(separator: "\n")
    }
}

enum IO {
    @TaskLocal static var dataOutputFileDescriptor: Int32 = STDOUT_FILENO

    static func emitText(_ text: String) {
        writeData(Data(text.utf8))
    }

    /// Keep caller-visible output separate from diagnostics written directly to fd 1 by
    /// Apple frameworks. The redirection lasts for the remaining process lifetime so delayed
    /// native messages cannot corrupt an already-written JSON or YAML response.
    static func withProcessDataOutputBoundary<T>(
        _ operation: nonisolated(nonsending) () async -> T
    ) async -> T? {
        let dataOutput = dup(STDOUT_FILENO)
        guard dataOutput >= 0 else { return nil }
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(dataOutput)
            return nil
        }
        defer { close(dataOutput) }
        return await $dataOutputFileDescriptor.withValue(dataOutput, operation: operation)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func writeData(_ data: Data) {
        FileHandle(fileDescriptor: dataOutputFileDescriptor, closeOnDealloc: false).write(data)
    }
}

enum CLIFormat: String {
    case text, json, yaml
}

/// `--format` with a per-command default and allowed set.
func resolveFormat(_ args: ParsedArgs, default def: CLIFormat, allowed: Set<CLIFormat>) throws -> CLIFormat {
    guard let raw = args.option("format") else {
        if args.flag("format") { throw CLIError("--format requires a value", fix: "pass one of text|json|yaml, e.g. `--format json`", field: "--format") }
        return def
    }
    guard let format = CLIFormat(rawValue: raw), allowed.contains(format) else {
        let names = allowed.map(\.rawValue).sorted().joined(separator: "|")
        throw CLIError("invalid --format: \(raw) (expected \(names))", fix: "use `--format \(names)`", field: "--format", received: raw)
    }
    return format
}

/// Render a value tree: JSON is exactly the HTTP body (`Wire.jsonBody`), YAML the same value.
func render(_ value: YAMLValue, as format: CLIFormat) -> String {
    switch format {
    case .json: return Wire.jsonBody(value)
    case .yaml, .text: return value.render(as: .yaml) + "\n"
    }
}

func optDouble(_ args: ParsedArgs, _ key: String) throws -> Double? {
    if args.flag(key) { throw CLIError("--\(key) requires a value", fix: "pass a number of seconds, e.g. `--\(key) 60`", field: "--\(key)") }
    guard let raw = args.option(key) else { return nil }
    guard let value = Double(raw), TimeoutBounds.isValid(value) else {
        throw CLIError("invalid --\(key): \(raw) (expected a number of seconds above 0 and at most 86400)", fix: "use a number of seconds from 0.001 to 86400, e.g. `--\(key) 60`", field: "--\(key)", received: raw)
    }
    return value
}

func optInt(_ args: ParsedArgs, _ key: String) throws -> Int? {
    if args.flag(key) { throw CLIError("--\(key) requires a value", fix: "pass an integer, e.g. `--\(key) 9091`", field: "--\(key)") }
    guard let raw = args.option(key) else { return nil }
    guard let value = Int(raw) else {
        throw CLIError("invalid --\(key): \(raw) (expected an integer)", fix: "pass a whole number, e.g. `--\(key) 9091`", field: "--\(key)", received: raw)
    }
    return value
}

func optString(_ args: ParsedArgs, _ key: String) throws -> String? {
    if args.flag(key) { throw CLIError("--\(key) requires a value", fix: "pass a value, e.g. `--\(key) <value>`; see `maclang <command> --help`", field: "--\(key)") }
    return args.option(key)
}
