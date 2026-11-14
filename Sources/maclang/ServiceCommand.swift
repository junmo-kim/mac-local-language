import Foundation
import Darwin
import LangCore

/// `maclang service install|uninstall|start|stop|status` — manages the login LaunchAgent that
/// keeps the server running inside the GUI session.
enum ServiceCommand {
    static let help = """
    maclang service install [--host H] [--port N]   write config.json and the LaunchAgent, then load it
    maclang service uninstall                       unload the agent and move its plist to the Trash
    maclang service start                           start the server (kickstart when loaded)
    maclang service stop                            stop the running server (only this install's own)
    maclang service status [--format yaml|json]     agent, bundle and server state
    """

    private static var domain: String { "gui/\(getuid())" }

    static func run(_ rest: [String]) async throws -> Int32 {
        guard let sub = rest.first, !sub.hasPrefix("--") else {
            IO.emitText(help + "\n")
            return rest.first == nil ? ExitCode.usage.rawValue : 0
        }
        let args = ArgParser.parse(Array(rest.dropFirst()), booleanFlags: ["help"])
        if args.flag("help") { IO.emitText(help + "\n"); return 0 }
        let paths = currentPaths()
        switch sub {
        case "install": return try install(args, paths)
        case "uninstall": return try uninstall(paths)
        case "start": return try start(paths)
        case "stop": return try stop(paths)
        case "status":
            let format = try resolveFormat(args, default: .yaml, allowed: [.json, .yaml])
            IO.emitText(render(try status(paths), as: format))
            return 0
        default:
            throw CLIError("unknown service command '\(sub)' (expected install|uninstall|start|stop|status)",
                           fix: "run one of: maclang service install | uninstall | start | stop | status", field: "service command", received: sub)
        }
    }

    // MARK: launchctl state

    private static func target(_ paths: Paths) -> String { "\(domain)/\(paths.label)" }

    private static func loadedState(_ paths: Paths) -> (loaded: Bool, info: AgentSpec.PrintInfo) {
        guard let out = Launcher.launchctl(["print", target(paths)], timeout: 2), out.status == 0 else {
            return (false, AgentSpec.PrintInfo(state: nil, pid: nil, lastExitCode: nil))
        }
        return (true, AgentSpec.parsePrint(out.text))
    }

    private static func client(_ paths: Paths) throws -> (ServerClient, Config) {
        let config = try loadConfig(paths)
        return (ServerClient(host: config.clientHost, port: config.port), config)
    }

    // MARK: install

