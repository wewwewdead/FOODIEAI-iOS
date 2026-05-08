import SwiftUI

/// Brand colors. Each property reads from a Color Set in Assets.xcassets
/// keyed by the same name. Source of truth is DESIGN_SYSTEM.md §Color.
///
/// Phase 0 Q3: locked to light mode app-wide. Color Sets do not have a
/// dark variant — adding one would silently override and ship wrong colors.
extension Color {
    // MARK: - Brand
    static let brand           = Color("brand")            // #B8CA38
    static let brandActive     = Color("brandActive")      // #ACC300
    static let brandHover      = Color("brandHover")       // #A7AD78
    static let brandBright     = Color("brandBright")      // #E2F45D
    static let brandCream      = Color("brandCream")       // #F8FFC5
    static let brandCreamSoft  = Color("brandCreamSoft")   // #F7FFC4
    static let brandIvory      = Color("brandIvory")       // #FCFFF8

    // MARK: - Accent
    static let greenSave       = Color("greenSave")        // #006147
    static let greenCalorie    = Color("greenCalorie")     // #133900
    static let greenAnalysis   = Color("greenAnalysis")    // #313803
    static let oliveQuote      = Color("oliveQuote")       // #828B41
    static let oliveDrab       = Color("oliveDrab")        // #6B8E23
    static let orangeBadge     = Color("orangeBadge")      // #FF911C
    static let orangeCancel    = Color("orangeCancel")     // #CE4100
    static let redError        = Color("redError")         // #FF2727
    static let panelBenefits   = Color("panelBenefits")    // #ADD8E6
    static let panelDrawbacks  = Color("panelDrawbacks")   // #A9A9A9
    static let pinkGlow        = Color("pinkGlow")         // rgba(255,105,180,0.6)

    // MARK: - Neutrals
    static let textPrimary     = Color("textPrimary")      // #212120
    static let textBody        = Color("textBody")         // #242424
    static let textMeta        = Color("textMeta")         // #7D7D7D
    static let navBg           = Color("navBg")            // rgba(232,255,198,0.094)

    // MARK: - Component-scoped tokens
    /// 8pt inner border on AnalysisPanel — DESIGN_SYSTEM.md §HomePage.
    static let panelBorder     = Color("panelBorder")      // #FFF8F8
    /// Dashed-border stroke on the empty DashedDropZone — web `.form__upload--empty`.
    static let dropZoneStroke  = Color("dropZoneStroke")   // #999999
}

/// Catalog of all design tokens for ThemePreview rendering and any future
/// "show me every color" debug screen.
enum AppColorToken: String, CaseIterable, Identifiable {
    case brand, brandActive, brandHover, brandBright,
         brandCream, brandCreamSoft, brandIvory
    case greenSave, greenCalorie, greenAnalysis,
         oliveQuote, oliveDrab,
         orangeBadge, orangeCancel, redError,
         panelBenefits, panelDrawbacks, pinkGlow
    case textPrimary, textBody, textMeta, navBg

    var id: String { rawValue }
    var color: Color { Color(rawValue) }

    var hexLabel: String {
        switch self {
        case .brand:           "#B8CA38"
        case .brandActive:     "#ACC300"
        case .brandHover:      "#A7AD78"
        case .brandBright:     "#E2F45D"
        case .brandCream:      "#F8FFC5"
        case .brandCreamSoft:  "#F7FFC4"
        case .brandIvory:      "#FCFFF8"
        case .greenSave:       "#006147"
        case .greenCalorie:    "#133900"
        case .greenAnalysis:   "#313803"
        case .oliveQuote:      "#828B41"
        case .oliveDrab:       "#6B8E23"
        case .orangeBadge:     "#FF911C"
        case .orangeCancel:    "#CE4100"
        case .redError:        "#FF2727"
        case .panelBenefits:   "#ADD8E6"
        case .panelDrawbacks:  "#A9A9A9"
        case .pinkGlow:        "#FF69B4 @60%"
        case .textPrimary:     "#212120"
        case .textBody:        "#242424"
        case .textMeta:        "#7D7D7D"
        case .navBg:           "#E8FFC6 @9.4%"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case brand = "Brand", accent = "Accent", neutral = "Neutral"
        var id: String { rawValue }
        var members: [AppColorToken] {
            switch self {
            case .brand:
                [.brand, .brandActive, .brandHover, .brandBright,
                 .brandCream, .brandCreamSoft, .brandIvory]
            case .accent:
                [.greenSave, .greenCalorie, .greenAnalysis,
                 .oliveQuote, .oliveDrab,
                 .orangeBadge, .orangeCancel, .redError,
                 .panelBenefits, .panelDrawbacks, .pinkGlow]
            case .neutral:
                [.textPrimary, .textBody, .textMeta, .navBg]
            }
        }
    }
}
