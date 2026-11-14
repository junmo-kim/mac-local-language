import Foundation

/// Single source of file locations. Everything is derived from `home`, `label` and the
/// LaunchAgents directory; environment lookups happen only in `init(env:userHome:)`.
public struct Paths: Equatable, Sendable {
    public static let defaultLabel = "kim.junmo.maclang"

    public let home: URL
    public let label: String
    public let launchAgentsDir: URL

    public init(home: String, label: String, launchAgentsDir: String) {
        self.home = URL(fileURLWithPath: home)
        self.label = label
        self.launchAgentsDir = URL(fileURLWithPath: launchAgentsDir)
    }

    /// CLI resolution: `MACLANG_HOME`, `MACLANG_LABEL`, `MACLANG_LAUNCH_AGENTS_DIR` over defaults.
    public init(env: [String: String], userHome: URL) {
        func nonEmpty(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        self.init(
            home: nonEmpty("MACLANG_HOME")
                ?? userHome.appendingPathComponent("Library/Application Support/maclang").path,
            label: nonEmpty("MACLANG_LABEL") ?? Paths.defaultLabel,
            launchAgentsDir: nonEmpty("MACLANG_LAUNCH_AGENTS_DIR")
                ?? userHome.appendingPathComponent("Library/LaunchAgents").path)
    }

    public var appBundle: URL { home.appendingPathComponent("MacLang.app") }
    public var bundleExecutable: URL { appBundle.appendingPathComponent("Contents/MacOS/maclang") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var serverLog: URL { home.appendingPathComponent("logs/server.log") }
    public var bootstrapRequest: URL { home.appendingPathComponent("bootstrap-request") }
    public var bootstrapResult: URL { home.appendingPathComponent("bootstrap-result") }
    public var agentPlist: URL { launchAgentsDir.appendingPathComponent("\(label).plist") }

    /// App mode cannot receive environment variables, so home is the parent directory of the
    /// `*.app` that contains the executable. Returns nil when not run from `X.app/Contents/MacOS/`.
    public static func appModeHome(executablePath: String) -> String? {
        let url = URL(fileURLWithPath: executablePath)
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app.deletingLastPathComponent().path
    }
}
