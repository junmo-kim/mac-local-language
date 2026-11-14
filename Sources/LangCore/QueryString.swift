// Adapted from mac-local-vision (MIT, same author).
import Foundation

/// Form-style (`application/x-www-form-urlencoded`) component decoding.
enum QueryString {
    /// Literal `+` means space, then percent-escapes resolve (so an encoded `%2B` survives as a
    /// literal plus).
    /// A malformed escape (`100%+off`) falls back to the plus-replaced text rather than the raw input.
    static func decode(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
