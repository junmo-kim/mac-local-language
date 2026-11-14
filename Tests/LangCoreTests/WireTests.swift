import Testing
import Foundation
@testable import LangCore

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite("U-WIRE LibreTranslate-compatible wire format")
struct WireTests {
    // MARK: request decode

    @Test("U-WIRE-1 JSON single, canonicalizes codes, defaults")
    func jsonSingle() throws {
        let r = try Wire.decodeTranslate(body: json(#"{"q":"hello","source":"en-US","target":"zh-Hant","api_key":"x"}"#),
                                         contentType: "application/json")
        #expect(r.texts == ["hello"])
        #expect(r.isBatch == false)
        #expect(r.source == "en")
        #expect(r.target == "zh-TW")
        #expect(r.alternatives == 0)
        #expect(r.strategy == nil)
    }

    @Test("U-WIRE-1 JSON batch, auto source, alternatives, strategy")
    func jsonBatch() throws {
        let r = try Wire.decodeTranslate(
            body: json(#"{"q":["a","b","c"],"source":"auto","target":"ko","format":"text","alternatives":3,"strategy":"low-latency"}"#),
            contentType: "application/json; charset=utf-8")
        #expect(r.texts == ["a", "b", "c"])
        #expect(r.isBatch)
        #expect(r.source == "auto")
        #expect(r.alternatives == 3)
        #expect(r.strategy == .lowLatency)
    }

    @Test("U-WIRE-1 form body, with percent and plus decoding")
    func form() throws {
        let r = try Wire.decodeTranslate(
            body: json("q=hello+w%C3%B6rld%2B1&source=en&target=ko&alternatives=2&strategy=high-fidelity"),
            contentType: "application/x-www-form-urlencoded")
        #expect(r.texts == ["hello wörld+1"])
        #expect(r.alternatives == 2)
        #expect(r.strategy == .highFidelity)
    }

    @Test("U-WIRE-1 form q that looks numeric stays text")
    func formNumericText() throws {
        let r = try Wire.decodeTranslate(body: json("q=007&source=en&target=ko"), contentType: "application/x-www-form-urlencoded")
        #expect(r.texts == ["007"])
    }

    private func code(_ body: String, _ ct: String = "application/json") -> ErrorCode? {
        do { _ = try Wire.decodeTranslate(body: json(body), contentType: ct); return nil }
        catch let e as LangError { return e.code } catch { return .internalError }
    }

    @Test("U-WIRE-2 missing or wrong-typed fields")
    func missing() {
        #expect(code(#"{"source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en"}"#) == .invalidRequest)
        #expect(code(#"{"q":"","source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":"  ","source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":[],"source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":[1],"source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code(#"{"q":5,"source":"en","target":"ko"}"#) == .invalidRequest)
        #expect(code("not json") == .invalidRequest)
        #expect(code("[1]") == .invalidRequest)
        #expect(code("") == .invalidRequest)
        #expect(code("q=x&source=en", "application/x-www-form-urlencoded") == .invalidRequest)
    }

    @Test("U-WIRE-3 format must be absent or text")
    func format() {
        #expect(code(#"{"q":"x","source":"en","target":"ko","format":"html"}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en","target":"ko","format":"text"}"#) == nil)
    }

    @Test("U-WIRE-4 batch limit is 100")
    func batchLimit() {
        let ok = "[" + (0..<100).map { "\"t\($0)\"" }.joined(separator: ",") + "]"
        let over = "[" + (0..<101).map { "\"t\($0)\"" }.joined(separator: ",") + "]"
        #expect(code(#"{"q":\#(ok),"source":"en","target":"ko"}"#) == nil)
        #expect(code(#"{"q":\#(over),"source":"en","target":"ko"}"#) == .invalidRequest)
    }

    @Test("U-WIRE-5 strategy, alternatives and language validation")
    func options() {
        #expect(code(#"{"q":"x","source":"en","target":"ko","strategy":"fast"}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en","target":"ko","alternatives":-1}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en","target":"ko","alternatives":1.5}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en","target":"ko","alternatives":true}"#) == .invalidRequest)
        #expect(code(#"{"q":"x","source":"en","target":"ko","alternatives":0}"#) == nil)
        #expect(code(#"{"q":"x","source":"en","target":"xx!"}"#) == .unsupportedLanguage)
        #expect(code(#"{"q":"x","source":"k","target":"ko"}"#) == .unsupportedLanguage)
        #expect(code(#"{"q":"x","source":"en","target":"auto"}"#) == .unsupportedLanguage)
        #expect(code("q=x&source=en&target=ko&alternatives=abc", "application/x-www-form-urlencoded") == .invalidRequest)
    }

    @Test("detect request needs a non-blank string q")
    func detectRequest() throws {
        #expect(try Wire.decodeDetect(body: json(#"{"q":"hola"}"#), contentType: "application/json") == "hola")
        #expect(try Wire.decodeDetect(body: json("q=hola"), contentType: "application/x-www-form-urlencoded") == "hola")
        #expect(throws: LangError.self) { try Wire.decodeDetect(body: json(#"{"q":["a"]}"#), contentType: nil) }
        #expect(throws: LangError.self) { try Wire.decodeDetect(body: json(#"{}"#), contentType: nil) }
    }

    // MARK: response encode

    @Test("U-WIRE-6 single response shapes")
    func singleResponse() {
        let plain = Wire.translateResponse([.init(text: "안녕", detected: nil)], batch: false, alternatives: 0)
        #expect(Wire.jsonBody(plain) == "{\"translatedText\":\"안녕\"}\n")

        let auto = Wire.translateResponse([.init(text: "x", detected: Detection(language: "en", probability: 0.9876))],
                                          batch: false, alternatives: 0)
        #expect(Wire.jsonBody(auto) == "{\"translatedText\":\"x\",\"detectedLanguage\":{\"confidence\":98.8,\"language\":\"en\"}}\n")

        let alt = Wire.translateResponse([.init(text: "x", detected: nil)], batch: false, alternatives: 2)
        #expect(Wire.jsonBody(alt) == "{\"translatedText\":\"x\",\"alternatives\":[]}\n")
    }

    @Test("U-WIRE-6 batch response shapes")
    func batchResponse() {
        let r = Wire.translateResponse(
            [.init(text: "a", detected: Detection(language: "ko", probability: 1)),
             .init(text: "b", detected: Detection(language: "ja", probability: 0.5))],
            batch: true, alternatives: 1)
        #expect(Wire.jsonBody(r) ==
            "{\"translatedText\":[\"a\",\"b\"],\"detectedLanguage\":[{\"confidence\":100,\"language\":\"ko\"},{\"confidence\":50,\"language\":\"ja\"}],\"alternatives\":[[],[]]}\n")
        let one = Wire.translateResponse([.init(text: "a", detected: nil)], batch: true, alternatives: 0)
        #expect(Wire.jsonBody(one) == "{\"translatedText\":[\"a\"]}\n")
    }

    @Test("U-WIRE-6 confidence rounds to one decimal")
    func confidence() {
        #expect(Detection(language: "en", probability: 0.9996).confidence == 100)
        #expect(Detection(language: "en", probability: 0.12345).confidence == 12.3)
        #expect(Detection(language: "en", probability: 0.8).confidence == 80)
    }

    @Test("U-WIRE-7 error body and escaping")
    func errorBody() {
        let v = Wire.errorBody(LangError(.invalidRequest, "bad \"q\"", fix: "do \"this\""))
        #expect(Wire.jsonBody(v) == "{\"error\":\"bad \\\"q\\\"\",\"code\":\"invalid_request\",\"fix\":\"do \\\"this\\\"\"}\n")
    }

    @Test("U-WIRE-7 error body key order: error, code, fix, then field and received when present")
    func errorBodyOrder() throws {
        let full = Wire.errorBody(LangError(.unsupportedLanguage, "m", fix: "f", field: "target", received: "xx"))
        #expect(Wire.jsonBody(full) == "{\"error\":\"m\",\"code\":\"unsupported_language\",\"fix\":\"f\",\"field\":\"target\",\"received\":\"xx\"}\n")
        let onlyField = Wire.errorBody(LangError(.notFound, "m", field: "path"))
        #expect(Wire.jsonBody(onlyField).hasPrefix("{\"error\":\"m\",\"code\":\"not_found\",\"fix\":"))
        #expect(Wire.jsonBody(onlyField).hasSuffix(",\"field\":\"path\"}\n"))
        // Without a specific fix the code's table entry is used.
        #expect(LangError(.timeout, "m").fix == ErrorCode.timeout.defaultFix)
        let decoded = Wire.decodeError(Data(Wire.jsonBody(full).utf8))
        #expect(decoded == Wire.DecodedError(message: "m", code: "unsupported_language", fix: "f", field: "target", received: "xx"))
    }

    @Test("U-WIRE-8 health, languages and detect")
    func misc() {
        let h = Wire.health(version: "0.1.0", pid: 42, session: "Aqua", engine: "apple-translation",
                            label: "kim.junmo.maclang", executable: "/x/maclang")
        #expect(Wire.jsonBody(h) == "{\"status\":\"ok\",\"version\":\"0.1.0\",\"pid\":42,\"session\":\"Aqua\",\"engine\":\"apple-translation\",\"label\":\"kim.junmo.maclang\",\"executable\":\"/x/maclang\"}\n")

        let l = Wire.languages([LanguageEntry(code: "en", name: "English", targets: ["ko", "ja"])])
        #expect(Wire.jsonBody(l) == "[{\"code\":\"en\",\"name\":\"English\",\"targets\":[\"ko\",\"ja\"]}]\n")

        let d = Wire.detect([Detection(language: "fr", probability: 0.97), Detection(language: "en", probability: 0.02)])
        #expect(Wire.jsonBody(d) == "[{\"confidence\":97,\"language\":\"fr\"},{\"confidence\":2,\"language\":\"en\"}]\n")
        #expect(Wire.jsonBody(Wire.detect([])) == "[]\n")
    }

    @Test("form-decoding form decoding falls back to the plus-replaced text when percent-decoding fails")
    func formDecodeFallback() throws {
        let r = try Wire.decodeTranslate(body: json("q=100%+off&source=en&target=ko"), contentType: "application/x-www-form-urlencoded")
        #expect(r.texts == ["100% off"])
        let ok = try Wire.decodeTranslate(body: json("q=a%2Bb+c&source=en&target=ko"), contentType: "application/x-www-form-urlencoded")
        #expect(ok.texts == ["a+b c"])
        let bad = try Wire.decodeTranslate(body: json("q=50%&source=en&target=ko"), contentType: "application/x-www-form-urlencoded")
        #expect(bad.texts == ["50%"])
    }

    @Test("undetected-source an undetected item reports en with confidence 0.0 per item")
    func zeroConfidence() {
        let r = Wire.translateResponse([.init(text: "x", detected: Detection(language: "en", probability: 0))], batch: false, alternatives: 0)
        #expect(Wire.jsonBody(r) == "{\"translatedText\":\"x\",\"detectedLanguage\":{\"confidence\":0,\"language\":\"en\"}}\n")
    }
}
