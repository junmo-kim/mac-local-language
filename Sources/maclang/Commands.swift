import Foundation
import LangCore
import LangEngine
import Darwin

// MARK: - shared helpers

let environment = ProcessInfo.processInfo.environment

private func readText(_ args: ParsedArgs) throws -> String {
    guard args.positionals.count <= 1 else {
        throw CLIError("expected a single TEXT argument (quote it), got \(args.positionals.count)",
                       fix: "quote the text: `maclang translate \"Hello world\" --to ko`, or pipe it on stdin", field: "TEXT", received: args.positionals.joined(separator: " "))
    }
    var text: String
    if let given = args.firstPositional {
        text = given
    } else {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        if text.hasSuffix("\r\n") { text.removeLast(2) } else if text.hasSuffix("\n") { text.removeLast() }
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError("input text is empty", fix: "pass non-blank text: `maclang translate \"Hello\" --to ko` or `echo Hello | maclang translate --to ko`", field: "TEXT", received: "")
    }
    return text
}

private func language(_ args: ParsedArgs, _ key: String) throws -> String? {
    guard let raw = try optString(args, key) else { return nil }
    do { return try LanguageCode.normalize(raw, field: "--\(key)") } catch { throw CLIError(error) }
}

private func strategy(_ args: ParsedArgs) throws -> StrategyOption? {
    guard let raw = try optString(args, "strategy") else { return nil }
    guard let s = StrategyOption(rawValue: raw) else {
        throw CLIError("invalid --strategy: \(raw) (expected high-fidelity|low-latency)", fix: "use `--strategy high-fidelity` or `--strategy low-latency`, or omit it (maclang then requests high fidelity)", field: "--strategy", received: raw)
    }
    return s
}

private func routeRequest(_ args: ParsedArgs) throws -> RouteRequest {
    guard let raw = try optString(args, "route") else { return .auto }
    guard let r = RouteRequest(rawValue: raw) else {
        throw CLIError("invalid --route: \(raw) (expected auto|local|server)", fix: "use `--route auto`, `--route local` or `--route server`", field: "--route", received: raw)
    }
    return r
}

/// Single routing decision. The session is probed only when the table needs it.
private func resolveRoute(_ args: ParsedArgs) throws -> Route {
    let requested = try routeRequest(args)
    let engine = EngineKind(env: environment)
    let session: SessionKind = (requested == .auto && engine == .apple) ? Launcher.sessionKind() : .gui
    return Route.resolve(requested: requested, session: session, engine: engine)
}

// MARK: - forwarding to the login-session server

func loadConfig(_ paths: Paths) throws -> Config {
    do { return try Config.parse(try? Data(contentsOf: paths.config)) } catch { throw CLIError(error) }
}

func waitForHealth(_ client: ServerClient, until deadline: Date, interval: TimeInterval = 0.2) -> HealthInfo? {
    while true {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { return nil }
        if let info = client.health(timeout: min(1, left)) { return info }
        Thread.sleep(forTimeInterval: min(interval, max(0, deadline.timeIntervalSinceNow)))
    }
}

/// The one start path (CLI auto-start and `service start`): materialize the bundle, then either
/// kickstart the loaded LaunchAgent or `open` the bundle, and wait for /health. Callers must have
/// established that no maclang server is running (the bundle may be replaced).
func startServer(paths: Paths, client: ServerClient, deadline: Date) throws -> HealthInfo {
    let failure = CLIError("could not start the maclang server in a GUI login session (is a user logged in?)",
                           code: .sessionUnavailable,
                           fix: "log in to this Mac's desktop (a locked screen is fine), then retry; if you are logged in, run `maclang doctor` and read \(paths.serverLog.path)",
                           field: "label", received: paths.label)
    try AppBundle.ensure(paths, deadline: deadline)
    let target = "gui/\(getuid())/\(paths.label)"
    // Kickstart only our own agent; a loaded service with the same label but another program is not ours.
    let printed = Launcher.launchctl(["print", target], timeout: min(2, max(0.1, deadline.timeIntervalSinceNow)))
    if printed?.status == 0,
       AgentSpec.isOwn(program: AgentSpec.parsePrint(printed?.text ?? "").program, expected: paths.bundleExecutable.path) {
        let out = Launcher.launchctl(["kickstart", target], timeout: min(10, max(0.1, deadline.timeIntervalSinceNow)))
        guard out?.status == 0 else {
            let output = (out?.text ?? "no output").trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("launchctl kickstart failed: \(output)", code: .sessionUnavailable,
                           fix: "retry `maclang service start`; if it keeps failing run `maclang service install` again, and check \(paths.serverLog.path)")
        }
    } else {
        let openTimeout = min(10, deadline.timeIntervalSinceNow)
        guard openTimeout > 0, Launcher.openApp(paths.appBundle, timeout: openTimeout) else { throw failure }
    }
    guard let info = waitForHealth(client, until: min(deadline, Date().addingTimeInterval(15))) else { throw failure }
    return info
}

