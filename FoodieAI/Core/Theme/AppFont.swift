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
        case displayXL, displayLG, displayMD
        case bodyLG, foodName, kcal, nav, body, meta
        // Meta-size weight variants used by BouncingBadge.
        // Same 12pt as `meta`, different Nunito weight files.
        case metaSemiBold        // Nunito-SemiBold (600) — `.reminder` badge
        case metaExtraBold       // Nunito-ExtraBold (800) — `.free` badge
        // Pill button label — same 24pt as `bodyLG` but Nunito-ExtraBold (800)
        // per Phase 3 spec ("bodyLG, weight 800").
        case pillTitle
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
        }
    }

    /// Letter-spacing baked into specific tokens (kcal only, per spec).
    static func kerning(_ style: Style) -> CGFloat {
        switch style {
        case .kcal: 3
        default:    0
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
        .displayXL, .displayLG, .displayMD,
        .bodyLG, .foodName, .kcal, .nav, .body, .meta,
        .metaSemiBold, .metaExtraBold, .pillTitle
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
        }
    }
}