    /// Every bootout in this file goes through here: unload the agent and wait (<= 5 s) until launchd no
    /// longer lists it and nothing answers on the `clients` expected to go quiet.
    private static func bootoutAndWait(_ paths: Paths, _ clients: [ServerClient]) {
        _ = Launcher.launchctl(["bootout", target(paths)], timeout: 10)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let gone = !loadedState(paths).loaded
            let quiet = clients.allSatisfy { if case .unreachable = $0.probe(timeout: 0.5) { return true } else { return false } }
            if gone && quiet { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func bootstrapAgent(_ paths: Paths) throws {
        if Launcher.sessionKind() == .gui {
            let out = Launcher.launchctl(["bootstrap", domain, paths.agentPlist.path], timeout: 10)
            if out?.status != 0 {
                throw CLIError("launchctl bootstrap failed: \((out?.text ?? "no output").trimmingCharacters(in: .whitespacesAndNewlines))",
                               code: .internalError,
                               fix: "check the plist (`plutil -lint \(paths.agentPlist.path)`), run `maclang service uninstall`, then retry `maclang service install`")
            }
        } else {
            try bootstrapViaApp(paths)
        }
    }

    /// Three phases: A validate (no side effects), B quiesce (stop what runs), C apply. A failure in B or C
    /// is compensated (see `InstallPlan`) and reported together with the rollback outcome.
    private static func install(_ args: ParsedArgs, _ paths: Paths) throws -> Int32 {
        let fm = FileManager.default

        // --- A. validate -------------------------------------------------------------------------
        let oldConfigData = try? Data(contentsOf: paths.config)
        let oldConfig = try loadConfig(paths)
        var config = oldConfig
        if let host = try optString(args, "host") { config.host = host }
        if let port = try optInt(args, "port") {
            guard (1...65535).contains(port) else {
                throw CLIError("invalid --port: \(port) (expected 1-65535)", fix: "use a port from 1 to 65535, e.g. `--port 9091`", field: "--port", received: "\(port)")
            }
            config.port = port
        }
        let oldClient = ServerClient(host: oldConfig.clientHost, port: oldConfig.port)
        let cl = ServerClient(host: config.clientHost, port: config.port)

        let lintFile = fm.temporaryDirectory.appendingPathComponent("maclang-lint-\(getpid()).plist")
        defer { try? fm.removeItem(at: lintFile) }
        do { try AgentSpec.plist(paths: paths).write(to: lintFile) }
        catch { throw CLIError("cannot render the LaunchAgent plist: \(error.localizedDescription)", code: .internalError, fix: "check free space in the temporary directory and retry `maclang service install`") }
        let lintResult = Launcher.plutilLint(lintFile)
        guard let lint = lintResult, lint.status == 0 else {
            throw CLIError("the generated LaunchAgent plist failed plutil -lint: \((lintResult?.text ?? "plutil did not run").trimmingCharacters(in: .whitespacesAndNewlines))", code: .internalError,
                           fix: "check that /usr/bin/plutil works and that MACLANG_HOME/MACLANG_LABEL contain no unusual characters, then retry")
        }
        switch cl.probe(timeout: 1) {
        case .foreign:
            throw foreignPortError(config)
        case .maclang(let info):
            func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
            guard let exe = info.executable, resolved(exe) == resolved(paths.bundleExecutable.path) else {
                throw CLIError("refusing to install: a maclang server from another install holds \(config.clientHost):\(config.port)",
                               code: .internalError,
                               fix: "reported executable: \(info.executable ?? "unknown") (pid \(info.pid.map(String.init) ?? "unknown"), label \(info.label ?? "unknown")); expected: \(paths.bundleExecutable.path) (label \(paths.label)). Stop that server, install on another port (`maclang service install --port <free port>`), or run this command with the MACLANG_HOME and MACLANG_LABEL of that install",
                               field: "executable", received: info.executable)
            }
        case .unreachable: break
        }

        // --- B. quiesce ---------------------------------------------------------------------------
        let wasLoaded = loadedState(paths).loaded
        let oldPlistData = try? Data(contentsOf: paths.agentPlist)
        var stoppedNonAgent = false
        var phase = InstallPhase.quiesce
        var rollbackQuiet = [cl]

        func rollbackNote(_ failed: InstallPhase) -> String {
            let steps = InstallPlan.compensation(wasLoaded: wasLoaded, hadPlist: oldPlistData != nil,
                                                 stoppedNonAgent: stoppedNonAgent, failedPhase: failed)
            if steps.isEmpty { return "nothing to roll back" }
            var done: [String] = []
            for step in steps {
                switch step {
                case .bootoutNewAgent:
                    bootoutAndWait(paths, rollbackQuiet)
                    done.append("unloaded the new agent")
                case .restoreConfig:
                    if let oldConfigData { try? oldConfigData.write(to: paths.config, options: .atomic) }
                    else { try? fm.removeItem(at: paths.config) }
                    done.append("restored config.json")
                case .restorePlist:
                    if let oldPlistData { try? oldPlistData.write(to: paths.agentPlist, options: .atomic) }
                    done.append("restored the previous plist")
                case .removeNewPlist:
                    try? fm.removeItem(at: paths.agentPlist)
                    done.append("removed the new plist")
                case .rebootstrapOldAgent:
                    do { try bootstrapAgent(paths); done.append("reloaded the previous agent") }
                    catch { done.append("could NOT reload the previous agent (\((error as? CLIError)?.message ?? "error"))") }
                case .restartNonAgentServer:
                    do { _ = try startServer(paths: paths, client: oldClient, deadline: Date().addingTimeInterval(20)); done.append("restarted the previous server") }
                    catch { done.append("could NOT restart the previous server") }
                }
            }
            return "rollback: " + done.joined(separator: ", ")
        }

        // The old address is only this install's business when it differs from the new one AND what
        // answers there is this install's own server; any other maclang or foreign listener is left alone.
        let sameAddress = oldClient.host == cl.host && oldClient.port == cl.port
        var oldOwned = false
        if !sameAddress, case .maclang(let info) = oldClient.probe(timeout: 1), isOwnServer(paths, info) { oldOwned = true }
        var oldUnreachable = false
        if !sameAddress, case .unreachable = oldClient.probe(timeout: 1) { oldUnreachable = true }
        let quiet = (!sameAddress && (oldOwned || oldUnreachable)) ? [cl, oldClient] : [cl]
        rollbackQuiet = quiet

        do {
            if wasLoaded { bootoutAndWait(paths, quiet) }
            if !sameAddress, oldOwned, try stopServer(paths, oldClient) { stoppedNonAgent = true }
            if case .maclang = cl.probe(timeout: 1) {
                if try stopServer(paths, cl) { stoppedNonAgent = true }
            }

            // --- C. apply -------------------------------------------------------------------------
            phase = .apply
            do {
                try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
                try fm.createDirectory(at: paths.serverLog.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(config.render().utf8).write(to: paths.config, options: .atomic)
            } catch {
                throw CLIError("cannot write config.json: \(error.localizedDescription)", code: .internalError, fix: "check that \(paths.home.path) is writable, then retry `maclang service install`")
            }
            try AppBundle.ensure(paths, deadline: Date().addingTimeInterval(60))
            do {
                try fm.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
                try AgentSpec.plist(paths: paths).write(to: paths.agentPlist, options: .atomic)
            } catch {
                throw CLIError("cannot write the LaunchAgent plist: \(error.localizedDescription)", code: .internalError, fix: "check that \(paths.launchAgentsDir.path) is writable, then retry `maclang service install`")
            }
            try bootstrapAgent(paths)
            guard waitForHealth(cl, until: Date().addingTimeInterval(15)) != nil else {
                IO.warn((try? status(paths)).map { $0.render(as: .yaml) } ?? "")
                throw CLIError("the server did not become healthy after installing the LaunchAgent", code: .sessionUnavailable,
                               fix: "read \(paths.serverLog.path), run `maclang doctor`, and retry `maclang service install`")
            }
        } catch {
            let original = (error as? CLIError) ?? CLIError("install failed: \(error)", code: .internalError)
            throw original.appending(rollbackNote(phase))
        }
        IO.emitText(render(try status(paths), as: .yaml))
        return 0
    }

    /// Outside a GUI session `launchctl bootstrap gui/<uid>` fails, so ask the app (which runs in the
    /// GUI session) to do it via a request/result file handshake.
    private static func bootstrapViaApp(_ paths: Paths) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: paths.bootstrapResult)
        do { try Data(paths.agentPlist.path.utf8).write(to: paths.bootstrapRequest, options: .atomic) }
        catch { throw CLIError("cannot write bootstrap-request: \(error.localizedDescription)", code: .internalError, fix: "check that \(paths.home.path) is writable, then retry") }
        guard Launcher.openApp(paths.appBundle, newInstance: true) else {
            try? fm.removeItem(at: paths.bootstrapRequest)
            throw CLIError("could not start the maclang app in a GUI login session (is a user logged in?)", code: .sessionUnavailable,
                           fix: "log in to this Mac's desktop (a locked screen is fine), then retry `maclang service install`; run `maclang doctor` to see the session")
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: paths.bootstrapResult), let result = AgentSpec.decodeBootstrapResult(data) {
                try? fm.removeItem(at: paths.bootstrapResult)
                if result.exit != 0 {
                    throw CLIError("launchctl bootstrap failed (exit \(result.exit)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))",
                                   code: .internalError,
                                   fix: "run `maclang service uninstall`, then retry `maclang service install`; the output above is launchctl's")
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? fm.removeItem(at: paths.bootstrapRequest)
        throw CLIError("the maclang app did not answer the bootstrap request", code: .sessionUnavailable,
                       fix: "check that a user is logged in, read \(paths.serverLog.path), then retry `maclang service install`")
    }

    // MARK: uninstall / start / stop

    private static func uninstall(_ paths: Paths) throws -> Int32 {
        let fm = FileManager.default
        // Uninstall must work with a missing or corrupt config.json: fall back to the defaults.
        let config = (try? loadConfig(paths)) ?? .default
        let cl = ServerClient(host: config.clientHost, port: config.port)
        if loadedState(paths).loaded {
            bootoutAndWait(paths, [cl])
        }
        if fm.fileExists(atPath: paths.agentPlist.path) {
            do { try fm.trashItem(at: paths.agentPlist, resultingItemURL: nil) }
            catch { throw CLIError("cannot move the plist to the Trash: \(error.localizedDescription)", code: .internalError, fix: "move \(paths.agentPlist.path) to the Trash yourself, then rerun `maclang service uninstall`") }
        }
        // Only this install's own server is stopped. Another install's server (for example the
        // production one on the default port when config.json is corrupt) is left alone.
        if case .maclang(let info) = cl.probe(timeout: 1), isOwnServer(paths, info) { _ = try stopServer(paths, cl) }
        IO.emitText("uninstalled\n")
        return 0
    }

    private static func start(_ paths: Paths) throws -> Int32 {
        let (cl, config) = try client(paths)
        switch cl.probe(timeout: 1) {
        case .maclang: break
        case .foreign: throw foreignPortError(config)
        case .unreachable: _ = try startServer(paths: paths, client: cl, deadline: Date().addingTimeInterval(30))
        }
        IO.emitText(render(try status(paths), as: .yaml))
        return 0
    }

    private static func stop(_ paths: Paths) throws -> Int32 {
        let (cl, _) = try client(paths)
        IO.emitText(try stopServer(paths, cl) ? "stopped\n" : "not running\n")
        return 0
    }

    /// SIGTERM the server behind /health, but only if it is this install's own bundle executable
    /// (reported path AND the kernel's view of the pid agree). Returns false when nothing was running.
    @discardableResult
    private static func stopServer(_ paths: Paths, _ cl: ServerClient) throws -> Bool {
        let health: HealthInfo
        switch cl.probe(timeout: 1) {
        case .unreachable: return false
        case .foreign:
            throw CLIError("refusing to stop the process answering on port \(cl.port): it is not a maclang server",
                           code: .internalError,
                           fix: "stop that program yourself (find it with `lsof -nP -iTCP:\(cl.port) -sTCP:LISTEN`); maclang only stops its own server (expected \(paths.bundleExecutable.path))",
                           field: "port", received: "\(cl.port)")
        case .maclang(let info): health = info
        }
        guard isOwnServer(paths, health), let pid = health.pid else {
            throw CLIError("refusing to stop the process answering on port \(cl.port): it is not this install's server",
                           code: .internalError,
                           fix: "reported executable: \(health.executable ?? "unknown") (pid \(health.pid.map(String.init) ?? "unknown"), label \(health.label ?? "unknown")); expected: \(paths.bundleExecutable.path) (label \(paths.label)). To stop that server run this command with its MACLANG_HOME and MACLANG_LABEL, or stop the pid yourself",
                           field: "executable", received: health.executable)
        }
        kill(Int32(pid), SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if kill(Int32(pid), 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError("the server did not exit within 5 seconds", code: .internalError,
                       fix: "check pid \(pid) (`kill -9 \(pid)` as a last resort), then retry")
    }

    /// The reported executable AND the kernel's view of the pid both say this install's bundle executable.
    private static func isOwnServer(_ paths: Paths, _ health: HealthInfo) -> Bool {
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let expected = resolved(paths.bundleExecutable.path)
        guard let pid = health.pid, pid > 1, let reported = health.executable, resolved(reported) == expected,
              let actual = processPath(pid: Int32(pid)), resolved(actual) == expected else { return false }
        return true
    }

    private static func processPath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    // MARK: status

    static func status(_ paths: Paths) throws -> YAMLValue {
        let (cl, _) = try client(paths)
        let state = loadedState(paths)
        let probed = cl.probe(timeout: 1)
        let health = probed.info
        let bundle = AppBundle.installedVersion(paths)
        func opt(_ s: String?) -> YAMLValue { s.map { .string($0) } ?? .null }
        func optInt(_ i: Int?) -> YAMLValue { i.map { .int($0) } ?? .null }
        return .dict([
            ("label", .string(paths.label)),
            ("plist_path", .string(paths.agentPlist.path)),
            ("installed", .bool(FileManager.default.fileExists(atPath: paths.agentPlist.path))),
            ("loaded", .bool(state.loaded)),
            ("launchd_state", opt(state.info.state)),
            ("last_exit_code", optInt(state.info.lastExitCode)),
            ("server", .dict([("state", .string(probed.name)), ("reachable", .bool(health != nil)), ("version", opt(health?.version)),
                              ("pid", optInt(health?.pid)), ("session", opt(health?.session))])),
            ("bundle", .dict([("path", .string(paths.appBundle.path)), ("version", opt(bundle.version))])),
        ])
    }
}
