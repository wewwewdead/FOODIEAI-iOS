import SwiftUI

/// Brand colors. Each property reads from a Color Set in Assets.xcassets
/// keyed by the same name. Source of truth is REDESIGN_DESIGN_SYSTEM.md
/// (Phase 14) for v2 tokens; DESIGN_SYSTEM.md (Phase 0) for v1 tokens.
///
/// Phase 0 Q3: locked to light mode app-wide. Color Sets do not have a
/// dark variant — adding one would silently override and ship wrong colors.
extension Color {

    // MARK: - v2 (Phase 14 redesign)

    // Canvas & surfaces
    static let bgCanvas        = Color("bgCanvas")         // #FAFAF6
    static let bgSurface       = Color("bgSurface")        // #FFFFFF
    static let bgSurfaceSoft   = Color("bgSurfaceSoft")    // #F4F2EC
    static let borderHairline  = Color("borderHairline")   // #ECEAE2

    // Ink (text)
    static let ink             = Color("ink")              // #181715
    static let inkMute         = Color("inkMute")          // #6B6862
    static let inkLight        = Color("inkLight")         // #A8A59E

    // Brand (brand itself is reused from v1)
    static let brandDeep       = Color("brandDeep")        // #4A5713
    static let brandSoft       = Color("brandSoft")        // #F4F8DD

    // Semantic accents
    static let accentWarm      = Color("accentWarm")       // #E27B2C
    static let accentCool      = Color("accentCool")       // #5B7F8F
    static let success         = Color("success")          // #5C8333

    /// Phase 14 alias for the v1 `redError`. Both reference the same
    /// asset slot; new code should prefer `error`. Note: the asset
    /// `errorV2.colorset` carries the redesigned `#C83E3E` (slightly less
    /// saturated than the v1 `#FF2727`) — `error` reads from it.
    static let error           = Color("errorV2")          // #C83E3E

    // Category palette (replaces v1 panelBenefits/panelDrawbacks)
    static let catNutrients     = Color("catNutrients")     // #F4F8DD
    static let catNutrientsInk  = Color("catNutrientsInk")  // #4A5713
    static let catBenefits      = Color("catBenefits")      // #DFEBF1
    static let catBenefitsInk   = Color("catBenefitsInk")   // #3A5663
    static let catDrawbacks     = Color("catDrawbacks")     // #FBE7D9
    static let catDrawbacksInk  = Color("catDrawbacksInk")  // #A04A1C

    // MARK: - v1 (Phase 0)

    // MARK: Brand
    static let brand           = Color("brand")            // #B8CA38
    static let brandActive     = Color("brandActive")      // #ACC300
    static let brandHover      = Color("brandHover")       // #A7AD78
    static let brandBright     = Color("brandBright")      // #E2F45D

    /// @deprecated Phase 14: replaced by `bgCanvas`. Kept until call sites migrate.
    static let brandCream      = Color("brandCream")       // #F8FFC5
    /// @deprecated Phase 14: collapsed into `brandSoft`. Kept until call sites migrate.
    static let brandCreamSoft  = Color("brandCreamSoft")   // #F7FFC4
    /// @deprecated Phase 14: replaced by `bgSurface` (pure white). Kept until call sites migrate.
    static let brandIvory      = Color("brandIvory")       // #FCFFF8

    // MARK: Accent
    static let greenSave       = Color("greenSave")        // #006147
    static let greenCalorie    = Color("greenCalorie")     // #133900
    static let greenAnalysis   = Color("greenAnalysis")    // #313803
    /// @deprecated Phase 14: never carried weight; drop after migration.
    static let oliveQuote      = Color("oliveQuote")       // #828B41
    /// @deprecated Phase 14: never carried weight; drop after migration.
    static let oliveDrab       = Color("oliveDrab")        // #6B8E23
    static let orangeBadge     = Color("orangeBadge")      // #FF911C
    static let orangeCancel    = Color("orangeCancel")     // #CE4100
    static let redError        = Color("redError")         // #FF2727
    /// @deprecated Phase 14: blue panels read as Bootstrap; replaced by `catBenefits`.
    static let panelBenefits   = Color("panelBenefits")    // #ADD8E6
    /// @deprecated Phase 14: gray feels punitive; replaced by `catDrawbacks`.
    static let panelDrawbacks  = Color("panelDrawbacks")   // #A9A9A9
    /// @deprecated Phase 14: never carried weight; drop after migration.
    static let pinkGlow        = Color("pinkGlow")         // rgba(255,105,180,0.6)