func foreignPortError(_ config: Config) -> CLIError {
    CLIError("port \(config.clientHost):\(config.port) is in use by another program (not maclang)", code: .sessionUnavailable,
             fix: "stop the program on \(config.clientHost):\(config.port) (find it with `lsof -nP -iTCP:\(config.port) -sTCP:LISTEN`) or move maclang: `maclang service install --port <free port>`",
             field: "port", received: "\(config.clientHost):\(config.port)")
}

enum Forward {
    /// One round trip to the server, starting it if needed. `timeout` bounds the whole call: the
    /// health probe, bundle build, server start-up wait and the request itself.
    static func call(method: String, path: String, body: Data?, timeout: Double) throws -> HTTPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        let paths = currentPaths()
        let config = try loadConfig(paths)
        let client = ServerClient(host: config.clientHost, port: config.port)

        var info: HealthInfo
        switch client.probe(timeout: min(1, timeout)) {
        case .maclang(let i):
            info = i
        case .foreign:
            throw foreignPortError(config)
        case .unreachable:
            guard RuntimeEnv(env: environment).autostart else {
                throw CLIError("could not reach the maclang server at \(config.clientHost):\(config.port) and autostart is disabled",
                               code: .sessionUnavailable,
                               fix: "unset MACLANG_AUTOSTART (it is 0) or run `maclang service start`",
                               field: "MACLANG_AUTOSTART", received: environment["MACLANG_AUTOSTART"] ?? "")
            }
            info = try startServer(paths: paths, client: client, deadline: deadline)
        }
        if let warning = Version.mismatchWarning(server: info.version, cli: Version.current) {
            IO.warn(warning)
        }
        let result = client.request(method: method, path: path, body: body, timeout: deadline.timeIntervalSinceNow)
        switch result {
        case .success(let response):
            guard response.status == 200 else { throw CLIError(serverStatus: response.status, body: response.body) }
            return response
        case .failure(.timeout):
            throw CLIError("timed out waiting for the maclang server", code: .timeout,
                           fix: "retry; for long texts raise `--timeout` (now \(timeout) s); check `maclang service status`")
        case .failure:
            throw CLIError("lost the connection to the maclang server", code: .sessionUnavailable,
                           fix: "check `maclang service status` and the server log (\(paths.serverLog.path)), then retry")
        }
    }
}

func currentPaths() -> Paths {
    let userHome = FileManager.default.homeDirectoryForCurrentUser
    var paths = Paths(env: environment, userHome: userHome)
    // App mode / LaunchAgent runs get no environment: home and label come from the bundle itself.
    if let exe = Bundle.main.executablePath, let home = Paths.appModeHome(executablePath: exe),
       let label = Bundle.main.bundleIdentifier {
        paths = Paths(home: home, label: label, launchAgentsDir: paths.launchAgentsDir.path)
    }
    return paths
}

private func runLocal<T: Sendable>(
    timeout: Double,
    _ operation: @escaping @Sendable (any TranslationEngine) async throws -> T
) async throws -> T {
    let engine = EngineFactory.make(env: environment, timeoutSeconds: timeout)
    do {
        return try await withTimeout(seconds: timeout) { try await operation(engine) }
    } catch {
        throw CLIError(error)
    }
}

private func wantsHelp(_ args: ParsedArgs) -> Bool { args.flag("help") || args.flag("h") }

// MARK: - translate

