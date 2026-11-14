import Foundation

public enum StrategyOption: String, Sendable, CaseIterable {
    case highFidelity = "high-fidelity"
    case lowLatency = "low-latency"
}

public struct Detection: Sendable, Equatable {
    public let language: String
    /// NaturalLanguage probability, 0...1.
    public let probability: Double
    public init(language: String, probability: Double) {
        self.language = language
        self.probability = probability
    }
    /// From a wire confidence (0-100).
    public init(language: String, confidence: Double) {
        self.language = language
        self.probability = confidence / 100
    }
    /// Probability x 100 rounded to one decimal.
    public var confidence: Double { (probability * 1000).rounded() / 10 }
}

public struct LanguageEntry: Sendable, Equatable {
    public let code: String
    public let name: String
    public let targets: [String]
    public init(code: String, name: String, targets: [String]) {
        self.code = code
        self.name = name
        self.targets = targets
    }
}

public struct TranslateRequest: Sendable, Equatable {
    public var texts: [String]
    public var isBatch: Bool
    /// Canonical code or "auto".
    public var source: String
    public var target: String
    public var alternatives: Int
    public var strategy: StrategyOption?
}

public struct TranslateResult: Sendable, Equatable {
    public var text: String
    public var detected: Detection?
    public init(text: String, detected: Detection?) {
        self.text = text
        self.detected = detected
    }
}

/// LibreTranslate-compatible request decoding and response encoding. The HTTP 200 body and
/// `--format json` CLI output both come from `jsonBody`, so they are byte-identical.
public enum Wire {
    public static let maxBatch = 100

    // MARK: - request decoding

    public static func decodeTranslate(body: Data, contentType: String?) throws(LangError) -> TranslateRequest {
        let fields = try fields(body: body, contentType: contentType)

        var texts: [String] = []
        var isBatch = false
        switch fields["q"] {
        case let s as String:
            texts = [s]
        case let a as [Any]:
            isBatch = true
            guard !a.isEmpty else { throw LangError(.invalidRequest, "q must not be an empty array", field: "q", received: "[]") }
            guard a.count <= maxBatch else {
                throw LangError(.invalidRequest, "q has more than \(maxBatch) items", fix: "send at most \(maxBatch) strings per request and split larger batches", field: "q", received: "\(a.count) items")
            }
            for item in a {
                guard let s = item as? String else { throw LangError(.invalidRequest, "q items must be strings", fix: "make every item of q a string, e.g. {\"q\":[\"Hello\",\"Bye\"],\"source\":\"auto\",\"target\":\"ko\"}", field: "q") }
                texts.append(s)
            }
        case nil:
            throw LangError(.invalidRequest, "missing required field: q", fix: "add \"q\": {\"q\":\"Hello\",\"source\":\"auto\",\"target\":\"ko\"}", field: "q")
        default:
            throw LangError(.invalidRequest, "q must be a string or an array of strings", fix: "send q as \"Hello\" or [\"Hello\",\"Bye\"]", field: "q")
        }
        if texts.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw LangError(.invalidRequest, "q must not be empty", fix: "send non-blank text in q", field: "q")
        }

        let sourceRaw = try requiredString(fields, "source")
        let targetRaw = try requiredString(fields, "target")
        let source = sourceRaw == "auto" ? "auto" : try LanguageCode.normalize(sourceRaw, field: "source")
        let target = try LanguageCode.normalize(targetRaw, field: "target")

        if let f = fields["format"] {
            guard let s = f as? String, s == "text" else {
                throw LangError(.invalidRequest, "format must be \"text\"", fix: "omit format or send \"format\":\"text\" (html is not supported)", field: "format", received: "\(f)")
            }
        }

        var alternatives = 0
        if let a = fields["alternatives"] {
            alternatives = try parseAlternatives(a)
        }

        var strategy: StrategyOption?
        if let s = fields["strategy"] {
            guard let str = s as? String, let opt = StrategyOption(rawValue: str) else {
                throw LangError(.invalidRequest, "strategy must be high-fidelity or low-latency", fix: "use \"strategy\":\"high-fidelity\" or \"low-latency\", or omit it", field: "strategy", received: "\(s)")
            }
            strategy = opt
        }

