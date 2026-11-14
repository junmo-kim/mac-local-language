import Foundation

public struct HealthInfo: Sendable, Equatable {
    public let status: String
    public let version: String
    public let pid: Int?
    public let session: String?
    public let engine: String?
    public let label: String?
    public let executable: String?
}

/// What answered on a host:port when asked for `GET /health`.
public enum HealthState: Sendable, Equatable {
    case maclang(HealthInfo)
    /// Nothing accepted the connection.
    case unreachable
    /// Something is listening but it is not a maclang server (wrong answer, hang or drop).
    case foreign

    public var info: HealthInfo? {
        if case .maclang(let i) = self { return i }
        return nil
    }

    /// Short name for doctor/status output.
    public var name: String {
        switch self {
        case .maclang: return "maclang"
        case .unreachable: return "unreachable"
        case .foreign: return "foreign"
        }
    }
}

public enum ProbeOutcome: Sendable {
    case response(status: Int, body: Data)
    case refused
    case timedOutAfterConnect
    case dropped
}

public enum HealthClassifier {
    /// A single drop or post-connect hang may be transient (a server mid-exit); probe once more before
    /// calling the listener foreign.
    public static func needsRetry(_ outcome: ProbeOutcome) -> Bool {
        switch outcome {
        case .dropped, .timedOutAfterConnect: return true
        case .refused, .response: return false
        }
    }

    public static func classify(_ outcome: ProbeOutcome) -> HealthState {
        switch outcome {
        case .refused: return .unreachable
        case .timedOutAfterConnect, .dropped: return .foreign
        case .response(let status, let body):
            guard status == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let st = obj["status"] as? String, st == "ok",
                  let version = obj["version"] as? String else { return .foreign }
            return .maclang(HealthInfo(status: st, version: version, pid: obj["pid"] as? Int,
                                       session: obj["session"] as? String, engine: obj["engine"] as? String,
                                       label: obj["label"] as? String, executable: obj["executable"] as? String))
        }
    }
}