enum TranslateCommand {
    static let help = """
    maclang translate [TEXT] --to LANG [--from LANG|auto] [--strategy high-fidelity|low-latency]
                      [--format text|json|yaml] [--timeout SEC] [--route auto|local|server]

    Translate TEXT (or stdin when TEXT is omitted) on-device. Default --from auto, --timeout 60,
    --format text. --format json prints exactly what the HTTP /translate endpoint returns.
    Without --strategy, maclang always requests high fidelity.
    Outside a GUI login session the request is forwarded to the login-session server (--route).
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let format = try resolveFormat(args, default: .text, allowed: [.text, .json, .yaml])
        guard let to = try language(args, "to") else { throw CLIError("missing required option: --to", fix: "add the target language: `maclang translate \"Hello\" --to ko`", field: "--to") }
        let fromRaw = try optString(args, "from")
        let from: String? = (fromRaw == nil || fromRaw == "auto") ? nil : try language(args, "from")
        let strat = try strategy(args)
        let timeout = try optDouble(args, "timeout") ?? 60
        let route = try resolveRoute(args)
        let text = try readText(args)

        let result: TranslateResult
        if route == .local {
            let output = try await runLocal(timeout: timeout) { engine in
                try await engine.translate(text, from: from, to: to, strategy: strat)
            }
            result = TranslateResult(text: output.text, detected: output.detected)
        } else {
            var payload: [String: Any] = ["q": text, "source": from ?? "auto", "target": to]
            if let strat { payload["strategy"] = strat.rawValue }
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try Forward.call(method: "POST", path: "/translate", body: body, timeout: timeout)
            do {
                guard let first = try Wire.decodeTranslateResponse(response.body).results.first else {
                    throw CLIError("malformed server response", code: .internalError)
                }
                result = first
            } catch let e as LangError { throw CLIError(e) }
        }
        switch format {
        case .text:
            IO.emitText(result.text + "\n")
        case .json, .yaml:
            IO.emitText(render(Wire.translateResponse([result], batch: false, alternatives: 0), as: format))
        }
        return 0
    }
}

// MARK: - detect

enum DetectCommand {
    static let help = """
    maclang detect [TEXT] [--format text|json|yaml]

    Detect the language of TEXT (or stdin) with NaturalLanguage. Always local, works in any session.
    text prints the top language code; json/yaml list up to 3 candidates with confidence 0-100.
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let format = try resolveFormat(args, default: .text, allowed: [.text, .json, .yaml])
        let text = try readText(args)
        let found = NLDetector.detect(text, max: 3)
        guard let top = found.first else {
            throw CLIError("could not detect the language", code: .unableToDetect,
                           fix: "pass longer text, or skip detection and give the language yourself (`maclang translate … --from <code>`)", field: "TEXT")
        }
        switch format {
        case .text: IO.emitText(top.language + "\n")
        case .json, .yaml: IO.emitText(render(Wire.detect(found), as: format))
        }
        return 0
    }
}

// MARK: - languages

enum LanguagesCommand {
    static let help = """
    maclang languages [--from LANG] [--strategy S] [--format yaml|json] [--timeout SEC] [--route auto|local|server]

    List translation languages and the targets installed for each. --from limits the work to one
    source language (47 lookups on the local path). Without --from the local path takes about
    16 seconds; the server caches the catalog.
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let format = try resolveFormat(args, default: .yaml, allowed: [.json, .yaml])
        let from = try language(args, "from")
        let strat = try strategy(args)
        let timeout = try optDouble(args, "timeout") ?? 60
        let route = try resolveRoute(args)
        var entries: [LanguageEntry]
        if route == .local {
            entries = try await runLocal(timeout: timeout) { engine in
                try await engine.languages(strategy: strat, from: from)
            }
        } else {
            let path = strat.map { "/languages?strategy=\($0.rawValue)" } ?? "/languages"
            let response = try Forward.call(method: "GET", path: path, body: nil, timeout: timeout)
            do { entries = try Wire.decodeLanguages(response.body) } catch { throw CLIError(error) }
            if let from {
                entries = entries.filter { $0.code == from }
                if entries.isEmpty { throw CLIError("unsupported source language: \(from)", code: .unsupportedLanguage, field: "--from", received: from) }
            }
        }
        IO.emitText(render(Wire.languages(entries), as: format))
        return 0
    }
}

// MARK: - doctor

enum DoctorCommand {
    static let help = """
    maclang doctor [--format yaml|json]

    Report the session kind, engine, paths, bundle, LaunchAgent and server status. Outside a GUI
    login session the Translation framework is never called.
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let format = try resolveFormat(args, default: .yaml, allowed: [.json, .yaml])

