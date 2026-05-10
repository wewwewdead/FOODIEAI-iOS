import SwiftUI
import UIKit

/// Type scale per DESIGN_SYSTEM.md §Type scale.
///
/// IMPORTANT — family-name discrepancy with the design system:
///   The marketed Google Fonts name is "M PLUS Rounded 1c", but the .ttf's
///   internal Family Name (`name` table id 1) is the older form
///   "Rounded Mplus 1c" (lowercase "Mplus", no spaces). Each weight reports
///   itself as a separate family ("Rounded Mplus 1c Bold", etc.). At runtime,
///   `UIFont.fontNames(forFamilyName: "M PLUS Rounded 1c")` returns empty;
///   `UIFont.fontNames(forFamilyName: "Rounded Mplus 1c")` returns the 6
///   weights as expected.
///
///   Verified at Phase 2 launch:
///     [FontDebug] 'Rounded Mplus 1c': RoundedMplus1c-Regular,
///     RoundedMplus1c-Light, RoundedMplus1c-Medium, RoundedMplus1c-Bold,
///     RoundedMplus1c-ExtraBold, RoundedMplus1c-Black
///
///   Therefore we reference fonts by PostScript name throughout — see
///   `AppFont.PS` below — never by family name.
///
/// Two font families:
///   - "Rounded Mplus 1c" (6 static weights bundled).
///   - "Nunito" (variable font; we use 4 named instances:
///     Regular / SemiBold / Bold / ExtraBold).
///
/// `clamp()` typography from CSS is resolved once at launch by linearly
/// interpolating between min and max based on screen width.
enum AppFont {

    // MARK: - PostScript font names (single source of truth for Font.custom)
    enum PS {
        static let mplusLight     = "RoundedMplus1c-Light"
        static let mplusRegular   = "RoundedMplus1c-Regular"
        static let mplusMedium    = "RoundedMplus1c-Medium"
        static let mplusBold      = "RoundedMplus1c-Bold"
        static let mplusExtraBold = "RoundedMplus1c-ExtraBold"
        static let mplusBlack     = "RoundedMplus1c-Black"

        static let nunitoRegular   = "Nunito-Regular"
        static let nunitoSemiBold  = "Nunito-SemiBold"
        static let nunitoBold      = "Nunito-Bold"
        static let nunitoExtraBold = "Nunito-ExtraBold"
    }

    // MARK: - Token enum
    enum Style {
        // v1 tokens (kept; do not break existing call sites)
        case displayXL, displayLG, displayMD
        case bodyLG, foodName, kcal, nav, body, meta
        // Meta-size weight variants used by BouncingBadge.
        // Same 12pt as `meta`, different Nunito weight files.
        case metaSemiBold        // Nunito-SemiBold (600) — `.reminder` badge
        case metaExtraBold       // Nunito-ExtraBold (800) — `.free` badge
        // Pill button label — same 24pt as `bodyLG` but Nunito-ExtraBold (800)
        // per Phase 3 spec ("bodyLG, weight 800").
        case pillTitle

        // v2 tokens (Phase 14 redesign — REDESIGN_DESIGN_SYSTEM.md §Type scale).
        case heroNumber          // 88pt M PLUS Black, kern -3 — THE one number
        case display1            // 42pt M PLUS Bold, kern -1.2 — onboarding hero
        case display2            // 32pt Nunito ExtraBold, kern -0.8 — food name, date
        case title1              // 20pt Nunito ExtraBold, kern -0.3 — card titles
        case title2              // 17pt Nunito ExtraBold, kern -0.2 — pill button label
        case bodyV2              // 16pt Nunito Regular — v2 default body
        case bodyEmphasis        // 16pt Nunito SemiBold
        case chipNumber          // 20pt Nunito ExtraBold, kern -0.3 — macro chips
        case caption             // 13pt Nunito SemiBold
        case captionStrong       // 13pt Nunito ExtraBold
        case labelEyebrow        // 11pt Nunito ExtraBold, kern 2 — UPPERCASE eyebrow
    }

