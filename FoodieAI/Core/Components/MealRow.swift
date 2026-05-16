import SwiftUI

/// @deprecated Phase 21.9 — replaced everywhere by `ExpandableMealCard`
/// (which composes `MealCard` + an inline expansion). Today, Day detail,
/// and Recap all use the new card. The only remaining references to this
/// type live in its own `#Preview` blocks below; safe to delete in a
/// follow-up cleanup once we're confident nothing dynamic still resolves
/// to it.
///
/// Shared expandable meal row used by Today, the Week day-detail sheet, and
/// the Month day-detail sheet. Phase 10 surfaces the saved analysis details
/// (coach speech bubble + nutrients/benefits/drawbacks panels) inline below
/// the row when expanded.
///
/// State is owned per-row (`@State private var isExpanded`), so each row's
/// expansion is independent — no shared coordinator. The expanded content
/// uses `.prefilled` AnalysisPanels (no typewriter); users saw the
/// typewriter once during the analyze flow.
///
/// If the saved meal carries no expandable content (no coach advice and all
/// three arrays empty), the chevron is hidden and the row is non-tappable
/// — Phase 10 Step 6, option (a).
struct MealRow: View {
    let log: FoodLog

    @State private var isExpanded: Bool = false
    @State private var imageURL: URL?
    @State private var failed: Bool = false
    /// Phase 12 addendum: drives the full-image-viewer fullScreenCover.
    @State private var showFullImage: Bool = false

    private static let imageService = FoodImageService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow

