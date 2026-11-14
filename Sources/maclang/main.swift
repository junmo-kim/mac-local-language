import Foundation
import LangCore

func printUsage() {
    let usage = """
    maclang \(Version.current) — on-device translation and language detection for macOS

    USAGE:
      maclang <command> [options]

    COMMANDS:
      translate [TEXT] --to LANG [--from LANG|auto] [--strategy high-fidelity|low-latency] [--format text|json|yaml] [--timeout SEC] [--route auto|local|server]
      detect [TEXT] [--format text|json|yaml]
      languages [--from LANG] [--strategy S] [--format yaml|json] [--timeout SEC] [--route auto|local|server]
      doctor [--format yaml|json]
      serve [--host H] [--port N] [--max-body-kib K] [--engine-timeout SEC]
      --version | --help

    TEXT is read from stdin when omitted. Data goes to stdout, errors to stderr as
    `error: <message> (<code>)`. Run `maclang <command> --help` for details.
    """
    IO.emitText(usage + "\n")
}

let arguments = Array(CommandLine.arguments.dropFirst())

func dispatch(_ args: [String]) async -> Int32 {
    guard let sub = args.first else {
        printUsage()
        return ExitCode.usage.rawValue
    }
    let rest = Array(args.dropFirst())
    do {
        switch sub {
        case "translate": return try await TranslateCommand.run(rest)
        case "detect":    return try await DetectCommand.run(rest)
        case "languages": return try await LanguagesCommand.run(rest)
        case "doctor":    return try await DoctorCommand.run(rest)
        case "serve":     return try await ServeCommand.run(rest)
        case "help", "-h", "--help": printUsage(); return ExitCode.success.rawValue
        case "version", "--version": IO.emitText("maclang \(Version.current)\n"); return ExitCode.success.rawValue
        default:
            IO.warn("error: unknown command '\(sub)' (try: maclang --help) (\(ErrorCode.invalidRequest.rawValue))")
            return ExitCode.usage.rawValue
        }
    } catch let error as CLIError {
        IO.warn("error: \(error.message) (\(error.code.rawValue))")
        return error.exitCode
    } catch {
        IO.warn("error: unexpected failure (\(ErrorCode.internalError.rawValue))")
        return ExitCode.runtimeError.rawValue
    }
}

guard let code = await IO.withProcessDataOutputBoundary({
    await dispatch(arguments)
}) else {
    IO.warn("error: could not reserve stdout for structured output")
    exit(ExitCode.runtimeError.rawValue)
}
exit(code)
