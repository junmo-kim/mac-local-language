import Foundation
import Darwin
import LangCore

enum ClientFailure: Error {
    /// Nothing accepted the connection (refused, unresolvable, or connect timed out).
    case unreachable
    /// Connected, but the deadline passed while sending or waiting for the response.
    case timeout
    /// The connection broke or the response was truncated/garbled.
    case dropped
}

/// The one HTTP/1.1 client: BSD sockets, `Connection: close`, read until EOF, hard deadline.
/// Used by doctor, the bind-failure probe, request forwarding and the service commands.
struct ServerClient: Sendable {
    let host: String
    let port: Int

    func request(method: String, path: String, body: Data?, timeout: TimeInterval) -> Result<HTTPResponse, ClientFailure> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return .failure(.unreachable) }
        defer { freeaddrinfo(res) }

        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        let payload = HTTPRequestBuilder.build(method: method, path: path, host: host, body: body)
        var lastFailure = ClientFailure.unreachable
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            switch Self.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen, deadline) {
            case .ok: break
            case .timedOut: lastFailure = .unreachable; continue
            case .refused: continue
            }
            // A server may answer early and close (e.g. 413 before the whole body is sent), which makes
            // the send fail. Whatever response is already buffered is still worth reading.
            let sent = Self.sendAll(fd, [UInt8](payload), deadline)
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 16_384)
            while data.count < 16 * 1024 * 1024 {
                guard Self.wait(fd, POLLIN, deadline) else { return .failure(.timeout) }
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            do { return .success(try HTTPResponseParser.parse(data)) }
            catch { return .failure(sent ? .dropped : (Date() >= deadline ? .timeout : .dropped)) }
        }
        return .failure(lastFailure)
    }

    /// `GET /health`, classified: maclang, nothing listening, or some other program.
    func probe(timeout: TimeInterval) -> HealthState {
        var outcome = probeOnce(timeout: timeout)
        if HealthClassifier.needsRetry(outcome) {
            Thread.sleep(forTimeInterval: 0.1)
            outcome = probeOnce(timeout: timeout)
        }
        return HealthClassifier.classify(outcome)
    }

    private func probeOnce(timeout: TimeInterval) -> ProbeOutcome {
        switch request(method: "GET", path: "/health", body: nil, timeout: timeout) {
        case .success(let r): return .response(status: r.status, body: r.body)
        case .failure(.unreachable): return .refused
        case .failure(.timeout): return .timedOutAfterConnect
        case .failure(.dropped): return .dropped
        }
    }

    /// Non-nil only for a maclang server.
    func health(timeout: TimeInterval) -> HealthInfo? { probe(timeout: timeout).info }

    // MARK: socket helpers

    private enum ConnectResult { case ok, timedOut, refused }

    private static func remaining(_ deadline: Date) -> Int32 {
        Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSinceNow * 1000)))
    }

    private static func wait(_ fd: Int32, _ events: Int32, _ deadline: Date) -> Bool {
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let r = poll(&p, 1, remaining(deadline))
        return r > 0 && (p.revents & Int16(events | POLLHUP | POLLERR)) != 0
    }

    private static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t, _ deadline: Date) -> ConnectResult {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, addr, len) == 0 { return .ok }
        guard errno == EINPROGRESS else { return .refused }
        guard wait(fd, POLLOUT, deadline) else { return .timedOut }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
        return err == 0 ? .ok : .refused
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8], _ deadline: Date) -> Bool {
        var sent = 0
        while sent < bytes.count {
            guard wait(fd, POLLOUT, deadline) else { return false }
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