    // MARK: Neutrals
    static let textPrimary     = Color("textPrimary")      // #212120
    static let textBody        = Color("textBody")         // #242424
    static let textMeta        = Color("textMeta")         // #7D7D7D
    static let navBg           = Color("navBg")            // rgba(232,255,198,0.094)

    // MARK: Component-scoped tokens
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

/// Phase 14 token catalog mirroring `AppColorToken` but for v2 tokens.
/// Used by ThemePreview's v2 section so the redesign can be diffed
/// visually against v1 in a single screen.
enum AppColorTokenV2: String, CaseIterable, Identifiable {
    case bgCanvas, bgSurface, bgSurfaceSoft, borderHairline
    case ink, inkMute, inkLight
    case brand, brandDeep, brandSoft
    case accentWarm, accentCool, success, error
    case catNutrients, catNutrientsInk
    case catBenefits, catBenefitsInk
    case catDrawbacks, catDrawbacksInk

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .bgCanvas:        return .bgCanvas
        case .bgSurface:       return .bgSurface
        case .bgSurfaceSoft:   return .bgSurfaceSoft
        case .borderHairline:  return .borderHairline
        case .ink:             return .ink
        case .inkMute:         return .inkMute
        case .inkLight:        return .inkLight
        case .brand:           return .brand
        case .brandDeep:       return .brandDeep
        case .brandSoft:       return .brandSoft
        case .accentWarm:      return .accentWarm
        case .accentCool:      return .accentCool
        case .success:         return .success
        case .error:           return .error
        case .catNutrients:    return .catNutrients
        case .catNutrientsInk: return .catNutrientsInk
        case .catBenefits:     return .catBenefits
        case .catBenefitsInk:  return .catBenefitsInk
        case .catDrawbacks:    return .catDrawbacks
        case .catDrawbacksInk: return .catDrawbacksInk
        }
    }

    var hexLabel: String {
        switch self {
        case .bgCanvas:        "#FAFAF6"
        case .bgSurface:       "#FFFFFF"
        case .bgSurfaceSoft:   "#F4F2EC"
        case .borderHairline:  "#ECEAE2"
        case .ink:             "#181715"
        case .inkMute:         "#6B6862"
        case .inkLight:        "#A8A59E"
        case .brand:           "#B8CA38"
        case .brandDeep:       "#4A5713"
        case .brandSoft:       "#F4F8DD"
        case .accentWarm:      "#E27B2C"
        case .accentCool:      "#5B7F8F"
        case .success:         "#5C8333"
        case .error:           "#C83E3E"
        case .catNutrients:    "#F4F8DD"
        case .catNutrientsInk: "#4A5713"
        case .catBenefits:     "#DFEBF1"
        case .catBenefitsInk:  "#3A5663"
        case .catDrawbacks:    "#FBE7D9"
        case .catDrawbacksInk: "#A04A1C"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case canvas = "Canvas & surfaces"
        case ink = "Ink (text)"
        case brand = "Brand"
        case accent = "Semantic accents"
        case category = "Category palette"
        var id: String { rawValue }
        var members: [AppColorTokenV2] {
            switch self {
            case .canvas:   [.bgCanvas, .bgSurface, .bgSurfaceSoft, .borderHairline]
            case .ink:      [.ink, .inkMute, .inkLight]
            case .brand:    [.brand, .brandDeep, .brandSoft]
            case .accent:   [.accentWarm, .accentCool, .success, .error]
            case .category: [.catNutrients, .catNutrientsInk,
                             .catBenefits, .catBenefitsInk,
                             .catDrawbacks, .catDrawbacksInk]
            }
        }
    }
}
