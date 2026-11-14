import Foundation

public enum EngineKind: String, Sendable {
    case apple
    case mock

    /// `MACLANG_ENGINE=mock` selects the test engine; anything else is the Apple engine.
    public init(env: [String: String]) {
        self = env["MACLANG_ENGINE"] == "mock" ? .mock : .apple
    }
}

public enum RouteRequest: String, Sendable {
    case auto, local, server
}

public enum Route: Equatable, Sendable {
    case local
    case server

    public static func resolve(requested: RouteRequest, session: SessionKind, engine: EngineKind) -> Route {
        switch requested {
        case .local: return .local
        case .server: return .server
        case .auto:
            if engine == .mock { return .local }
            return session == .gui ? .local : .server
        }
    }
}
