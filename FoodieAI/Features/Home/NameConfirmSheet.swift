import SwiftUI

/// Mandatory name-confirmation step inserted between `/analyze` and the
/// result. Gemini's self-reported `nameConfidence` is unreliable, so we
/// confirm the detected food name with the user on *every* scan before
/// trusting the macros.
///
/// "Looks right" accepts the first-pass analysis as-is — no network
/// call, no scan credit. "Not correct — fix it" reveals a text field
/// where the user types the real dish name; "Update analysis" re-runs
/// the analyzer with `corrected_food_name` (a server-side refinement —
/// also no scan credit). `nameAlternatives` render as one-tap quick-pick
/// chips that route straight through the correction path.
///
/// Dismissal is entirely state-driven: the parent presents on
/// `state.isConfirmingName` and dismisses on any other state, so this
/// view never calls `dismiss()`. Drag-to-dismiss defaults to "Looks
/// right" — a silent disappearance without an explicit choice is treated
/// as confirming the detected name (per `onDisappear` below).
struct NameConfirmSheet: View {
    let detectedName: String
    let nameAlternatives: [String]
    let onConfirm: () -> Void
    let onCorrect: (String) -> Void
    /// NOVEL_DIRECTIONS Idea 4 — a name recognized from a PAST meal's photo
    /// (Visual Food Memory). nil unless the opt-in read flag is on and a
    /// confident visual match was found. Offered as a one-tap chip; never
    /// auto-applied, so this stays a suggestion the user confirms.
    var visualSuggestion: String? = nil
    /// How many past meals matched this photo (the "you've had this N times"
    /// signal). 0 when unknown / read path off.
    var visualTimesSeen: Int = 0

    /// True once the user has taken an explicit action (confirm, chip
    /// pick, or typed correction). Gates the `onDisappear` default so a
    /// drag-to-dismiss after an explicit choice doesn't double-fire, and
    /// a drag-to-dismiss *without* a choice falls back to confirm.
    @State private var didAct = false

    /// Reveals the free-text correction field after "Not correct".
    @State private var isCorrecting = false
    @State private var typedName = ""
    @FocusState private var fieldFocused: Bool

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private var trimmedTyped: String {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSubmitTyped: Bool { !trimmedTyped.isEmpty }

    /// Dedupe alternatives + drop any that just re-assert the detected
    /// name (case-insensitive). Cap at 3 so the chip row stays calm.
    /// Mirrors `AnalysisResultView.uniqueAlternatives`.
    private var quickPicks: [String] {
        let currentKey = detectedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var seen: Set<String> = [currentKey]
        var out: [String] = []
        for raw in nameAlternatives {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                out.append(trimmed)
            }
        }
        return Array(out.prefix(3))
    }

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    header
                    detectedNameCard

                    if recognizedName != nil {
                        visualSuggestionSection
                    }

                    if !quickPicks.isEmpty {
                        quickPickSection
                    }

                    actions

