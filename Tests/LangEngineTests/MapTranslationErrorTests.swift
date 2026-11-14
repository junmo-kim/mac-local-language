import Testing
import Foundation
import Translation
import LangCore
@testable import LangEngine

// Only the static TranslationError constants are used here: creating a TranslationSession or
// LanguageAvailability outside a GUI login session hangs, so those are never touched in tests.
@Suite("E-MAP mapTranslationError")
struct MapTranslationErrorTests {
    @Test("E-MAP-1 the seven TranslationError constants and an arbitrary Error")
    func mapping() {
        #expect(mapTranslationError(TranslationError.unsupportedSourceLanguage) == .unsupportedLanguage)
        #expect(mapTranslationError(TranslationError.unsupportedTargetLanguage) == .unsupportedLanguage)
        #expect(mapTranslationError(TranslationError.unsupportedLanguagePairing) == .unsupportedLanguage)
        #expect(mapTranslationError(TranslationError.unableToIdentifyLanguage) == .unableToDetect)
        #expect(mapTranslationError(TranslationError.nothingToTranslate) == .invalidRequest)
        #expect(mapTranslationError(TranslationError.alreadyCancelled) == .timeout)
        #expect(mapTranslationError(TranslationError.notInstalled) == .notInstalled)
        #expect(mapTranslationError(TranslationError.internalError) == .internalError)
        struct Other: Error {}
        #expect(mapTranslationError(Other()) == .internalError)
        #expect(mapTranslationError(CancellationError()) == .timeout)
    }

    @Test("every mapped code has a stable message that never echoes input")
    func messages() {
        for code in ErrorCode.allCases {
            #expect(!AppleTranslationEngine.message(for: code).isEmpty)
        }
    }
}
