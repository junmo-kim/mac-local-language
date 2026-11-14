import Foundation
import NaturalLanguage
import LangCore

public enum NLDetector {
    /// Up to `max` language hypotheses, most probable first. Empty when nothing is detected.
    /// Codes are canonical; hypotheses that collapse onto the same canonical code keep the larger probability.
    public static func detect(_ text: String, max: Int = 3) -> [Detection] {
        guard max > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // Ask for a few extra so canonical-code merging cannot starve the result.
        let hypotheses = recognizer.languageHypotheses(withMaximum: max + 3)
        var merged: [String: Double] = [:]
        for (language, probability) in hypotheses where language != .undetermined && probability > 0 {
            let code = LanguageCode.canonical(language.rawValue)
            merged[code] = Swift.max(merged[code] ?? 0, probability)
        }
        return merged
            .map { Detection(language: $0.key, probability: $0.value) }
            .sorted { $0.probability != $1.probability ? $0.probability > $1.probability : $0.language < $1.language }
            .prefix(max)
            .map { $0 }
    }

    /// LibreTranslate parity for `source=auto`: text whose language cannot be detected is treated as
    /// English and reported with confidence 0.
    public static func detectOrFallback(_ text: String) -> Detection {
        detect(text, max: 1).first ?? Detection(language: "en", probability: 0)
    }
}