            if isExpanded {
                expandedContent
                    .padding(.top, AppSpacing.md)
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
        .task {
            await loadThumbnail()
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(hasExpandableContent ? (isExpanded ? "Tap row to collapse details" : "Tap row to expand details") : "")
        .fullScreenCover(isPresented: $showFullImage) {
            FullImageViewer(imagePath: log.imagePath ?? "")
        }
    }

    // MARK: - Collapsed row
    //
    // Phase 12 addendum: split the gesture surface into two distinct,
    // non-overlapping areas:
    //   - Thumbnail → opens FullImageViewer.
    //   - Text + chevron region → toggles row expansion.
    // The Button on the thumbnail wins on its own bounds; the
    // contentShape+onTapGesture on the right-hand region wins everywhere
    // else. There is no parent gesture eating either tap.

    private var collapsedRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            thumbnailButton

            HStack(alignment: .top, spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(log.foodName)
                        .appFont(.bodyLG)
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                    Text(metaLine)
                        .appFont(.meta)
                        .foregroundStyle(Color.textMeta)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasExpandableContent {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Color.textMeta)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 6)
                        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasExpandableContent else { return }
                Haptics.soft()
                withAnimation(.appReveal) {
                    isExpanded.toggle()
                }
            }
        }
    }

    /// Thumbnail wrapped in a Button so a tap on the image opens the
    /// full-screen viewer. Disabled (just renders the image) if the row
    /// has no usable `image_path` — defensively, since saved meals
    /// always have one.
    @ViewBuilder
    private var thumbnailButton: some View {
        let canViewFull = !(log.imagePath?.isEmpty ?? true)
        if canViewFull {
            Button {
                Haptics.tap()
                showFullImage = true
            } label: {
                thumbnailFrame
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full image")
        } else {
            thumbnailFrame
        }
    }

    /// The visual thumbnail frame (clipped, bordered). Used both inside
    /// the Button and as the non-tappable fallback.
    private var thumbnailFrame: some View {
        thumbnail
            .frame(width: 80, height: 80)
            .background(Color.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.panelBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // Phase 11: full macros line. Renders only the macros that exist
            // on the row — pre-Phase-11 meals (where protein/fat/fiber are
            // nil) silently omit those segments rather than show "0g".
            fullMacrosLine

            if let advice = log.coachAdvice, !advice.isEmpty {
                SpeechBubble(text: advice, coachName: log.coachName)
            }

            VStack(spacing: AppSpacing.xs) {
                if !log.nutrients.isEmpty {
                    AnalysisPanel(
                        kind: .nutrients,
                        title: "Nutrients",
                        items: log.nutrients,
                        startTyping: false,
                        mode: .prefilled
                    )
                }
                if !log.benefits.isEmpty {
                    AnalysisPanel(
                        kind: .benefits,
                        title: "Benefits",
                        items: log.benefits,
                        startTyping: false,
                        mode: .prefilled
                    )
                }
                if !log.drawbacks.isEmpty {
                    AnalysisPanel(
                        kind: .drawbacks,
                        title: "Drawbacks",
                        items: log.drawbacks,
                        startTyping: false,
                        mode: .prefilled
                    )
                }
            }
        }
    }

    /// Compact "{cal} cal · {carbs}g carbs · …" string. Skips any nil/missing
    /// value so pre-Phase-11 rows render only the macros they actually have.
    private var fullMacrosLine: some View {
        var parts: [String] = []
        parts.append("\(format(log.calories)) cal")
        parts.append("\(format(log.carbsG))g carbs")
        parts.append("\(format(log.sugarG))g sugar")
        if let p = log.proteinG { parts.append("\(format(p))g protein") }
        if let f = log.fatG     { parts.append("\(format(f))g fat") }
        if let fi = log.fiberG  { parts.append("\(format(fi))g fiber") }
        return Text(parts.joined(separator: " · "))
            .appFont(.meta)
            .foregroundStyle(Color.textBody)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Expand gating

    /// True if anything would actually appear in the expanded section.
    /// Phase 10 Step 6 option (a): hide the chevron and disable taps when
    /// there's nothing to reveal, rather than promising content with a
    /// "no additional details" placeholder.
    private var hasExpandableContent: Bool {
        if let advice = log.coachAdvice, !advice.isEmpty { return true }
        return !log.nutrients.isEmpty || !log.benefits.isEmpty || !log.drawbacks.isEmpty
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.bgSurface
            Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.textMeta.opacity(0.5))
        }
    }

    private func loadThumbnail() async {
        guard imageURL == nil, !failed else { return }
        // Phase 12: prefer the small thumbnail object; fall back to the main
        // image for pre-Phase-12 rows (where image_thumb_path is NULL).
        // The fallback is slightly wasteful (the main object is ~5–10× the
        // thumb's bytes) but harmless and tapers off as users save new meals.
        let path: String? = log.imageThumbPath ?? log.imagePath
        guard let path, !path.isEmpty else { return }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: path)
            await MainActor.run { self.imageURL = url }
        } catch {
            #if DEBUG
            NSLog("[FoodImage] sign failed for %@: %@", path, "\(error)")
            #endif
            await MainActor.run { self.failed = true }
        }
    }

    // MARK: - Meta line

    private var metaLine: String {
        let time = Self.timeFormatter.string(from: log.eatenAt)
        return "\(time) • \(format(log.calories)) cal • \(format(log.sugarG))g sugar • \(format(log.carbsG))g carbs"
    }

    /// Cached — `DateFormatter` allocation is expensive (CFCalendar +
    /// ICU bootstrap) and this row renders inside the Tracker scroll
    /// view, so a fresh allocation per row is pure waste.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()

    private func format(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

#if DEBUG
#Preview("MealRow — variants") {
    ScrollView {
        VStack(spacing: AppSpacing.lg) {
            // Collapsed (will show chevron because expandable content exists).
            MealRow(log: .preview(
                name: "Margherita pizza",
                benefits: ["Calcium for bone health", "Lycopene from tomato sauce"],
                drawbacks: ["High in refined carbs", "Sodium can be elevated"],
                nutrients: ["Calcium 200mg", "Protein 12g", "Sodium 700mg"],
                coachAdvice: "Pair this with a side salad to balance carbs and fiber.",
                coachName: "Albert Einstein"
            ))
            // Empty drawbacks — only nutrients + benefits should render expanded.
            MealRow(log: .preview(
                name: "Greek salad",
                benefits: ["Olive oil monounsaturated fats", "Feta calcium"],
                drawbacks: [],
                nutrients: ["Calcium 180mg", "Iron 2mg"],
                coachAdvice: "Beautiful balance — keep this one in rotation.",
                coachName: "Albert Einstein"
            ))
            // No coach advice; arrays still populated.
            MealRow(log: .preview(
                name: "Protein shake",
                benefits: ["High protein"],
                drawbacks: [],
                nutrients: ["Protein 30g"],
                coachAdvice: nil,
                coachName: nil
            ))
            // Nothing to expand → chevron hidden, row non-tappable.
            MealRow(log: .preview(
                name: "Mystery snack (sparse data)",
                benefits: [],
                drawbacks: [],
                nutrients: [],
                coachAdvice: nil,
                coachName: nil
            ))
        }
        .padding(AppSpacing.lg)
    }
    .background(Color.bgCanvas)
}

private extension FoodLog {
    static func preview(
        name: String,
        benefits: [String],
        drawbacks: [String],
        nutrients: [String],
        coachAdvice: String?,
        coachName: String?
    ) -> FoodLog {
        FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: 420,
            carbsG: 48,
            sugarG: 6,
            proteinG: 18,
            fatG: 12,
            fiberG: 3,
            benefits: benefits,
            drawbacks: drawbacks,
            nutrients: nutrients,
            coachName: coachName,
            coachAdvice: coachAdvice,
            eatenAt: Date(),
            createdAt: Date(),
            origin: .analyzed,
            sourceLogId: nil,
            mood: nil
        )
    }
}
#endif
