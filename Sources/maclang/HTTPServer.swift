// Adapted from mac-local-vision (MIT, same author).
import Foundation
import Darwin
import LangCore

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
