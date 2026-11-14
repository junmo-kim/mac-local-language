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
            guard !a.isEmpty else { throw LangError(.invalidRequest, "q must not be an empty array") }
            guard a.count <= maxBatch else {
                throw LangError(.invalidRequest, "q has more than \(maxBatch) items")
            }
            for item in a {
                guard let s = item as? String else { throw LangError(.invalidRequest, "q items must be strings") }
                texts.append(s)
            }
        case nil:
            throw LangError(.invalidRequest, "missing required field: q")
        default:
            throw LangError(.invalidRequest, "q must be a string or an array of strings")
        }
        if texts.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw LangError(.invalidRequest, "q must not be empty")
        }

        let sourceRaw = try requiredString(fields, "source")
        let targetRaw = try requiredString(fields, "target")
        let source = sourceRaw == "auto" ? "auto" : try LanguageCode.normalize(sourceRaw)
        let target = try LanguageCode.normalize(targetRaw)

        if let f = fields["format"] {
            guard let s = f as? String, s == "text" else {
                throw LangError(.invalidRequest, "format must be \"text\"")
            }
        }

        var alternatives = 0
        if let a = fields["alternatives"] {
            alternatives = try parseAlternatives(a)
        }

        var strategy: StrategyOption?
        if let s = fields["strategy"] {
            guard let str = s as? String, let opt = StrategyOption(rawValue: str) else {
                throw LangError(.invalidRequest, "strategy must be high-fidelity or low-latency")
            }
            strategy = opt
        }

        return TranslateRequest(texts: texts, isBatch: isBatch, source: source, target: target,
                                alternatives: alternatives, strategy: strategy)
    }

    public static func decodeDetect(body: Data, contentType: String?) throws(LangError) -> String {
        let fields = try fields(body: body, contentType: contentType)
        guard let q = fields["q"] else { throw LangError(.invalidRequest, "missing required field: q") }
        guard let s = q as? String else { throw LangError(.invalidRequest, "q must be a string") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LangError(.invalidRequest, "q must not be empty")
        }
        return s
    }

    private static func requiredString(_ fields: [String: Any], _ key: String) throws(LangError) -> String {
        guard let v = fields[key] else { throw LangError(.invalidRequest, "missing required field: \(key)") }
        guard let s = v as? String, !s.isEmpty else {
            throw LangError(.invalidRequest, "\(key) must be a non-empty string")
        }
        return s
    }

    private static func parseAlternatives(_ v: Any) throws(LangError) -> Int {
        let bad = LangError(.invalidRequest, "alternatives must be an integer >= 0")
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
                throw LangError(.invalidRequest, "body is not valid UTF-8")
            }
            return parseForm(text)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else {
            throw LangError(.invalidRequest, "body must be a JSON object")
        }
        return dict
    }

    /// Raw form parsing (values stay strings; `QueryString.parse` would type them).
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

    public static func errorBody(message: String, code: ErrorCode) -> YAMLValue {
        .dict([("error", .string(message)), ("code", .string(code.rawValue))])
    }

    public static func health(version: String, pid: Int, session: String, engine: String,
                              label: String, executable: String) -> YAMLValue {
        .dict([("status", .string("ok")), ("version", .string(version)), ("pid", .int(pid)),
               ("session", .string(session)), ("engine", .string(engine)),
               ("label", .string(label)), ("executable", .string(executable))])
    }

    /// The one JSON rendering used for both HTTP bodies and CLI `--format json`.
    public static func jsonBody(_ value: YAMLValue) -> String {
        value.render(as: .json) + "\n"
    }
}
