import Foundation
import LangCore

/// Entry path when LaunchServices starts `MacLang.app` (no arguments, no environment).
enum AppMode {
    static func shouldEnter() -> Bool {
        guard CommandLine.arguments.count == 1, Bundle.main.bundleIdentifier != nil,
              let exe = Bundle.main.executablePath else { return false }
        return Paths.appModeHome(executablePath: exe) != nil
    }

    static func run() async -> Int32 {
        let paths = currentPaths()
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.serverLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = freopen(paths.serverLog.path, "a", stderr)

        // A non-GUI `service install` asks us (a GUI-session process) to run `launchctl bootstrap`.
        if let request = try? String(contentsOf: paths.bootstrapRequest, encoding: .utf8) {
            let plist = request.trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: paths.bootstrapRequest)
            let out = Launcher.launchctl(["bootstrap", "gui/\(getuid())", plist], timeout: 10)
            let status = out?.status ?? 1
            let text = out?.text ?? "launchctl did not finish"
            try? AgentSpec.encodeBootstrapResult(exit: Int(status), output: text)
                .write(to: paths.bootstrapResult, options: .atomic)
            return status
        }
        do { return try await ServeCommand.run([]) }
        catch let e as CLIError {
            IO.warn(e.report)
            return e.exitCode
        } catch { return ExitCode.runtimeError.rawValue }
    }
}