    // MARK: - Token-to-Font lookup
    static func font(_ style: Style) -> Font {
        switch style {
        case .displayXL:
            // CSS: clamp(3rem, 6vw, 5rem) ≈ 48–80pt, M PLUS weight 500
            .custom(PS.mplusMedium, size: clamped(min: 48, max: 80))
        case .displayLG:
            // CSS: clamp(2.5rem, 5vw, 4rem) ≈ 40–64pt, weight 800
            .custom(PS.mplusExtraBold, size: clamped(min: 40, max: 64))
        case .displayMD:
            // 2rem ≈ 32pt, weight 800
            .custom(PS.mplusExtraBold, size: 32)
        case .bodyLG:
            // 1.5rem ≈ 24pt, Nunito weight 600
            .custom(PS.nunitoSemiBold, size: 24)
        case .foodName:
            // 2.2rem desktop / 1.5rem mobile, Nunito weight 800.
            // iOS is mobile-first: 24pt with room to grow on iPad later.
            .custom(PS.nunitoExtraBold, size: 24)
        case .kcal:
            // ~28pt, Nunito weight 900 (mapped to ExtraBold — see weight(_:)).
            // Kerning is applied separately via Text.appFont(_:); Font alone
            // can't carry letter-spacing.
            .custom(PS.nunitoExtraBold, size: 28)
        case .nav:
            // 1.1rem ≈ 17.6pt, Nunito weight 700
            .custom(PS.nunitoBold, size: 17.6)
        case .body:
            // 1.125rem ≈ 18pt, Nunito weight 400
            .custom(PS.nunitoRegular, size: 18)
        case .meta:
            // 0.7–0.8rem ≈ 11–13pt, Nunito weight 700
            .custom(PS.nunitoBold, size: 12)
        case .metaSemiBold:
            .custom(PS.nunitoSemiBold, size: 12)
        case .metaExtraBold:
            .custom(PS.nunitoExtraBold, size: 12)
        case .pillTitle:
            // Same size as bodyLG (24pt) but Nunito-ExtraBold per Phase 3 spec.
            .custom(PS.nunitoExtraBold, size: 24)

        // v2 (Phase 14 redesign)
        case .heroNumber:
            .custom(PS.mplusBlack,      size: 88)
        case .display1:
            .custom(PS.mplusBold,       size: 42)
        case .display2:
            .custom(PS.nunitoExtraBold, size: 32)
        case .title1:
            .custom(PS.nunitoExtraBold, size: 20)
        case .title2:
            .custom(PS.nunitoExtraBold, size: 17)
        case .bodyV2:
            .custom(PS.nunitoRegular,   size: 16)
        case .bodyEmphasis:
            .custom(PS.nunitoSemiBold,  size: 16)
        case .chipNumber:
            .custom(PS.nunitoExtraBold, size: 20)
        case .caption:
            .custom(PS.nunitoSemiBold,  size: 13)
        case .captionStrong:
            .custom(PS.nunitoExtraBold, size: 13)
        case .labelEyebrow:
            .custom(PS.nunitoExtraBold, size: 11)
        }
    }

    /// Resolved point size for a given style, exposed so ThemePreview can
    /// label each sample with its computed pt.
    static func resolvedSize(_ style: Style) -> CGFloat {
        switch style {
        case .displayXL: clamped(min: 48, max: 80)
        case .displayLG: clamped(min: 40, max: 64)
        case .displayMD: 32
        case .bodyLG:    24
        case .foodName:  24
        case .kcal:      28
        case .nav:       17.6
        case .body:      18
        case .meta:      12
        case .metaSemiBold:  12
        case .metaExtraBold: 12
        case .pillTitle: 24
        // v2
        case .heroNumber:    88
        case .display1:      42
        case .display2:      32
        case .title1:        20
        case .title2:        17
        case .bodyV2:        16
        case .bodyEmphasis:  16
        case .chipNumber:    20
        case .caption:       13
        case .captionStrong: 13
        case .labelEyebrow:  11
        }
    }

    /// Letter-spacing baked into specific tokens.
    static func kerning(_ style: Style) -> CGFloat {
        switch style {
        case .kcal:         3
        // v2 (Phase 14)
        case .heroNumber:   -3
        case .display1:     -1.2
        case .display2:     -0.8
        case .title1:       -0.3
        case .title2:       -0.2
        case .chipNumber:   -0.3
        case .labelEyebrow: 2
        default:            0
        }
    }

    // MARK: - CSS weight mapping
    /// Maps the non-standard CSS weight values referenced in the design
    /// system note to the closest bundled SwiftUI weight.
    ///
    /// Mapping (all close-call cases erring toward what the visual spec
    /// describes):
    ///
    ///   200 → ultraLight   300 → light       400 → regular   500 → medium
    ///   600 → semibold     660 → semibold *  680 → semibold *
    ///   700 → bold         800 → heavy       850 → heavy *
    ///   900 → black        960 → black *
    ///
    /// (\*) 660/680 round down to .semibold (closer to 600 than 700, and
    /// the bundled 700 is a noticeably heavier stroke). 850 and 960 round
    /// to the next bundled weight. Documented per Phase 0 review.
    static func weight(_ cssWeight: Int) -> Font.Weight {
        switch cssWeight {
        case ..<250:     .ultraLight
        case 250..<350:  .light
        case 350..<450:  .regular
        case 450..<550:  .medium
        case 550..<700:  .semibold      // 660/680 land here
        case 700..<800:  .bold
        case 800..<875:  .heavy         // 850 lands here
        case 875...:     .black         // 900/960 land here
        default:         .regular
        }
    }

    // MARK: - clamp() resolution
    /// CSS `clamp(min, vw, max)` resolved once per process from the device
    /// screen width. Cached in `LaunchClamp` to avoid per-access work.
    private static func clamped(min: CGFloat, max: CGFloat) -> CGFloat {
        LaunchClamp.shared.clamp(min: min, max: max)
    }
}

