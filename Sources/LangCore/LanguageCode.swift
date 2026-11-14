import Foundation

public enum LanguageCode {
    private static let syntax = try! NSRegularExpression(pattern: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$")
    private static let aliases: [String: String] = ["zt": "zh-Hant"]

    /// Output form: `Locale.Language(identifier:).minimalIdentifier`.
    public static func canonical(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).minimalIdentifier
    }

    /// Input form: apply aliases, validate syntax, then canonicalize.
    /// Whether the language is actually supported is decided by the engine.
    public static func normalize(_ input: String, field: String? = nil) throws(LangError) -> String {
        let aliased = aliases[input.lowercased()] ?? input
        let range = NSRange(aliased.startIndex..., in: aliased)
        guard syntax.firstMatch(in: aliased, range: range) != nil else {
            throw LangError(.unsupportedLanguage, "invalid language code: \(input)",
                            fix: "use a language code like en, ko, ja, zh (Simplified), zh-TW (Traditional) or pt-PT; list the installed ones with `maclang languages --from <source>` (HTTP: GET /languages)",
                            field: field, received: input)
        }
        return canonical(aliased)
    }
}
