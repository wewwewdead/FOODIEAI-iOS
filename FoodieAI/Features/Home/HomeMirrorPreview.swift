import Foundation

/// Structured payload for the Home Food Mirror preview card. Carries
/// the full LifeOS-style layout (eyebrow, title, body, evidence,
/// nudge, CTA) rather than a single sentence so the view layer can
/// render hierarchy without re-deriving anything from the summary.
///
/// `kind` distinguishes the two states the picker can return:
///   - `.learning(progress)` — fewer than 8 logs in the 30-day window.
///     The view renders a thin progress bar alongside the copy.
///   - `.ready` — normal insight surface. No progress bar.
///
/// All fields are pre-formatted display strings; the view does no
/// further composition.
struct HomeMirrorPreviewCardModel: Equatable {
    enum Kind: Equatable {
        case learning(LearningProgress)
        case ready
    }

    let eyebrow: String
    let title: String
    let body: String?
    let evidenceLine: String?
    let nudgeLine: String?
    let ctaText: String
    let kind: Kind
}

/// Pure picker that maps a `FoodMirrorSummary` into the Home card
/// model. No dependencies, no side effects — the view model owns the
/// fetch + summary computation and this layer only chooses what to
/// surface.
///
/// Priority chain when `hasEnoughData == true`:
///   - **title**:        `eatingIdentity` → `thisWeekChanged` → `weeklySummary`
///   - **body**:         `moodInsight` → `timingInsight`
///   - **nudgeLine**:    `todaysGentleNudge` (separate slot, no longer
///                       competes with the title)
///   - **evidenceLine**: derived from `thirtyDayLogCount` so the card
///                       can honestly state the basis ("30 days of logs"
///                       vs "your recent meals")
///   - **ctaText**:      "Open Mirror →"
///
/// Learning state copy is fixed per spec — the only variable piece is
/// the "X of 8 meals logged" evidence line.
///
/// Returns nil only when `hasEnoughData == true` AND no title source
/// is populated — a defensive case the view treats as "render nothing"
/// so the Home card never grows blank chrome over the scan flow.
enum HomeMirrorPreview {
    static let eyebrowCopy = "YOUR FOOD MIRROR"

    static func cardModel(for summary: FoodMirrorSummary) -> HomeMirrorPreviewCardModel? {
        if !summary.hasEnoughData {
            return HomeMirrorPreviewCardModel(
                eyebrow:      eyebrowCopy,
                title:        "Your mirror is learning you.",
                body:         "The picture sharpens as you log meals.",
                evidenceLine: summary.learningProgress.progressText,
                nudgeLine:    nil,
                ctaText:      "Keep logging →",
                kind:         .learning(summary.learningProgress)
            )
        }

        // Sharper-first title chain: when a single food is becoming
        // a regular ("anchor" framing kicks in at the storybuilder's
        // anchorFloor), surface that line over the older identity
        // copy. The eatingIdentity helper now produces nuanced
        // sentences too, but a top-food anchor reads tighter on
        // Home where space is scarce.
        let anchorTitle = FoodOSStoryBuilder.homePreviewAnchorTitle(
            topFoods: summary.mostCommonFoods
        )
        let title: String
        if let anchor = anchorTitle {
            title = anchor
        } else if let identity = summary.eatingIdentity {
            title = identity
        } else if let changed = summary.thisWeekChanged {
            title = changed
        } else if let weekly = summary.weeklySummary {
            title = weekly
        } else {
            return nil
        }

        let body = summary.moodInsight ?? summary.timingInsight

        // When the anchor copy fires, prefer the sharper
        // "6 logs · recent mood notes steady" footer. The default
        // evidence line still applies everywhere else so the legacy
        // "Based on 30 days of logs" surface is preserved.
        let evidence: String = {
            if anchorTitle != nil,
               let sharper = FoodOSStoryBuilder.homePreviewAnchorEvidence(
                   topFood:      summary.mostCommonFoods.first,
                   moodLogCount: summary.moodLogCount
               ) {
                return "Based on " + sharper
            }
            return evidenceLine(for: summary)
        }()

        return HomeMirrorPreviewCardModel(
            eyebrow:      eyebrowCopy,
            title:        title,
            body:         body,
            evidenceLine: evidence,
            nudgeLine:    summary.todaysGentleNudge,
            ctaText:      "Open Mirror →",
            kind:         .ready
        )
    }

    /// At 20+ logs we can claim the longer 30-day window; below that
    /// we cite the actual count so the card doesn't overclaim. Floor
    /// hand-off to a generic line when the count would read oddly.
    private static func evidenceLine(for summary: FoodMirrorSummary) -> String {
        let count = summary.thirtyDayLogCount
        if count >= 20 { return "Based on 30 days of logs" }
        if count >= summary.learningProgress.target {
            let meals = count == 1 ? "meal" : "meals"
            return "Based on \(count) \(meals) logged"
        }
        return "Based on your recent meals"
    }
}
