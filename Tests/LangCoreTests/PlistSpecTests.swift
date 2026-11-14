import Testing
import Foundation
@testable import LangCore

private func roundTrip(_ data: Data) throws -> [String: Any] {
    try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Suite("U-PLIST / U-PRINT / U-VER")
struct PlistSpecTests {
    @Test("U-PLIST-1 Info.plist round trip")
    func infoPlist() throws {
        let d = try roundTrip(BundleSpec.infoPlist(label: "kim.junmo.maclang", version: "0.1.0"))
        #expect(d["CFBundleIdentifier"] as? String == "kim.junmo.maclang")
        #expect(d["CFBundleExecutable"] as? String == "maclang")
        #expect(d["CFBundlePackageType"] as? String == "APPL")
        #expect(d["LSUIElement"] as? Bool == true)
        #expect(d["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(d["CFBundleShortVersionString"] as? String == "0.1.0")
        #expect(d["CFBundleVersion"] as? String == "0.1.0")
        #expect(d.count == 7)
        let e = try roundTrip(BundleSpec.infoPlist(label: "x.e2e", version: "9.9.9"))
        #expect(e["CFBundleIdentifier"] as? String == "x.e2e")
        #expect(e["CFBundleShortVersionString"] as? String == "9.9.9")
    }

    @Test("U-PLIST-2 agent plist has exactly the eight fixed keys")
    func agentPlist() throws {
        let paths = Paths(home: "/h", label: "kim.junmo.maclang", launchAgentsDir: "/la")
        let d = try roundTrip(AgentSpec.plist(paths: paths))
        #expect(Set(d.keys) == ["Label", "ProgramArguments", "LimitLoadToSessionType", "RunAtLoad", "KeepAlive",
                                "ThrottleInterval", "StandardOutPath", "StandardErrorPath"])
        #expect(d["Label"] as? String == "kim.junmo.maclang")
        #expect(d["ProgramArguments"] as? [String] == ["/h/MacLang.app/Contents/MacOS/maclang", "serve"])
        #expect(d["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(d["RunAtLoad"] as? Bool == true)
        let keepAlive = try #require(d["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
        #expect(keepAlive.count == 1)
        #expect(d["ThrottleInterval"] as? Int == 10)
        #expect(d["StandardOutPath"] as? String == "/h/logs/server.log")
        #expect(d["StandardErrorPath"] as? String == "/h/logs/server.log")
    }

    // Shape of `launchctl print gui/<uid>/<label>` (macOS 27.0.1): top-level attributes are
    // indented by one tab; nested blocks (endpoints etc.) use two or more and must be ignored.
    static let printRunning = """
    gui/501/kim.junmo.maclang.e2e = {
    \tactive count = 1
    \tpath = /tmp/a.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /tmp/MacLang.app/Contents/MacOS/maclang
    \targuments = {
    \t\t/tmp/MacLang.app/Contents/MacOS/maclang
    \t\tserve
    \t}

    \tdefault environment = {
    \t\tPATH => /usr/bin:/bin
    \t}

    \truns = 2
    \tpid = 4143
    \timmediate reason = inefficient
    \tlast exit code = 0

    \tendpoints = {
    \t\t"x" = {
    \t\t\tstate = active
    \t\t\tpid = 1
    \t\t}
    \t}
    }
    """

    static let printNeverExited = """
    gui/501/x = {
    \tstate = not running
    \tlast exit code = (never exited)
    }
    """

    @Test("U-PRINT-1 parsePrint reads only top-level state, pid and last exit code")
    func parsePrint() {
        let r = AgentSpec.parsePrint(Self.printRunning)
        #expect(r.state == "running")
        #expect(r.pid == 4143)
        #expect(r.lastExitCode == 0)
        #expect(r.program == "/tmp/MacLang.app/Contents/MacOS/maclang")

        let n = AgentSpec.parsePrint(Self.printNeverExited)
        #expect(n.state == "not running")
        #expect(n.pid == nil)
        #expect(n.lastExitCode == nil)
        #expect(n.program == nil)

        let empty = AgentSpec.parsePrint("Could not find service \"x\" in domain for user gui: 501")
        #expect(empty == AgentSpec.PrintInfo(state: nil, pid: nil, lastExitCode: nil))
    }

    @Test("U-VER-1 mismatch warning")
    func mismatch() {
        #expect(Version.mismatchWarning(server: "0.1.0", cli: "0.1.0") == nil)
        #expect(Version.mismatchWarning(server: "0.0.9", cli: "0.1.0")
                == "warning: server 0.0.9 differs from CLI 0.1.0; run 'maclang service stop && maclang service start'")
        #expect(Version.current == "0.1.0")
    }
}