        return TranslateRequest(texts: texts, isBatch: isBatch, source: source, target: target,
                                alternatives: alternatives, strategy: strategy)
    }

    public static func decodeDetect(body: Data, contentType: String?) throws(LangError) -> String {
        let fields = try fields(body: body, contentType: contentType)
        guard let q = fields["q"] else { throw LangError(.invalidRequest, "missing required field: q", fix: "send {\"q\":\"Bonjour tout le monde\"}", field: "q") }
        guard let s = q as? String else { throw LangError(.invalidRequest, "q must be a string", fix: "send q as one string: {\"q\":\"Bonjour tout le monde\"}", field: "q") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LangError(.invalidRequest, "q must not be empty", fix: "send non-blank text in q", field: "q")
        }
        return s
    }

    private static func requiredString(_ fields: [String: Any], _ key: String) throws(LangError) -> String {
        guard let v = fields[key] else { throw LangError(.invalidRequest, "missing required field: \(key)", fix: "add \"\(key)\": {\"q\":\"Hello\",\"source\":\"auto\",\"target\":\"ko\"} (source may be auto)", field: key) }
        guard let s = v as? String, !s.isEmpty else {
            throw LangError(.invalidRequest, "\(key) must be a non-empty string", fix: "send a language code such as \"en\", \"ko\", \"zh-TW\"", field: key)
        }
        return s
    }

    private static func parseAlternatives(_ v: Any) throws(LangError) -> Int {
        let bad = LangError(.invalidRequest, "alternatives must be an integer >= 0", fix: "send \"alternatives\":0 (or a positive integer), or omit it", field: "alternatives", received: "\(v)")
        if let s = v as? String {
            guard let i = Int(s), i >= 0 else { throw bad }
            return i
        }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { throw bad }
            guard let i = Int(exactly: n), i >= 0 else { throw bad }
            return i
        }
        throw bad
    }

    private static func fields(body: Data, contentType: String?) throws(LangError) -> [String: Any] {
        if let ct = contentType?.lowercased(), ct.contains("application/x-www-form-urlencoded") {
            guard let text = String(data: body, encoding: .utf8) else {
                throw LangError(.invalidRequest, "body is not valid UTF-8", fix: "send the body as UTF-8 with Content-Type application/x-www-form-urlencoded or application/json")
            }
            return parseForm(text)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else {
            throw LangError(.invalidRequest, "body must be a JSON object", fix: "send a JSON object with Content-Type: application/json, e.g. {\"q\":\"Hello\",\"source\":\"auto\",\"target\":\"ko\"}, or a form body q=Hello&source=auto&target=ko")
        }
        return dict
    }

    /// Raw form parsing (values stay strings).
    public static func parseForm(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = QueryString.decode(String(kv[0]))
            guard !key.isEmpty else { continue }
            out[key] = QueryString.decode(kv.count > 1 ? String(kv[1]) : "")
        }
        return out
    }

    // MARK: - response encoding (deterministic key order)

    public static func translateResponse(_ results: [TranslateResult], batch: Bool, alternatives: Int) -> YAMLValue {
        var pairs: [(String, YAMLValue)] = []
        if batch {
            pairs.append(("translatedText", .array(results.map { .string($0.text) })))
        } else {
            pairs.append(("translatedText", .string(results.first?.text ?? "")))
        }
        if results.contains(where: { $0.detected != nil }) {
            if batch {
                pairs.append(("detectedLanguage", .array(results.map { detectionValue($0.detected) })))
            } else {
                pairs.append(("detectedLanguage", detectionValue(results.first?.detected)))
            }
        }
        if alternatives > 0 {
            pairs.append(("alternatives", batch ? .array(results.map { _ in .array([]) }) : .array([])))
        }
        return .dict(pairs)
    }

    private static func detectionValue(_ d: Detection?) -> YAMLValue {
        guard let d else { return .null }
        return .dict([("confidence", .double(d.confidence)), ("language", .string(d.language))])
    }

    public static func detect(_ detections: [Detection]) -> YAMLValue {
        .array(detections.map { detectionValue($0) })
    }

    public static func languages(_ entries: [LanguageEntry]) -> YAMLValue {
        .array(entries.map {
            .dict([("code", .string($0.code)), ("name", .string($0.name)),
                   ("targets", .array($0.targets.map { .string($0) }))])
        })
    }

    /// `{"error","code","fix"}` then `"field"`, `"received"` when present (fixed order).
    public static func errorBody(_ e: LangError) -> YAMLValue {
        var pairs: [(String, YAMLValue)] = [("error", .string(e.message)), ("code", .string(e.code.rawValue)),
                                            ("fix", .string(e.fix))]
        if let field = e.field { pairs.append(("field", .string(field))) }
        if let received = e.received { pairs.append(("received", .string(received))) }
        return .dict(pairs)
    }

    public static func health(version: String, pid: Int, session: String, engine: String,
                              label: String, executable: String) -> YAMLValue {
        .dict([("status", .string("ok")), ("version", .string(version)), ("pid", .int(pid)),
               ("session", .string(session)), ("engine", .string(engine)),
               ("label", .string(label)), ("executable", .string(executable))])
    }

    // MARK: - client-side decoding of server responses

    public struct DecodedTranslate: Sendable, Equatable {
        public var results: [TranslateResult]
        public var batch: Bool
        public var alternatives: Int
    }

    private static func object(_ data: Data) throws(LangError) -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`")
        }
        return obj
    }

    private static func detection(_ v: Any?) -> Detection? {
        guard let d = v as? [String: Any], let lang = d["language"] as? String,
              let conf = (d["confidence"] as? NSNumber)?.doubleValue else { return nil }
        return Detection(language: lang, confidence: conf)
    }

    public static func decodeTranslateResponse(_ data: Data) throws(LangError) -> DecodedTranslate {
        guard let dict = try object(data) as? [String: Any] else {
            throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`")
        }
        let alternatives = dict["alternatives"] == nil ? 0 : 1
        if let texts = dict["translatedText"] as? [Any] {
            let strings = texts.compactMap { $0 as? String }
            guard strings.count == texts.count else { throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`") }
            let detected = dict["detectedLanguage"] as? [Any]
            let results = strings.enumerated().map { i, s in
                TranslateResult(text: s, detected: detected.flatMap { i < $0.count ? detection($0[i]) : nil })
            }
            return DecodedTranslate(results: results, batch: true, alternatives: alternatives)
        }
        guard let text = dict["translatedText"] as? String else {
            throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`")
        }
        return DecodedTranslate(results: [TranslateResult(text: text, detected: detection(dict["detectedLanguage"]))],
                                batch: false, alternatives: alternatives)
    }

    public static func decodeLanguages(_ data: Data) throws(LangError) -> [LanguageEntry] {
        guard let arr = try object(data) as? [[String: Any]] else {
            throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`")
        }
        return try arr.map { (row: [String: Any]) throws(LangError) -> LanguageEntry in
            guard let code = row["code"] as? String, let name = row["name"] as? String,
                  let targets = row["targets"] as? [String] else {
                throw LangError(.internalError, "malformed server response", fix: "the server answered with an unexpected body; compare `maclang --version` with the server version (`maclang service status`) and restart it with `maclang service stop && maclang service start`")
            }
            return LanguageEntry(code: code, name: name, targets: targets)
        }
    }

    public struct DecodedError: Sendable, Equatable {
        public var message: String
        public var code: String?
        public var fix: String?
        public var field: String?
        public var received: String?
    }

    /// `{"error","code","fix"[,"field","received"]}`; a body that is not that shape yields a generic
    /// message and nil code.
    public static func decodeError(_ data: Data) -> DecodedError {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = dict["error"] as? String else {
            return DecodedError(message: "unexpected server response", code: nil, fix: nil, field: nil, received: nil)
        }
        return DecodedError(message: message, code: dict["code"] as? String, fix: dict["fix"] as? String,
                            field: dict["field"] as? String, received: dict["received"] as? String)
    }

    /// The one JSON rendering used for both HTTP bodies and CLI `--format json`.
    public static func jsonBody(_ value: YAMLValue) -> String {
        value.render(as: .json) + "\n"
    }
}
