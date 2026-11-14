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
