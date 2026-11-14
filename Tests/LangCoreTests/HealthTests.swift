import Testing
import Foundation
@testable import LangCore

private func d(_ s: String) -> Data { Data(s.utf8) }

@Suite("U-HEALTH three-way health classification")
struct HealthTests {
    static let ok = #"{"status":"ok","version":"0.1.0","pid":42,"session":"Aqua","engine":"mock","label":"x","executable":"/a/maclang"}"#

    @Test("a 200 with status ok is maclang")
    func maclang() {
        guard case .maclang(let info) = HealthClassifier.classify(.response(status: 200, body: d(Self.ok))) else {
            Issue.record("expected maclang"); return
        }
        #expect(info.version == "0.1.0" && info.pid == 42 && info.executable == "/a/maclang" && info.session == "Aqua")
    }

    @Test("nothing listening is unreachable")
    func unreachable() {
        #expect(HealthClassifier.classify(.refused) == .unreachable)
    }

    @Test("anything else that answers, hangs or garbles is foreign",
          arguments: [(404, "not found"), (200, "<html>"), (200, #"{"status":"degraded","version":"1"}"#),
                      (200, #"{"status":"ok"}"#), (500, Self.ok)])
    func foreign(status: Int, body: String) {
        #expect(HealthClassifier.classify(.response(status: status, body: d(body))) == .foreign)
    }

    @Test("a connection that hangs or drops after connecting is foreign")
    func hangs() {
        #expect(HealthClassifier.classify(.timedOutAfterConnect) == .foreign)
        #expect(HealthClassifier.classify(.dropped) == .foreign)
    }

    @Test("U-VER-2 mismatch advice")
    func advice() {
        #expect(Version.mismatchWarning(server: "0.0.9", cli: "0.1.0")
                == "warning: server 0.0.9 differs from CLI 0.1.0; run 'maclang service stop && maclang service start'")
    }
}
