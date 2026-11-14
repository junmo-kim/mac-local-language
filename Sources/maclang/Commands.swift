import Foundation
import LangCore
import LangEngine
import Darwin

// MARK: - shared helpers

private let environment = ProcessInfo.processInfo.environment

private func readText(_ args: ParsedArgs) throws -> String {
    guard args.positionals.count <= 1 else {
        throw CLIError("expected a single TEXT argument (quote it), got \(args.positionals.count)")
    }
    var text: String
    if let given = args.firstPositional {
        text = given
    } else {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        if text.hasSuffix("\r\n") { text.removeLast(2) } else if text.hasSuffix("\n") { text.removeLast() }
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError("input text is empty")
    }
    return text
}

private func language(_ args: ParsedArgs, _ key: String) throws -> String? {
    guard let raw = try optString(args, key) else { return nil }
    do { return try LanguageCode.normalize(raw) } catch { throw CLIError(error) }
}

private func strategy(_ args: ParsedArgs) throws -> StrategyOption? {
    guard let raw = try optString(args, "strategy") else { return nil }
    guard let s = StrategyOption(rawValue: raw) else {
        throw CLIError("invalid --strategy: \(raw) (expected high-fidelity|low-latency)")
    }
    return s
}

private func routeRequest(_ args: ParsedArgs) throws -> RouteRequest {
    guard let raw = try optString(args, "route") else { return .auto }
    guard let r = RouteRequest(rawValue: raw) else {
        throw CLIError("invalid --route: \(raw) (expected auto|local|server)")
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

private func serverRoutePlaceholder() -> CLIError {
    // Phase 5 replaces this with the login-session server client.
    CLIError("the server route is not available in this build", code: .sessionUnavailable)
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
    Outside a GUI login session the request is forwarded to the login-session server (--route).
    """

    static func run(_ rest: [String]) async throws -> Int32 {
        let args = ArgParser.parse(rest, booleanFlags: ["help"])
        if wantsHelp(args) { IO.emitText(help + "\n"); return 0 }
        let format = try resolveFormat(args, default: .text, allowed: [.text, .json, .yaml])
        guard let to = try language(args, "to") else { throw CLIError("missing required option: --to") }
        let fromRaw = try optString(args, "from")
        let from: String? = (fromRaw == nil || fromRaw == "auto") ? nil : try language(args, "from")
        let strat = try strategy(args)
        let timeout = try optDouble(args, "timeout") ?? 60
        let route = try resolveRoute(args)
        let text = try readText(args)

        guard route == .local else { throw serverRoutePlaceholder() }

        let output = try await runLocal(timeout: timeout) { engine in
            try await engine.translate(text, from: from, to: to, strategy: strat)
        }
        switch format {
        case .text:
            IO.emitText(output.text + "\n")
        case .json, .yaml:
            let value = Wire.translateResponse([TranslateResult(text: output.text, detected: output.detected)],
                                               batch: false, alternatives: 0)
            IO.emitText(render(value, as: format))
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
            throw CLIError("could not detect the language", code: .unableToDetect)
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
        guard route == .local else { throw serverRoutePlaceholder() }

        let entries = try await runLocal(timeout: timeout) { engine in
            try await engine.languages(strategy: strat, from: from)
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

        let paths = Paths(env: environment, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let config: Config
        do { config = try Config.parse(try? Data(contentsOf: paths.config)) } catch { throw CLIError(error) }
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

        let uid = getuid()
        let loaded = Launcher.run("/bin/launchctl", ["print", "gui/\(uid)/\(paths.label)"], timeout: 2)?.status == 0

        let health = HTTPServer.probeHealth(host: config.clientHost, port: config.port, timeout: 1)

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
                              ("reachable", .bool(health != nil)),
                              ("version", health.map { .string($0.version) } ?? .null)])),
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
        if let p = portFlag, !(1...65535).contains(p) { throw CLIError("invalid --port: \(p) (expected 1-65535)") }
        guard maxBodyKiB > 0 else { throw CLIError("invalid --max-body-kib: \(maxBodyKiB) (expected a positive integer)") }

        let engineKind = EngineKind(env: environment)
        let session = Launcher.sessionKind()
        if engineKind == .apple, session != .gui {
            throw CLIError("the apple engine needs a GUI login session (current session: \(session.name)); nothing was bound",
                           code: .sessionUnavailable)
        }

        let paths = Paths(env: environment, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let config: Config
        do { config = try Config.parse(try? Data(contentsOf: paths.config)) } catch { throw CLIError(error) }

        let settings = ServerSettings(
            host: hostFlag ?? config.host, port: portFlag ?? config.port,
            maxBodyBytes: maxBodyKiB * 1024, engineTimeout: engineTimeout,
            engineName: engineKind == .mock ? "mock" : "apple-translation",
            session: session.name, label: paths.label)
        let engine = EngineFactory.make(env: environment, timeoutSeconds: engineTimeout)
        return await HTTPServer.run(settings: settings, engine: engine)
    }
}
