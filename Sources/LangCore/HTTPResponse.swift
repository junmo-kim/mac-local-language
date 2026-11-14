import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]  // lowercase keys
    public let body: Data
}

/// Parses a complete HTTP/1.x response read until EOF (requests use `Connection: close`).
public enum HTTPResponseParser {
    private static let sep = Data("\r\n\r\n".utf8)

    public static func parse(_ raw: Data) throws(HTTPParseError) -> HTTPResponse {
        guard let range = raw.range(of: sep) else { throw HTTPParseError.incomplete }
        guard let head = String(data: raw[raw.startIndex..<range.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed("non-UTF8 headers")
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]), (100...599).contains(status) else {
            throw HTTPParseError.malformed("invalid status line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            throw HTTPParseError.malformed("unsupported Transfer-Encoding")
        }
        let rest = Data(raw[range.upperBound...])
        if let cl = headers["content-length"], let n = Int(cl), n >= 0 {
            guard rest.count >= n else { throw HTTPParseError.incomplete }
            return HTTPResponse(status: status, headers: headers, body: Data(rest.prefix(n)))
        }
        return HTTPResponse(status: status, headers: headers, body: rest)
    }
}

public enum HTTPRequestBuilder {
    public static func build(method: String, path: String, host: String, body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }
}
