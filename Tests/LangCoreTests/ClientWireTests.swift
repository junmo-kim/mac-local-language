import Testing
import Foundation
@testable import LangCore

private func d(_ s: String) -> Data { Data(s.utf8) }

@Suite("U-HTTPR response parser, request builder, response decoding, bundle/bootstrap helpers")
struct ClientWireTests {
    @Test("U-HTTPR-1 parses status, headers and body")
    func parse() throws {
        let r = try HTTPResponseParser.parse(d("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"))
        #expect(r.status == 200)
        #expect(r.headers["content-type"] == "application/json")
        #expect(r.body == d("{}"))
    }

    @Test("U-HTTPR-2 body is trimmed to Content-Length; a short body is incomplete")
    func lengths() throws {
        let r = try HTTPResponseParser.parse(d("HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabcEXTRA"))
        #expect(r.status == 404)
        #expect(r.body == d("abc"))
        #expect(throws: HTTPParseError.incomplete) {
            try HTTPResponseParser.parse(d("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
        }
        // No Content-Length: everything until EOF is the body.
        let eof = try HTTPResponseParser.parse(d("HTTP/1.0 200 OK\r\n\r\nxyz"))
        #expect(eof.body == d("xyz"))
    }

    @Test("U-HTTPR-3 malformed input")
    func malformed() {
        #expect(throws: HTTPParseError.incomplete) { try HTTPResponseParser.parse(d("HTTP/1.1 200 OK\r\nContent-Le")) }
        #expect(throws: HTTPParseError.incomplete) { try HTTPResponseParser.parse(Data()) }
        #expect(throws: HTTPParseError.self) { try HTTPResponseParser.parse(d("garbage\r\n\r\n")) }
        #expect(throws: HTTPParseError.self) { try HTTPResponseParser.parse(d("HTTP/1.1 abc OK\r\n\r\n")) }
        #expect(throws: HTTPParseError.self) {
            try HTTPResponseParser.parse(d("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
        }
    }

    @Test("U-HTTPR-4 request builder")
    func builder() {
        let get = String(decoding: HTTPRequestBuilder.build(method: "GET", path: "/health", host: "127.0.0.1", body: nil), as: UTF8.self)
        #expect(get == "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        let post = String(decoding: HTTPRequestBuilder.build(method: "POST", path: "/translate", host: "h", body: d("{\"a\":1}")), as: UTF8.self)
        #expect(post == "POST /translate HTTP/1.1\r\nHost: h\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}")
    }

    @Test("U-WIRE-9 client-side decoding round trips the encoder, preserving key order")
    func decodeResponses() throws {
        let results = [TranslateResult(text: "안녕", detected: Detection(language: "ja", probability: 0.9876))]
        let body = Wire.jsonBody(Wire.translateResponse(results, batch: false, alternatives: 1))
        let decoded = try Wire.decodeTranslateResponse(Data(body.utf8))
        #expect(decoded.results.count == 1)
        #expect(decoded.batch == false)
        #expect(decoded.alternatives == 1)
        #expect(Wire.jsonBody(Wire.translateResponse(decoded.results, batch: decoded.batch, alternatives: decoded.alternatives)) == body)

        let batch = Wire.jsonBody(Wire.translateResponse(
            [TranslateResult(text: "a", detected: nil), TranslateResult(text: "b", detected: nil)], batch: true, alternatives: 0))
        let db = try Wire.decodeTranslateResponse(Data(batch.utf8))
        #expect(db.batch && db.results.map(\.text) == ["a", "b"])

        let langs = Wire.jsonBody(Wire.languages([LanguageEntry(code: "en", name: "English", targets: ["ko"])]))
        #expect(try Wire.decodeLanguages(Data(langs.utf8)) == [LanguageEntry(code: "en", name: "English", targets: ["ko"])])
        let err = Wire.decodeError(Data(Wire.jsonBody(Wire.errorBody(LangError(.timeout, "m"))).utf8))
        #expect(err.message == "m" && err.code == "timeout")
        #expect(Wire.decodeError(Data("nope".utf8)).code == nil)
    }

    @Test("U-BUNDLE-1 rebuild decision")
    func rebuild() {
        let s = BundleStamp(version: "0.1.0", label: "a.b", size: 100, mtime: 5)
        #expect(!BundleSpec.needsRebuild(bundleExists: true, stamp: s, expected: s, plistVersion: "0.1.0", plistLabel: "a.b"))
        #expect(BundleSpec.needsRebuild(bundleExists: false, stamp: s, expected: s, plistVersion: "0.1.0", plistLabel: "a.b"))
        #expect(BundleSpec.needsRebuild(bundleExists: true, stamp: nil, expected: s, plistVersion: "0.1.0", plistLabel: "a.b"))
        #expect(BundleSpec.needsRebuild(bundleExists: true, stamp: s, expected: s, plistVersion: "0.0.9", plistLabel: "a.b"))
        #expect(BundleSpec.needsRebuild(bundleExists: true, stamp: s, expected: s, plistVersion: "0.1.0", plistLabel: "x"))
        #expect(BundleSpec.needsRebuild(bundleExists: true, stamp: s, expected: BundleStamp(version: "0.1.0", label: "a.b", size: 101, mtime: 5), plistVersion: "0.1.0", plistLabel: "a.b"))
        #expect(BundleSpec.needsRebuild(bundleExists: true, stamp: s, expected: BundleStamp(version: "0.1.0", label: "a.b", size: 100, mtime: 6), plistVersion: "0.1.0", plistLabel: "a.b"))
        let round = BundleStamp.decode(s.encode())
        #expect(round == s)
        #expect(BundleStamp.decode(Data("x".utf8)) == nil)
    }

    @Test("U-BOOT-1 bootstrap result encoding")
    func bootstrap() throws {
        let data = AgentSpec.encodeBootstrapResult(exit: 5, output: "Bootstrap failed: \"x\"\n")
        let r = try #require(AgentSpec.decodeBootstrapResult(data))
        #expect(r.exit == 5 && r.output == "Bootstrap failed: \"x\"\n")
        #expect(AgentSpec.decodeBootstrapResult(Data("zzz".utf8)) == nil)
    }
}
