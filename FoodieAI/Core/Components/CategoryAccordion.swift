import SwiftUI

/// Phase 14: a 56pt-tall row that taps to reveal its items inline below.
/// Replaces `AnalysisPanel` in revisit (saved-meal) contexts. The original
/// `AnalysisPanel` with the 200pt-tall framed card and live typewriter
/// stays intact for the ComponentGallery v1 section.
///
/// Layout matches mockup-2-result.svg lines 104–127:
///   [○ N]  Nutrients                    3   ›
///
/// The monogram badge is a 28×28 circle filled with the category-tinted
/// surface (`catNutrients` / `catBenefits` / `catDrawbacks`) and the
/// matching `*Ink` color for the single-letter glyph. Tap toggles
/// `isExpanded`; expansion reveals the items list below.
///
/// Phase 14 typewriter restore: when `typewriter: true`, items type out
/// one-at-a-time char-by-char on first expansion (20 ms/char per spec)
/// using `TypewriterController`. After typing completes the accordion
/// behaves normally — collapsing and re-expanding renders instantly.
/// `startDelay` lets the parent stagger this accordion against others.
struct CategoryAccordion: View {
    let kind: AnalysisPanel.Kind
    let title: String
    let items: [String]
    /// When true the accordion starts expanded. Useful for the Result
    /// screen's auto-expand-on-first-appear behavior.
    var startsExpanded: Bool = false
    /// When true, items reveal via the live typewriter on first expansion.
    /// Defaults to false so revisit contexts (saved-meal expansion) render
    /// instantly.
    var typewriter: Bool = false
    /// Seconds to wait after expansion before kicking off the typewriter.
    /// Used to stagger multiple accordions on the Result screen.
    var startDelay: Double = 0

    @State private var isExpanded: Bool = false
    @StateObject private var controller: TypewriterController
    @State private var didStart: Bool = false

    init(kind: AnalysisPanel.Kind,
         title: String,
         items: [String],
         startsExpanded: Bool = false,
         typewriter: Bool = false,
         startDelay: Double = 0) {
        self.kind = kind
        self.title = title
        self.items = items
        self.startsExpanded = startsExpanded
        self.typewriter = typewriter
        self.startDelay = startDelay
        self._controller = StateObject(wrappedValue: TypewriterController(items: items))
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.soft()
                    withAnimation(.appBouncy) {
                        isExpanded.toggle()
                    }
                }

            if isExpanded {
                expandedItems
                    .padding(.horizontal, AppSpacing.md + 2)
                    .padding(.top, 2)
                    .padding(.bottom, AppSpacing.md)
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")
        .onAppear {
            if startsExpanded { isExpanded = true }
            // Defer typewriter start until the accordion is actually
            // expanded — otherwise the items would type into a
            // collapsed (zero-height) container.
            if typewriter, isExpanded { startTypewriterIfNeeded() }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, typewriter { startTypewriterIfNeeded() }
        }
    }

    private var collapsedHeader: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(badgeFill)
                    .frame(width: 28, height: 28)
                Text(monogram)
                    .appFont(.captionStrong)
                    .foregroundStyle(badgeInk)
            }

            Text(title)
                .appFont(.title2)
                .foregroundStyle(Color.ink)

            Spacer(minLength: 0)

            Text.number(items.count)
                .appFont(.captionStrong)
                .foregroundStyle(Color.inkLight)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.inkLight)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, AppSpacing.md + 2)
        .padding(.vertical, AppSpacing.md)
        .frame(minHeight: 56)
    }

    private var expandedItems: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Circle()
                        .fill(badgeInk)
                        .frame(width: 4, height: 4)
                        .offset(y: 8)
                    Text(displayedItem(at: idx, original: item))
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 28 + AppSpacing.md) // align under the title
    }

    /// When typewriter is active, render the controller's progressive
    /// string for this index; otherwise render the original item.
    private func displayedItem(at index: Int, original: String) -> String {
        guard typewriter else { return original }
        if controller.displayedText.indices.contains(index) {
            return controller.displayedText[index]
        }
        return ""
    }

    private func startTypewriterIfNeeded() {
        guard !didStart else { return }
        didStart = true
        Task { @MainActor in
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }
            controller.start()
        }
    }

    // MARK: - Category styling

    private var monogram: String {
        switch kind {
        case .nutrients: "N"
        case .benefits:  "B"
        case .drawbacks: "D"
        }
    }

    private var badgeFill: Color {
        switch kind {
        case .nutrients: .catNutrients
        case .benefits:  .catBenefits
        case .drawbacks: .catDrawbacks
        }
    }

    private var badgeInk: Color {
        switch kind {
        case .nutrients: .catNutrientsInk
        case .benefits:  .catBenefitsInk
        case .drawbacks: .catDrawbacksInk
        }
    }
}

#if DEBUG
#Preview("CategoryAccordion — three categories") {
    VStack(spacing: AppSpacing.md) {
        CategoryAccordion(
            kind: .nutrients,
            title: "Nutrients",
            items: [
                "Calcium: bone health — score 70",
                "Lycopene: antioxidant",
                "Protein: muscle synthesis"
            ],
            startsExpanded: true
        )
        CategoryAccordion(
            kind: .benefits,
            title: "Benefits",
            items: [
                "Provides calcium for bone health",
                "Contains lycopene from tomato sauce",
                "Source of protein from cheese"
            ]
        )
        CategoryAccordion(
            kind: .drawbacks,
            title: "Drawbacks",
            items: [
                "High in refined carbs",
                "Sodium content can be elevated",
                "Consider whole-grain crust"
            ]
        )
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}

#Preview("CategoryAccordion — typewriter cascade") {
    VStack(spacing: AppSpacing.md) {
        CategoryAccordion(
            kind: .nutrients,
            title: "Nutrients",
            items: [
                "Calcium: bone health — score 70",
                "Lycopene: antioxidant",
                "Protein: muscle synthesis"
            ],
            startsExpanded: true,
            typewriter: true,
            startDelay: 0.3
        )
        CategoryAccordion(
            kind: .benefits,
            title: "Benefits",
            items: [
                "Provides calcium for bone health",
                "Contains lycopene from tomato sauce"
            ],
            startsExpanded: true,
            typewriter: true,
            startDelay: 2.5
        )
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