                    if isCorrecting {
                        updateAnalysisButton
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .move(edge: .top))
                            )
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
        }
        .animation(
            reduceMotion ? .none : .appReveal,
            value: isCorrecting
        )
        .onDisappear {
            // State-driven dismissal: if the sheet went away without an
            // explicit action (drag-to-dismiss), default to confirming
            // the detected name. After an explicit action `didAct` is
            // already true, so this is a no-op and we never double-route.
            if !didAct { onConfirm() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Did we get it right?")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            Text("Confirm the dish so the calories and macros match what you actually ate.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
    }

    private var detectedNameCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(isCorrecting ? "EDIT THE NAME" : "WE SEE")
                .appFont(.caption)
                .foregroundStyle(Color.brandDeep)

            // The name box itself is the editor. Read mode shows the
            // detected name as text; entering correction swaps it in place
            // for a focused, pre-filled field — no separate input box
            // appears below.
            if isCorrecting {
                TextField("Type the dish name",
                          text: $typedName,
                          axis: .vertical)
                    .font(AppFont.font(.title1))
                    .foregroundStyle(Color.ink)
                    .tint(Color.brand)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .multilineTextAlignment(.leading)
                    .submitLabel(.done)
                    .autocorrectionDisabled(false)
                    .textInputAutocapitalization(.sentences)
                    .focused($fieldFocused)
                    .fixedSize(horizontal: false, vertical: true)
                    // Vertical-axis field inserts a newline on Return; catch
                    // it, strip it, and commit so Done matches the "Update
                    // analysis" button.
                    .onChange(of: typedName) { _, newValue in
                        guard newValue.contains("\n") else { return }
                        typedName = newValue
                            .replacingOccurrences(of: "\n", with: "")
                        if canSubmitTyped { commitCorrection(trimmedTyped) }
                    }
            } else {
                Text(detectedName)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(
                    Color.brand.opacity(isCorrecting ? 0.9 : 0.45),
                    lineWidth: isCorrecting ? 1.5 : 1
                )
        )
        .overlay {
            // Tap the name box in read mode to start editing in place.
            // Removed in edit mode so taps reach the field to reposition
            // the cursor.
            if !isCorrecting {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { beginCorrecting() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isCorrecting
                ? "Edit the dish name"
                : "Detected dish: \(detectedName). Double-tap to edit."
        )
    }

    /// The visual-memory suggestion, but only when it's a *different* name
    /// than the model already detected (otherwise "Looks right" covers it).
    private var recognizedName: String? {
        guard let raw = visualSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.caseInsensitiveCompare(detectedName) != .orderedSame else { return nil }
        return raw
    }

    /// One-tap "you've photographed this before" suggestion, sourced from the
    /// on-device Visual Food Memory. Routes through the same correction path as
    /// the quick picks, so accepting it re-analyzes with the recognized name.
    @ViewBuilder
    private var visualSuggestionSection: some View {
        if let name = recognizedName {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(visualTimesSeen >= 2
                     ? "You've photographed this \(visualTimesSeen) times"
                     : "You've photographed this before")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.inkMute)
                chip(label: name) { commitCorrection(name) }
            }
        }
    }

    /// One-tap quick picks from `nameAlternatives`. Each routes straight
    /// through the correction path so the user never has to type when
    /// the right answer is already on offer.
    private var quickPickSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Or did you mean…")
                .appFont(.captionStrong)
                .foregroundStyle(Color.inkMute)

            ChipFlow(spacing: 8, runSpacing: 8) {
                ForEach(quickPicks, id: \.self) { alt in
                    chip(label: alt) {
                        commitCorrection(alt)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: AppSpacing.sm) {
            PrimaryButton(title: "Looks right",
                          leadingSystemImage: "checkmark") {
                Haptics.tap()
                didAct = true
                onConfirm()
            }

            Button {
                if isCorrecting {
                    cancelCorrecting()
                } else {
                    beginCorrecting()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCorrecting ? "xmark" : "pencil")
                        .font(.system(size: 12, weight: .heavy))
                    Text(isCorrecting ? "Never mind" : "Not right? Fix it")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.inkMute)
                .padding(.vertical, AppSpacing.sm)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCorrecting
                    ? "Cancel correcting the name"
                    : "The detected name is not correct, type the right one"
            )
        }
    }

    /// Commit action shown while editing. The input itself lives in
    /// `detectedNameCard` now — this button just applies the edit and
    /// re-runs the analysis.
    private var updateAnalysisButton: some View {
        PrimaryButton(title: "Update analysis",
                      leadingSystemImage: "sparkles") {
            guard canSubmitTyped else { return }
            commitCorrection(trimmedTyped)
        }
        .disabled(!canSubmitTyped)
        .opacity(canSubmitTyped ? 1 : 0.5)
    }

    // MARK: - Actions

    /// Enter in-place editing: pre-fill the name box with the detected
    /// name so a correction is a quick edit (add/remove a word) rather
    /// than typing it from scratch, then focus the field.
    private func beginCorrecting() {
        Haptics.soft()
        typedName = detectedName
        isCorrecting = true
        // Let the reveal animation start before focusing so the keyboard
        // doesn't fight the field's move-in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            fieldFocused = true
        }
    }

    /// Leave editing without committing — the name box reverts to showing
    /// the detected name.
    private func cancelCorrecting() {
        Haptics.soft()
        fieldFocused = false
        isCorrecting = false
    }

    private func commitCorrection(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptics.tap()
        fieldFocused = false
        didAct = true
        // The field pre-fills with the detected name. If the user submits it
        // unchanged there's nothing to re-analyze — accept the first pass
        // instead of spending a round-trip on the same name.
        if trimmed.caseInsensitiveCompare(detectedName) == .orderedSame {
            onConfirm()
        } else {
            onCorrect(trimmed)
        }
    }

    private func chip(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .appFont(.captionStrong)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color.brandDeep)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.brandSoft)
                )
                .overlay(
                    Capsule().strokeBorder(Color.brand.opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use suggestion \(label)")
    }
}

// MARK: - Chip flow layout

/// Minimal wrapping layout for the quick-pick chips. Self-contained
/// because `AnalysisResultView`'s equivalent (`NameSuggestionFlow`) is
/// fileprivate to that file.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            let wouldFit = (rowWidth == 0)
                || (rowWidth + spacing + size.width <= maxWidth)
            if wouldFit {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            } else {
                totalHeight += rowHeight + runSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : totalWidth,
            height: totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview("NameConfirmSheet — with alternatives") {
    Color.bgCanvas
        .sheet(isPresented: .constant(true)) {
            NameConfirmSheet(
                detectedName: "Margherita Pizza",
                nameAlternatives: ["Cheese Flatbread", "Focaccia", "Margherita Pizza"],
                onConfirm: {},
                onCorrect: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
}

#Preview("NameConfirmSheet — no alternatives") {
    Color.bgCanvas
        .sheet(isPresented: .constant(true)) {
            NameConfirmSheet(
                detectedName: "this dish",
                nameAlternatives: [],
                onConfirm: {},
                onCorrect: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
}
#endif
