import Testing
@testable import LangCore

@Suite("U-SESS / U-ROUTE session and routing")
struct RouteTests {
    @Test("U-SESS-1 only exactly Aqua is gui",
          arguments: [("Aqua", true), ("System", false), ("Background", false), ("StandardIO", false),
                      ("LoginWindow", false), ("", false), ("aqua", false), ("unknown", false)])
    func session(name: String, isGUI: Bool) {
        let kind = SessionKind.parse(managerName: name)
        #expect((kind == .gui) == isGUI)
        if !isGUI { #expect(kind == .nonGUI(name)) }
    }

    @Test("session display names")
    func names() {
        #expect(SessionKind.gui.name == "Aqua")
        #expect(SessionKind.nonGUI("System").name == "System")
    }

    @Test("U-ROUTE-1 all five rows of the route table")
    func table() {
        #expect(Route.resolve(requested: .local, session: .nonGUI("System"), engine: .apple) == .local)
        #expect(Route.resolve(requested: .local, session: .gui, engine: .mock) == .local)
        #expect(Route.resolve(requested: .server, session: .gui, engine: .apple) == .server)
        #expect(Route.resolve(requested: .server, session: .nonGUI("System"), engine: .mock) == .server)
        #expect(Route.resolve(requested: .auto, session: .nonGUI("System"), engine: .mock) == .local)
        #expect(Route.resolve(requested: .auto, session: .gui, engine: .mock) == .local)
        #expect(Route.resolve(requested: .auto, session: .gui, engine: .apple) == .local)
        #expect(Route.resolve(requested: .auto, session: .nonGUI("System"), engine: .apple) == .server)
    }

    @Test("route option parsing")
    func parsing() {
        #expect(RouteRequest(rawValue: "auto") == .auto)
        #expect(RouteRequest(rawValue: "server") == .server)
        #expect(RouteRequest(rawValue: "x") == nil)
        #expect(EngineKind(env: [:]) == .apple)
        #expect(EngineKind(env: ["MACLANG_ENGINE": "mock"]) == .mock)
        #expect(EngineKind(env: ["MACLANG_ENGINE": "apple"]) == .apple)
    }
}
