import Foundation

/// Sanitizes free-text input from TextFields that use the default
/// keyboard but must accept only numeric (or feet/inches) characters.
///
/// We switched physiology inputs off `.numberPad`/`.decimalPad` so the
/// user gets a Done/return key and so the ft/in field can accept `'`
/// and `"`. The trade-off is the system keyboard no longer prevents
/// non-numeric input, so each TextField filters its bound text inside
/// `.onChange`.
enum NumericFieldFilter {
    /// Digits only.
    static func integer(_ input: String) -> String {
        input.filter { $0.isASCII && $0.isNumber }
    }

    /// Digits plus at most one decimal separator. Accepts both `.` and
    /// `,` as input (some locales) but normalizes to `.` for parsing.
    static func decimal(_ input: String) -> String {
        var result = ""
        var sawSeparator = false
        for ch in input {
            if ch.isASCII && ch.isNumber {
                result.append(ch)
            } else if (ch == "." || ch == ",") && !sawSeparator {
                result.append(".")
                sawSeparator = true
            }
        }
        return result
    }

    /// Digits, single quote, double quote, and a single space. Covers
    /// the common ways users write heights: `5'9"`, `5'9`, `5 9`.
    /// iOS's smart-punctuation feature converts straight quotes to
    /// curly ones (`'` → `’`, `"` → `”`) automatically, so we accept
    /// both forms and normalize curly variants back to ASCII straight
    /// quotes so downstream parsing only has to handle one shape.
    static func feetInches(_ input: String) -> String {
        var result = ""
        var sawSpace = false
        for ch in input {
            if ch.isASCII && ch.isNumber {
                result.append(ch)
            } else if ch == "'" || ch == "\u{2018}" || ch == "\u{2019}" {
                result.append("'")
            } else if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" {
                result.append("\"")
            } else if ch == " " && !sawSpace {
                result.append(ch)
                sawSpace = true
            }
        }
        return result
    }
}
