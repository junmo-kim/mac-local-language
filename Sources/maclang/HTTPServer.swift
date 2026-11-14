// Adapted from mac-local-vision (MIT, same author).
import Foundation
import Darwin
import Network
import os
import LangCore
import LangEngine

enum HTTPServer {}

// MARK: - serving

/// Runs engine work one call at a time (FIFO). Waiters that were cancelled while queued do not
/// start their work.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct ServerSettings: Sendable {
    let host: String
    let port: Int
    let maxBodyBytes: Int
    let engineTimeout: Double
    let engineName: String
    let session: String
    let label: String
    /// Started by launchd for this label (`XPC_SERVICE_NAME == label`): KeepAlive keeps retrying.
    let supervised: Bool
}

/// Everything a request handler needs. Translation goes through `gate` and `withTimeout`.
/// The language catalog does not: it only queries `LanguageAvailability` (no sessions), and
/// its ~16 s start-up warm-up must not hold the first translation behind it.
final class ServerContext: Sendable {
    let engine: any TranslationEngine
    let gate = SerialGate()
    let catalog: LanguageCatalog
    let settings: ServerSettings
    let healthBody: String

    init(engine: any TranslationEngine, settings: ServerSettings) {
        self.engine = engine
        self.settings = settings
        self.catalog = LanguageCatalog(validate: { (s: StrategyOption?) throws(EngineError) in try engine.validateStrategy(s) }) { strategy, from in
            try await engine.languages(strategy: strategy, from: from)
        }
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments.first ?? "maclang"
        self.healthBody = Wire.jsonBody(Wire.health(
            version: Version.current, pid: Int(getpid()), session: settings.session,
            engine: settings.engineName, label: settings.label, executable: executable))
    }

    /// Serialized, time-bounded engine call. The timeout covers queue wait plus the call.
    func engineCall<T: Sendable>(_ operation: @escaping @Sendable (any TranslationEngine) async throws -> T) async throws(EngineError) -> T {
        let engine = self.engine
        let gate = self.gate
        return try await withTimeout(seconds: settings.engineTimeout) {
            try await gate.run { try await operation(engine) }
        }
    }
}

struct HTTPResult {
    let status: Int
    let body: String
    var code: ErrorCode? = nil
}

extension HTTPServer {
    /// Request logging never includes bodies, query strings or translations.
    private static func log(_ message: String) {
        IO.warn("maclang serve: \(message)")
    }

    static func run(settings: ServerSettings, engine: any TranslationEngine) async -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let context = ServerContext(engine: engine, settings: settings)

        func alreadyRunningOrFail(_ reason: String) -> Int32 {
            let clientHost = Config(host: settings.host, port: settings.port).clientHost
            if let info = ServerClient(host: clientHost, port: settings.port).health(timeout: 1) {
                if settings.supervised {
                    // Exit non-zero so KeepAlive(SuccessfulExit=false) retries until the unsupervised
                    // instance is gone and launchd owns the server.
                    log("another maclang (version \(info.version)) holds \(settings.host):\(settings.port); exiting so launchd retries")
                    return ExitCode.runtimeError.rawValue
                }
                log("already running on \(settings.host):\(settings.port) (version \(info.version))")
                return ExitCode.success.rawValue
            }
            IO.warn("error: could not bind to \(settings.host):\(settings.port) (\(reason))")
            return ExitCode.runtimeError.rawValue
        }

        guard let listener = makeListener(host: settings.host, port: UInt16(settings.port)) else {
            return alreadyRunningOrFail("port may be in use")
        }

        enum Event { case ready, failed(String), cancelled, signalled }
        let (events, continuation) = AsyncStream<Event>.makeStream()

        listener.newConnectionHandler = { conn in
            Task { await handle(conn, context: context) }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield(.ready)
            case .failed(let err): continuation.yield(.failed("\(err)"))
            case .waiting(let err): continuation.yield(.failed("\(err)"))
            case .cancelled: continuation.yield(.cancelled)
            default: break
            }
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { continuation.yield(.signalled) }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        listener.start(queue: .global(qos: .userInitiated))