/// Linearly interpolates clamp() values between min and max using the
/// device's screen width. Captured at first access.
private final class LaunchClamp {
    static let shared = LaunchClamp()
    /// Reference widths chosen to bracket the iPhone form factor:
    ///   - 320pt = original iPhone SE 1
    ///   - 430pt = iPhone 15/16/17 Pro Max
    /// Anything wider (iPad) clamps to max.
    private let widthAtMin: CGFloat = 320
    private let widthAtMax: CGFloat = 430
    private let resolvedWidth: CGFloat

    private init() {
        // Avoid main-thread access during init by using the windowless screen API.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen.bounds.width })
            .first {
            self.resolvedWidth = window
        } else {
            // Fallback for pre-scene access; iPhone 15 width.
            self.resolvedWidth = 393
        }
    }

    func clamp(min: CGFloat, max: CGFloat) -> CGFloat {
        let w = resolvedWidth
        if w <= widthAtMin { return min }
        if w >= widthAtMax { return max }
        let t = (w - widthAtMin) / (widthAtMax - widthAtMin)
        return min + t * (max - min)
    }
}

// MARK: - Text + appFont(_:)

extension Text {
    /// Applies font *and* per-token kerning. Use this in preference to
    /// `.font(AppFont.font(.kcal))` — only this helper carries letter-spacing.
    func appFont(_ style: AppFont.Style) -> Text {
        self.font(AppFont.font(style))
            .kerning(AppFont.kerning(style))
    }
}

// MARK: - Convenient enumerations for ThemePreview

extension AppFont.Style: CaseIterable, Identifiable {
    public var id: String { String(describing: self) }
    public static let allCases: [AppFont.Style] = [
        // v1
        .displayXL, .displayLG, .displayMD,
        .bodyLG, .foodName, .kcal, .nav, .body, .meta,
        .metaSemiBold, .metaExtraBold, .pillTitle,
        // v2
        .heroNumber, .display1, .display2,
        .title1, .title2,
        .bodyV2, .bodyEmphasis,
        .chipNumber, .caption, .captionStrong, .labelEyebrow
    ]
    public var label: String {
        switch self {
        case .displayXL:     "displayXL"
        case .displayLG:     "displayLG"
        case .displayMD:     "displayMD"
        case .bodyLG:        "bodyLG"
        case .foodName:      "foodName"
        case .kcal:          "kcal"
        case .nav:           "nav"
        case .body:          "body"
        case .meta:          "meta"
        case .metaSemiBold:  "metaSemiBold"
        case .metaExtraBold: "metaExtraBold"
        case .pillTitle:     "pillTitle"
        // v2
        case .heroNumber:    "heroNumber"
        case .display1:      "display1"
        case .display2:      "display2"
        case .title1:        "title1"
        case .title2:        "title2"
        case .bodyV2:        "bodyV2"
        case .bodyEmphasis:  "bodyEmphasis"
        case .chipNumber:    "chipNumber"
        case .caption:       "caption"
        case .captionStrong: "captionStrong"
        case .labelEyebrow:  "labelEyebrow"
        }
    }

    /// Phase 14: returns true for tokens introduced in the v2 redesign.
    /// Used by ThemePreview to bucket the type-scale samples.
    public var isV2: Bool {
        switch self {
        case .heroNumber, .display1, .display2,
             .title1, .title2,
             .bodyV2, .bodyEmphasis,
             .chipNumber, .caption, .captionStrong, .labelEyebrow:
            true
        default:
            false
        }
    }
}

// MARK: - v2 Text helpers (Phase 14)

extension Text {
    /// Phase 14: idiomatic eyebrow label rendering. Applies the
    /// `.labelEyebrow` style (font + 2pt kerning baked in via
    /// `AppFont.kerning`), then uppercases the rendered glyphs.
    /// `textCase(.uppercase)` returns `some View`, so callers chain
    /// foreground / padding modifiers on the eyebrow afterward.
    /// Use: `Text("CALORIES").eyebrow().foregroundStyle(.inkMute)`.
    func eyebrow() -> some View {
        self.appFont(.labelEyebrow)
            .textCase(.uppercase)
    }
}

/// Phase 14: tabular-numeral helper. Numbers in the redesign render with
/// `.monospacedDigit()` so digit columns don't dance during count-up
/// animations.
///
/// Usage:
///
///   Text.number(1247)             // → "1247" with monospacedDigit
///   Text.number(1247.0, formatter: AnimatedNumber.integerFormatter)
///                                  // → "1247" via the same formatter the
///                                  //   AnimatedNumber view uses
extension Text {
    /// Static factory for numeric Text with monospacedDigit applied.
    static func number(_ value: Double,
                       formatter: (Double) -> String = { v in
                           if v.isNaN || v.isInfinite { return "—" }
                           if v == v.rounded() { return "\(Int(v))" }
                           return String(format: "%.1f", v)
                       }) -> Text {
        Text(formatter(value)).monospacedDigit()
    }

    /// Static factory for integer Text with monospacedDigit applied.
    static func number(_ value: Int) -> Text {
        Text("\(value)").monospacedDigit()
    }
}