        let paths = currentPaths()
        let config = try loadConfig(paths)
        let engine = EngineKind(env: environment)
        let session = Launcher.sessionKind()
        let fm = FileManager.default

        let bundleExists = fm.fileExists(atPath: paths.appBundle.path)
        var bundleVersion: YAMLValue = .null
        if bundleExists,
           let data = try? Data(contentsOf: paths.appBundle.appendingPathComponent("Contents/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let v = plist["CFBundleShortVersionString"] as? String {
            bundleVersion = .string(v)
        }

        let loaded = Launcher.launchctl(["print", "gui/\(getuid())/\(paths.label)"], timeout: 2)?.status == 0

        let health = ServerClient(host: config.clientHost, port: config.port).probe(timeout: 1)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        var pairs: [(String, YAMLValue)] = [
            ("version", .string(Version.current)),
            ("macos", .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")),
            ("session", .string(session.name)),
            ("strategy_api", .bool(AppleTranslationEngine.strategyAPIAvailable)),
            ("engine", .string(engine == .mock ? "mock" : "apple-translation")),
            ("home", .string(paths.home.path)),
            ("label", .string(paths.label)),
            ("bundle", .dict([("path", .string(paths.appBundle.path)), ("exists", .bool(bundleExists)),
                              ("version", bundleVersion)])),
            ("agent", .dict([("plist", .string(paths.agentPlist.path)),
                             ("installed", .bool(fm.fileExists(atPath: paths.agentPlist.path))),
                             ("loaded", .bool(loaded))])),
            ("server", .dict([("host", .string(config.host)), ("port", .int(config.port)),
                              ("state", .string(health.name)), ("reachable", .bool(health.info != nil)),
                              ("version", health.info.map { .string($0.version) } ?? .null)])),
        ]
        if session == .gui, engine == .apple {
            let status = (try? await withTimeout(seconds: 5) { await AppleAvailability.englishToKoreanStatus() }) ?? "unknown"
            pairs.append(("translation", .dict([("en_to_ko", .string(status))])))
        }
        IO.emitText(render(.dict(pairs), as: format))
        return 0
    }
}

// MARK: - serve

enum ServeCommand {
    static let help = """
    maclang serve [--host H] [--port N] [--max-body-kib K] [--engine-timeout SEC]

    Run the LibreTranslate-compatible HTTP server (POST /translate, POST /detect, GET /languages,
    GET /health). Host and port default to <home>/config.json (127.0.0.1:9091). --max-body-kib
    defaults to 1024 and --engine-timeout to 30. The real engine needs a GUI login session; the
    command refuses to start (exit 75) without one.
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let hostFlag = try optString(args, "host")
        let portFlag = try optInt(args, "port")
        let maxBodyKiB = try optInt(args, "max-body-kib") ?? 1024
        let engineTimeout = try optDouble(args, "engine-timeout") ?? 30
        if let p = portFlag, !(1...65535).contains(p) { throw CLIError("invalid --port: \(p) (expected 1-65535)", fix: "use a port from 1 to 65535, e.g. `--port 9091`", field: "--port", received: "\(p)") }
        guard maxBodyKiB > 0 else { throw CLIError("invalid --max-body-kib: \(maxBodyKiB) (expected a positive integer)", fix: "use a positive number of KiB, e.g. `--max-body-kib 1024`", field: "--max-body-kib", received: "\(maxBodyKiB)") }

        let engineKind = EngineKind(env: environment)
        let session = Launcher.sessionKind()
        if engineKind == .apple, session != .gui {
            throw CLIError("the apple engine needs a GUI login session (current session: \(session.name)); nothing was bound",
                           code: .sessionUnavailable,
                           fix: "from SSH use `maclang service install` (a LaunchAgent in your desktop session) or just `maclang translate …` (it forwards to the login-session server)",
                           field: "session", received: session.name)
        }

        let paths = currentPaths()
        let config = try loadConfig(paths)

        let settings = ServerSettings(
            host: hostFlag ?? config.host, port: portFlag ?? config.port,
            maxBodyBytes: maxBodyKiB * 1024, engineTimeout: engineTimeout,
            engineName: engineKind == .mock ? "mock" : "apple-translation",
            session: session.name, label: paths.label,
            supervised: environment["XPC_SERVICE_NAME"] == paths.label)
        let engine = EngineFactory.make(env: environment, timeoutSeconds: engineTimeout)
        return await HTTPServer.run(settings: settings, engine: engine)
    }
}
