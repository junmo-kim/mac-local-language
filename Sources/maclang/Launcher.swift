import Foundation
import os
import LangCore

/// Spawning of system tools (`launchctl` and friends) with hard timeouts.
enum Launcher {
    struct Output {
        let status: Int32
        let text: String
    }

    /// Run an executable and capture stdout+stderr. Returns nil if it cannot be launched or
    /// does not finish within `timeout` seconds (the process is terminated).
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        let collectedBox = OSAllocatedUnfairLock(initialState: Data())
        let reader = DispatchQueue(label: "maclang.launcher.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            collectedBox.withLock { $0 = data }
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return Output(status: process.terminationStatus, text: String(decoding: collectedBox.withLock { $0 }, as: UTF8.self))
    }

    /// `launchctl managername`, trimmed. Any failure is `unknown` (and therefore non-GUI).
    static func managerName() -> String {
        guard let out = run("/bin/launchctl", ["managername"], timeout: 2), out.status == 0 else { return "unknown" }
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sessionKind() -> SessionKind {
        SessionKind.parse(managerName: managerName())
    }
}

extension Launcher {
    static func launchctl(_ arguments: [String], timeout: TimeInterval = 10) -> Output? {
        run("/bin/launchctl", arguments, timeout: timeout)
    }

    /// `open -g -j -a <bundle>`: background, hidden, and deliberately no `--args` (apps started
    /// by LaunchServices get neither arguments nor the caller's environment). `newInstance` adds
    /// `-n` so a still-alive earlier instance cannot swallow the launch (used for the install
    /// bootstrap request only).
    static func openApp(_ bundle: URL, newInstance: Bool = false, timeout: TimeInterval = 10) -> Bool {
        let flags = newInstance ? ["-n", "-g", "-j", "-a"] : ["-g", "-j", "-a"]
        return run("/usr/bin/open", flags + [bundle.path], timeout: timeout)?.status == 0
    }

    static func codesign(label: String, bundle: URL, timeout: TimeInterval = 30) -> Output? {
        run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label, bundle.path], timeout: timeout)
    }

    static func plutilLint(_ file: URL) -> Output? {
        run("/usr/bin/plutil", ["-lint", file.path], timeout: 10)
    }
}
