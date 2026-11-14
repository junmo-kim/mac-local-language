// Adapted from mac-local-vision (MIT, same author).
import Foundation
import LangCore
import Darwin

/// Error raised by command handlers; printed as `error: <message> (<code>)` on stderr.
struct CLIError: Error {
    let message: String
    var code: ErrorCode = .invalidRequest

    var exitCode: Int32 { code.exitCode.rawValue }

    init(_ message: String, code: ErrorCode = .invalidRequest) {
        self.message = message
        self.code = code
    }

    init(_ error: LangError) {
        self.message = error.message
        self.code = error.code
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
        if args.flag("format") { throw CLIError("--format requires a value") }
        return def
    }
    guard let format = CLIFormat(rawValue: raw), allowed.contains(format) else {
        let names = allowed.map(\.rawValue).sorted().joined(separator: "|")
        throw CLIError("invalid --format: \(raw) (expected \(names))")
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
    if args.flag(key) { throw CLIError("--\(key) requires a value") }
    guard let raw = args.option(key) else { return nil }
    guard let value = Double(raw), value > 0, value.isFinite else {
        throw CLIError("invalid --\(key): \(raw) (expected a positive number)")
    }
    return value
}

func optInt(_ args: ParsedArgs, _ key: String) throws -> Int? {
    if args.flag(key) { throw CLIError("--\(key) requires a value") }
    guard let raw = args.option(key) else { return nil }
    guard let value = Int(raw) else {
        throw CLIError("invalid --\(key): \(raw) (expected an integer)")
    }
    return value
}

func optString(_ args: ParsedArgs, _ key: String) throws -> String? {
    if args.flag(key) { throw CLIError("--\(key) requires a value") }
    return args.option(key)
}
