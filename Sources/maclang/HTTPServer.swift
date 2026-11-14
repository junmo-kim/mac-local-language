// Adapted from mac-local-vision (MIT, same author).
import Foundation
import Darwin
import Network
import os
import LangCore
import LangEngine

struct HealthInfo: Sendable {
    let status: String
    let version: String
    let pid: Int?
    let session: String?
    let engine: String?
    let label: String?
    let executable: String?
}

enum HTTPServer {
    /// Minimal blocking `GET /health` over a BSD socket with a hard deadline.
    /// Returns nil when nothing answers 200 with a JSON object in time.
    static func probeHealth(host: String, port: Int, timeout: TimeInterval) -> HealthInfo? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        let deadline = Date().addingTimeInterval(timeout)
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            guard connectWithDeadline(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen, deadline) else { continue }

            let request = "GET /health HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            guard sendAll(fd, Array(request.utf8), deadline) else { continue }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while data.count < 65_536 {
                guard waitFor(fd, POLLIN, deadline) else { break }
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            if let info = parseHealth(data) { return info }
        }
        return nil
    }

    static func parseHealth(_ raw: Data) -> HealthInfo? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep),
              let head = String(data: raw[raw.startIndex..<range.lowerBound], encoding: .utf8),
              let statusLine = head.components(separatedBy: "\r\n").first,
              statusLine.split(separator: " ").dropFirst().first == "200",
              let obj = try? JSONSerialization.jsonObject(with: Data(raw[range.upperBound...])) as? [String: Any],
              let status = obj["status"] as? String, let version = obj["version"] as? String
        else { return nil }
        return HealthInfo(status: status, version: version, pid: obj["pid"] as? Int,
                          session: obj["session"] as? String, engine: obj["engine"] as? String,
                          label: obj["label"] as? String, executable: obj["executable"] as? String)
    }

    // MARK: - socket helpers

    private static func remaining(_ deadline: Date) -> Int32 {
        Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSinceNow * 1000)))
    }

    private static func waitFor(_ fd: Int32, _ events: Int32, _ deadline: Date) -> Bool {
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let r = poll(&p, 1, remaining(deadline))
        return r > 0 && (p.revents & Int16(events | POLLHUP)) != 0
    }

    private static func connectWithDeadline(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t, _ deadline: Date) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = connect(fd, addr, len)
        if r != 0 {
            guard errno == EINPROGRESS, waitFor(fd, POLLOUT, deadline) else { return false }
            var err: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
            guard err == 0 else { return false }
        }
        return true
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8], _ deadline: Date) -> Bool {
        var sent = 0
        while sent < bytes.count {
            guard waitFor(fd, POLLOUT, deadline) else { return false }
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}


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
}

/// Everything a request handler needs. Engine access goes through `gate` and `withTimeout`.
final class ServerContext: Sendable {
    let engine: any TranslationEngine
    let gate = SerialGate()
    let catalog: LanguageCatalog
    let settings: ServerSettings
    let healthBody: String

    init(engine: any TranslationEngine, settings: ServerSettings) {
        self.engine = engine
        self.settings = settings
        let gate = self.gate
        self.catalog = LanguageCatalog { strategy, from in
            try await gate.run { try await engine.languages(strategy: strategy, from: from) }
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
            if let info = probeHealth(host: clientHost, port: settings.port, timeout: 1), info.status == "ok" {
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
                log("listening on \(settings.host):\(settings.port) (engine \(settings.engineName), session \(settings.session))")
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

    private enum Received {
        case request(HTTPRequest)
        case reject(ErrorCode, String)
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
        case .reject(let code, let message):
            result = errorResult(code, message)
        case .request(let req):
            watchdog.cancel()
            let path = req.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? req.path
            logLine = "\(req.method) \(path)"
            result = await route(req, path: path, context: context)
        }
        log("\(logLine) -> \(result.status)" + (result.code.map { " \($0.rawValue)" } ?? ""))
        await sendHTTPResponse(conn, status: result.status, body: Data(result.body.utf8))
    }

    // MARK: routing

    private static func errorResult(_ code: ErrorCode, _ message: String) -> HTTPResult {
        HTTPResult(status: code.httpStatus ?? 500,
                   body: Wire.jsonBody(Wire.errorBody(message: message, code: code)), code: code)
    }

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
                guard !found.isEmpty else { throw LangError(.unableToDetect, "could not detect the language") }
                return HTTPResult(status: 200, body: Wire.jsonBody(Wire.detect(found)))
            case ("/languages", "GET"):
                return try await languages(query: req.path, context: context)
            case ("/health", _), ("/translate", _), ("/detect", _), ("/languages", _):
                return errorResult(.methodNotAllowed, "method \(req.method) not allowed for \(path)")
            default:
                return errorResult(.notFound, "unknown path \(path)")
            }
        } catch let e as LangError {
            return errorResult(e.code, e.message)
        } catch {
            return errorResult(.internalError, "internal error")
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
                    throw LangError(.invalidRequest, "strategy must be high-fidelity or low-latency")
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
            let chunk = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if let data, !data.isEmpty { c.resume(returning: data) } else { c.resume(returning: nil) }
                }
            }
            guard let chunk else { return .none }
            buf.append(chunk)

            if bodyStart == nil {
                if let range = buf.range(of: sep) {
                    bodyStart = buf.distance(from: buf.startIndex, to: range.upperBound)
                    guard let head = String(data: buf[buf.startIndex..<range.lowerBound], encoding: .utf8) else {
                        return .reject(.invalidRequest, "headers are not valid UTF-8")
                    }
                    for line in head.components(separatedBy: "\r\n").dropFirst() {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            guard let cl = Int(value), cl >= 0 else {
                                return .reject(.invalidRequest, "invalid Content-Length")
                            }
                            expected = cl
                            break
                        }
                    }
                    if expected > maxBody {
                        return .reject(.payloadTooLarge, "request body exceeds \(maxBody / 1024) KiB")
                    }
                } else if buf.count > headerCap {
                    return .reject(.invalidRequest, "request headers too large")
                }
            }
            if let start = bodyStart, buf.count - start >= expected { break }
        }

        do { return .request(try HTTPParser.parse(buf)) }
        catch { return .reject(.invalidRequest, "malformed HTTP request") }
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
