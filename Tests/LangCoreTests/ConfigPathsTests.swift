import Testing
import Foundation
@testable import LangCore

@Suite("U-CFG / U-PATH config and paths")
struct ConfigPathsTests {
    private let userHome = URL(fileURLWithPath: "/Users/tester")

    @Test("U-CFG-1 defaults")
    func defaults() throws {
        let c = try Config.parse(nil)
        #expect(c.host == "127.0.0.1")
        #expect(c.port == 9091)
        #expect(Config.default == c)
        #expect(c.render() == "{\"host\":\"127.0.0.1\",\"port\":9091}\n")
    }

    @Test("U-CFG-1 parse and partial files")
    func parseValues() throws {
        let c = try Config.parse(Data(#"{"host":"0.0.0.0","port":9100}"#.utf8))
        #expect(c == Config(host: "0.0.0.0", port: 9100))
        let partial = try Config.parse(Data(#"{"port":9200}"#.utf8))
        #expect(partial == Config(host: "127.0.0.1", port: 9200))
    }

    @Test("U-CFG-2 environment overrides use the injected dictionary")
    func envOverrides() {
        let d = Paths(env: [:], userHome: userHome)
        #expect(d.home.path == "/Users/tester/Library/Application Support/maclang")
        #expect(d.label == "kim.junmo.maclang")
        #expect(d.launchAgentsDir.path == "/Users/tester/Library/LaunchAgents")
        #expect(d.appBundle.path == "/Users/tester/Library/Application Support/maclang/MacLang.app")
        #expect(d.config.lastPathComponent == "config.json")
        #expect(d.serverLog.path.hasSuffix("maclang/logs/server.log"))
        #expect(d.bootstrapRequest.lastPathComponent == "bootstrap-request")
        #expect(d.bootstrapResult.lastPathComponent == "bootstrap-result")
        #expect(d.agentPlist.lastPathComponent == "kim.junmo.maclang.plist")
        #expect(d.bundleExecutable.path.hasSuffix("MacLang.app/Contents/MacOS/maclang"))

        let o = Paths(env: ["MACLANG_HOME": "/tmp/h", "MACLANG_LABEL": "x.y", "MACLANG_LAUNCH_AGENTS_DIR": "/tmp/a"],
                      userHome: userHome)
        #expect(o.home.path == "/tmp/h")
        #expect(o.label == "x.y")
        #expect(o.launchAgentsDir.path == "/tmp/a")
        #expect(o.agentPlist.path == "/tmp/a/x.y.plist")
        #expect(o.appBundle.path == "/tmp/h/MacLang.app")

        let empty = Paths(env: ["MACLANG_HOME": ""], userHome: userHome)
        #expect(empty.home.path.hasSuffix("Application Support/maclang"))
    }

    @Test("U-CFG-2 runtime env flags")
    func runtimeEnv() {
        #expect(RuntimeEnv(env: [:]).autostart)
        #expect(!RuntimeEnv(env: ["MACLANG_AUTOSTART": "0"]).autostart)
        #expect(RuntimeEnv(env: ["MACLANG_AUTOSTART": "1"]).autostart)
        #expect(RuntimeEnv(env: [:]).mockDelayMs == 0)
        #expect(RuntimeEnv(env: ["MACLANG_MOCK_DELAY_MS": "250"]).mockDelayMs == 250)
        #expect(RuntimeEnv(env: ["MACLANG_MOCK_DELAY_MS": "x"]).mockDelayMs == 0)
        #expect(RuntimeEnv(env: ["MACLANG_MOCK_DELAY_MS": "-5"]).mockDelayMs == 0)
        #expect(RuntimeEnv(env: ["MACLANG_ENGINE": "mock"]).engine == .mock)
    }

    @Test("U-CFG-3 broken config is invalid_config", arguments: [
        "{", "[]", "", #"{"port":"9091"}"#, #"{"port":0}"#, #"{"port":70000}"#, #"{"host":5}"#, #"{"host":""}"#,
    ])
    func broken(text: String) {
        do { _ = try Config.parse(Data(text.utf8)); Issue.record("expected failure for \(text)") }
        catch let e as LangError { #expect(e.code == .invalidConfig) }
        catch { Issue.record("wrong error") }
    }

    @Test("U-CFG-4 clientHost table")
    func clientHost() {
        #expect(Config(host: "0.0.0.0", port: 1).clientHost == "127.0.0.1")
        #expect(Config(host: "::", port: 1).clientHost == "127.0.0.1")
        #expect(Config(host: "localhost", port: 1).clientHost == "127.0.0.1")
        #expect(Config(host: "127.0.0.1", port: 1).clientHost == "127.0.0.1")
        #expect(Config(host: "10.0.0.5", port: 1).clientHost == "10.0.0.5")
    }

    @Test("U-PATH-1 app mode derives home from the bundle location")
    func appMode() {
        #expect(Paths.appModeHome(executablePath: "/x/MacLang.app/Contents/MacOS/maclang") == "/x")
        #expect(Paths.appModeHome(executablePath: "/Users/a b/Library/Application Support/maclang/MacLang.app/Contents/MacOS/maclang")
                == "/Users/a b/Library/Application Support/maclang")
        #expect(Paths.appModeHome(executablePath: "/usr/local/bin/maclang") == nil)
        #expect(Paths.appModeHome(executablePath: "/x/MacLang.app/Contents/Resources/maclang") == nil)
        let p = Paths(home: "/x", label: "kim.junmo.maclang.t", launchAgentsDir: "/la")
        #expect(p.home.path == "/x")
        #expect(p.label == "kim.junmo.maclang.t")
    }
}

@Suite("timeout-bounds timeout bounds")
struct TimeoutBoundsTests {
    @Test("accepts finite values in (0, 86400]", arguments: [0.001, 1, 60, 86400])
    func valid(v: Double) { #expect(TimeoutBounds.isValid(v)) }

    @Test("rejects zero, negatives, NaN, infinity and anything above a day",
          arguments: [0, -1, 86400.5, 86401, Double.nan, Double.infinity, -Double.infinity])
    func invalid(v: Double) { #expect(!TimeoutBounds.isValid(v)) }
}