        var isReady = false
        for await event in events {
            switch event {
            case .ready:
                isReady = true
                log("listening on \(settings.host):\(settings.port) (engine \(settings.engineName), session \(settings.session)\(settings.supervised ? ", launchd-managed" : ""))")
                Task { await context.catalog.warmUp() }
            case .failed(let reason):
                listener.cancel()
                if isReady {
                    IO.warn("error: listener failed: \(reason)")
                    return ExitCode.runtimeError.rawValue
                }
                return alreadyRunningOrFail(reason)
            case .signalled:
                log("shutting down")
                listener.cancel()
                // Wait for the cancelled state so the port is released before exit.
            case .cancelled:
                return ExitCode.success.rawValue
            }
        }
        return ExitCode.success.rawValue
    }

    // MARK: listener / connection

    private static func makeListener(host: String, port: UInt16) -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            IO.warn("error: invalid port value \(port)"); return nil
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener?
        if host == "0.0.0.0" || host == "::" {
            listener = try? NWListener(using: params, on: nwPort)
        } else {
            // requiredLocalEndpoint already contains the port. Passing `on: nwPort` as
            // well makes Network.framework reject explicit hosts on macOS 27.
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
            listener = try? NWListener(using: params)
        }
        return listener
    }

    private static func receiveChunk(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data, !data.isEmpty { c.resume(returning: data) } else { c.resume(returning: nil) }
            }
        }
    }

    private static let noLengthError = LangError(
        .invalidRequest, "chunked bodies are not supported; send Content-Length",
        fix: "send the body with a Content-Length header (e.g. curl --data-binary) instead of Transfer-Encoding: chunked",
        field: "Content-Length")

    private enum Received {
        case request(HTTPRequest)
        case reject(LangError)
        case none
    }

    private static func handle(_ conn: NWConnection, context: ServerContext) async {
        conn.start(queue: .global(qos: .userInitiated))
        // Drop connections that never finish sending a request.
        let watchdog = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel(); conn.cancel() }

        let result: HTTPResult
        var logLine = "?"
        switch await receiveHTTPRequest(conn, maxBody: context.settings.maxBodyBytes) {
        case .none:
            return
        case .reject(let error):
            result = errorResult(error)
        case .request(let req):
            watchdog.cancel()
            let path = req.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? req.path
            logLine = "\(req.method) \(path)"
            result = await route(req, path: path, context: context)
        }
        log("\(logLine) -> \(result.status)" + (result.code.map { " \($0.rawValue)" } ?? ""))
        await sendHTTPResponse(conn, status: result.status, body: Data(result.body.utf8))
        if result.code == .payloadTooLarge {
            // The client is probably still sending the oversized body. Closing now would reset the
            // connection and could discard the 413 it has not read yet, so read and discard until it
            // finishes or 2 s pass.
            let cutoff = DispatchWorkItem { conn.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: cutoff)
            while await receiveChunk(conn) != nil {}
            cutoff.cancel()
        }
    }

    // MARK: routing

    private static func errorResult(_ e: LangError) -> HTTPResult {
        HTTPResult(status: e.code.httpStatus ?? 500, body: Wire.jsonBody(Wire.errorBody(e)), code: e.code)
    }

    /// Method each known path accepts (for the 405 fix).
    private static let allowedMethod: [String: String] = [
        "/health": "GET", "/translate": "POST", "/detect": "POST", "/languages": "GET",
    ]

    private static func route(_ req: HTTPRequest, path: String, context: ServerContext) async -> HTTPResult {
        let contentType = req.headers["content-type"]
        do {
            switch (path, req.method) {
            case ("/health", "GET"):
                return HTTPResult(status: 200, body: context.healthBody)
            case ("/translate", "POST"):
                let tr = try Wire.decodeTranslate(body: req.body, contentType: contentType)
                return try await translate(tr, context: context)
            case ("/detect", "POST"):
                let text = try Wire.decodeDetect(body: req.body, contentType: contentType)
                let found = NLDetector.detect(text, max: 3)
                guard !found.isEmpty else { throw LangError(.unableToDetect, "could not detect the language", field: "q") }
                return HTTPResult(status: 200, body: Wire.jsonBody(Wire.detect(found)))
            case ("/languages", "GET"):
                return try await languages(query: req.path, context: context)
            case ("/health", _), ("/translate", _), ("/detect", _), ("/languages", _):
                let allowed = allowedMethod[path] ?? "GET"
                return errorResult(LangError(.methodNotAllowed, "method \(req.method) not allowed for \(path)",
                                             fix: "use \(allowed) \(path)", field: "method", received: req.method))
            default:
                return errorResult(LangError(.notFound, "unknown path \(path)",
                                             fix: "use GET /health, POST /translate, POST /detect or GET /languages", field: "path", received: path))
            }
        } catch let e as LangError {
            return errorResult(e)
        } catch {
            return errorResult(LangError(.internalError, "internal error"))
        }
    }

    private static func translate(_ tr: TranslateRequest, context: ServerContext) async throws(LangError) -> HTTPResult {
        let from: String? = tr.source == "auto" ? nil : tr.source
        let texts = tr.texts
        let target = tr.target
        let strategy = tr.strategy
        let results: [TranslateResult] = try await context.engineCall { engine in
            var out: [TranslateResult] = []
            for text in texts {
                let o = try await engine.translate(text, from: from, to: target, strategy: strategy)
                out.append(TranslateResult(text: o.text, detected: o.detected))
            }
            return out
        }
        let value = Wire.translateResponse(results, batch: tr.isBatch, alternatives: tr.alternatives)
        return HTTPResult(status: 200, body: Wire.jsonBody(value))
    }

    private static func languages(query path: String, context: ServerContext) async throws(LangError) -> HTTPResult {
        var requested: StrategyOption?
        if let q = path.firstIndex(of: "?") {
            let params = Wire.parseForm(String(path[path.index(after: q)...]))
            if let raw = params["strategy"] as? String {
                guard let s = StrategyOption(rawValue: raw) else {
                    throw LangError(.invalidRequest, "strategy must be high-fidelity or low-latency", fix: "use ?strategy=high-fidelity or ?strategy=low-latency, or omit it", field: "strategy", received: raw)
                }
                requested = s
            }
        }
        let strategy = requested
        let catalog = context.catalog
        let entries = try await withTimeout(seconds: context.settings.engineTimeout) {
            try await catalog.languages(strategy: strategy, from: nil)
        }
        return HTTPResult(status: 200, body: Wire.jsonBody(Wire.languages(entries)))
    }

    // MARK: wire I/O

    /// Accumulate raw bytes until the headers plus `Content-Length` body bytes have arrived.
    /// A declared body above the cap is rejected from the headers alone.
    private static func receiveHTTPRequest(_ conn: NWConnection, maxBody: Int) async -> Received {
        let sep = Data("\r\n\r\n".utf8)
        let headerCap = 65_536
        var buf = Data()
        var bodyStart: Int?
        var expected = 0

        while true {
            guard let chunk = await receiveChunk(conn) else { return .none }
            buf.append(chunk)

            if bodyStart == nil {
                if let range = buf.range(of: sep) {
                    bodyStart = buf.distance(from: buf.startIndex, to: range.upperBound)
                    guard let head = String(data: buf[buf.startIndex..<range.lowerBound], encoding: .utf8) else {
                        return .reject(LangError(.invalidRequest, "headers are not valid UTF-8", fix: "send ASCII/UTF-8 request headers"))
                    }
                    let headLines = head.components(separatedBy: "\r\n")
                    let method = headLines.first?.split(separator: " ").first.map(String.init) ?? ""
                    var sawLength = false
                    for line in headLines.dropFirst() {
                        let lower = line.lowercased()
                        if lower.hasPrefix("transfer-encoding:"), lower.contains("chunked") {
                            return .reject(Self.noLengthError)
                        }
                        if lower.hasPrefix("content-length:") {
                            sawLength = true
                            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            guard let cl = Int(value), cl >= 0 else {
                                return .reject(LangError(.invalidRequest, "invalid Content-Length", fix: "send Content-Length as the body size in bytes", field: "Content-Length", received: value))
                            }
                            expected = cl
                        }
                    }
                    // No Content-Length is an empty body, unless bytes follow the headers anyway.
                    if !sawLength, ["POST", "PUT", "PATCH"].contains(method), buf.count > (bodyStart ?? 0) {
                        return .reject(Self.noLengthError)
                    }
                    if expected > maxBody {
                        return .reject(LangError(.payloadTooLarge, "request body exceeds \(maxBody / 1024) KiB",
                                                 fix: "split the text into requests under \(maxBody / 1024) KiB, or start the server with a larger `serve --max-body-kib`",
                                                 field: "Content-Length", received: "\(expected)"))
                    }
                } else if buf.count > headerCap {
                    return .reject(LangError(.invalidRequest, "request headers too large", fix: "send fewer or shorter request headers (limit 64 KiB)"))
                }
            }
            if let start = bodyStart, buf.count - start >= expected { break }
        }

        do { return .request(try HTTPParser.parse(buf)) }
        catch { return .reject(LangError(.invalidRequest, "malformed HTTP request", fix: "send a well-formed HTTP/1.1 request, e.g. `curl -s -d 'q=Hello&source=auto&target=ko' http://127.0.0.1:9091/translate`")) }
    }

    private static func sendHTTPResponse(_ conn: NWConnection, status: Int, body: Data) async {
        let header = "HTTP/1.1 \(status) \(httpPhrase(status))\r\nConnection: close\r\n"
            + "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(body)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            conn.send(content: resp, completion: .contentProcessed { error in
                if error != nil { log("send error (\(status))") }
                c.resume()
            })
        }
    }

    private static func httpPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        case 504: return "Gateway Timeout"
        default: return "Status \(status)"
        }
    }
}
