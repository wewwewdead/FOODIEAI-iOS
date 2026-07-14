import SwiftUI
import UIKit

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The result-screen components: save-reward pill, repeat chip, Your Pattern card, and coach reaction bubble. Types are module-scoped so CaptureView still references them.

// MARK: - Save reward pill

/// Inline reward pill above the PrimaryButton. Visibility and copy are
/// keyed off `SaveRewardPhase` so the pill cannot claim success before
/// the meal actually lands:
///   - `.idle`   → hidden (covers `.ready` and `.saveFailed`)
///   - `.saving` → "Adding to today…", subtle progress dot, no stamp
///   - `.saved`  → "Added to today", checkmark stamps in + brand glow
///
/// Polish elements (saved only):
///   - checkmark glyph scale-stamps from 0.6 → 1.0
///   - one-shot brand glow expanding behind the checkmark
///   - soft success haptic when the phase transitions saving→saved so
///     the tactile beat lands with the visual
///
/// Reduce Motion path: opacity-only fade, no overshoot, no glow pulse.
/// No retained Tasks — animation is purely state-driven via
/// `.onChange(of: phase)`, so there's nothing to cancel on disappear.
struct SaveRewardPill: View {
    let phase: SaveRewardPhase

    @State private var stamped: Bool = false
    @State private var glow: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        phase != .idle
    }

    private var isSaved: Bool {
        phase == .saved
    }

    private var copyText: String {
        switch phase {
        case .idle, .saving: return "Adding to today…"
        case .saved:         return "Added to today"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Brand glow halo: only kicks in for `.saved`; while
                // `.saving` it stays at rest behind the icon and is
                // invisible (`glow` only animates after a saved
                // transition).
                Circle()
                    .fill(Color.brand.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .scaleEffect(glow ? 1.5 : 0.6)
                    .opacity(glow ? 0 : (isSaved ? 0.6 : 0))

                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.brandDeep)
                        .scaleEffect(stamped ? 1 : 0.6)
                        .transition(.opacity)
                } else {
                    // Saving: a quiet progress indicator. The dot
                    // gently pulses (handled by SwiftUI default
                    // ProgressView animation), no overshoot.
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.brandDeep)
                        .transition(.opacity)
                }
            }
            Text(copyText)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.brandSoft)
        )
        .overlay(
            Capsule().strokeBorder(Color.brand.opacity(0.45), lineWidth: 1)
        )
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.94)
        .animation(
            reduceMotion ? .appReduced : .motionReveal,
            value: isVisible
        )
        .animation(
            reduceMotion ? .appReduced : .motionBase,
            value: isSaved
        )
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .idle:
                stamped = false
                glow = false
            case .saving:
                // Reset stamp state in case we're transitioning
                // failed→retry→saving and the previous stamp was up.
                stamped = false
                glow = false
            case .saved:
                runStamp()
            }
        }
        .accessibilityHidden(!isVisible)
        .accessibilityLabel(copyText)
    }

    private func runStamp() {
        if reduceMotion {
            stamped = true
            return
        }
        withAnimation(.appStamp) { stamped = true }
        withAnimation(.easeOut(duration: 0.55)) { glow = true }
        // Tactile beat aligned with the visual stamp. `SavedConfirmationSheet`
        // still owns the larger `Haptics.success()` when its checkmark
        // lands — this `.soft` is the smaller pre-beat so the inline
        // pill doesn't change phases silently.
        Haptics.soft()
    }
}

// MARK: - Repeat chip

/// Small inline "you've had this before" chip with a subtle reveal:
/// fades in and lifts a few points on first appearance, then settles.
/// Reduce Motion drops the lift to a flat opacity fade. The chip itself
/// is keyed by its text so a count change (very rare during a single
/// view lifetime) replays the reveal cleanly rather than snapping.
struct RepeatChip: View {
    let text: String
    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .appFont(.captionStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.inkMute)
        .padding(.top, 2)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 4)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.45)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Your Pattern card

/// Multi-line card surfacing local pattern insights — never an
/// adjusted estimate. Each row is a bullet-style line describing how
/// this meal compares to the user's history; the underlying
/// `FoodPatternInsight` decides which lines exist. Card hides itself
/// entirely when no insight can be drawn (`hasAnyContent == false`),
/// so a first-time food never sees an empty stub.
///
/// Visual register: a soft brand-tinted card with a hairline border
/// and the "Your Pattern" section eyebrow rendered by the parent
/// (Zone 4b in `AnalysisResultView`). The card body owns:
///   - header row: similar-meal count + confidence dot
///   - bullet rows: user-average / typical-meal / repeated / mood
///
/// Tap target is non-interactive on purpose — pattern is enrichment;
/// it doesn't gate any new flow.
struct YourPatternCard: View {
    let insight: FoodPatternInsight

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var confidenceLabel: String { insight.confidence.label }

    /// Tone the confidence dot to match the label so the card stays
    /// honest about how much weight the user should place on it.
    private var confidenceDotColor: Color {
        switch insight.confidence {
        case .low:    return Color.inkLight
        case .medium: return Color.brand
        case .high:   return Color.brandDeep
        }
    }

    /// Mirror copy used by the header — pluralizes correctly for
    /// 1 vs. N priors. `similarMealCount` already excludes the
    /// current scan (we count before save).
    private var headerCopy: String {
        let n = insight.similarMealCount
        if n <= 1 { return "1 similar meal so far" }
        return "\(n) similar meals so far"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            header
            bulletLines
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.35), lineWidth: 1)
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 6)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.5)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCopy)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 12, weight: .bold))
            Text(headerCopy)
                .appFont(.captionStrong)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Circle()
                    .fill(confidenceDotColor)
                    .frame(width: 6, height: 6)
                Text(confidenceLabel)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .foregroundStyle(Color.brandDeep)
    }

    @ViewBuilder
    private var bulletLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = insight.comparisonToUserAverage?.copy {
                bullet(line)
            }
            if let line = insight.comparisonToTypicalMeal?.copy {
                bullet(line)
            }
            if let line = insight.repeatedFoodNote {
                bullet(line)
            }
            if let line = insight.moodNote {
                bullet(line)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.brand)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .appFont(.caption)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private var accessibilityCopy: String {
        var parts: [String] = ["Your pattern card, \(confidenceLabel) confidence", headerCopy]
        if let s = insight.comparisonToUserAverage?.copy { parts.append(s) }
        if let s = insight.comparisonToTypicalMeal?.copy { parts.append(s) }
        if let s = insight.repeatedFoodNote { parts.append(s) }
        if let s = insight.moodNote { parts.append(s) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Coach reaction bubble

/// Small inline reaction line under the editorial quote. Deterministic
/// off the coach name + analysis state — no per-render randomness, no
/// network, no new model field. Animation is opacity + a few points of
/// upward drift; Reduce Motion drops the drift.
struct CoachReactionBubble: View {
    let coach: String
    let analysis: GeminiAnalysis

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Match coach name into a small set of known characters. The
    /// server is free to send any string here; everything that doesn't
    /// match falls through to the neutral default.
    private enum Persona {
        case einstein, cleopatra, shakespeare, neutral
    }

    private var persona: Persona {
        let normalized = coach.lowercased()
        if normalized.contains("einstein") { return .einstein }
        if normalized.contains("cleopatra") { return .cleopatra }
        if normalized.contains("shakespeare") { return .shakespeare }
        return .neutral
    }

    /// One sentence, deterministic. Persona drives the voice; the
    /// "indulgent" branch only kicks in when there's something to
    /// note (>= 600 kcal or sugar > 25g), so light meals get the
    /// calmer line instead of an unearned warning.
    private var reactionText: String {
        let heavy = (analysis.calories ?? 0) >= 600
            || (analysis.sugar ?? 0) > 25
        switch persona {
        case .einstein:
            return heavy
                ? "Relatively rich, but the numbers still matter."
                : "Relatively reasonable, but the numbers still matter."
        case .cleopatra:
            return heavy
                ? "A royal feast. Keep your balance."
                : "A royal choice. Keep your balance."
        case .shakespeare:
            return heavy
                ? "A bold plate. Moderation enters stage left."
                : "A worthy plate, though moderation enters stage left."
        case .neutral:
            return "Nice log. Here's what this means for your day."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
                .padding(.top, 2)
            Text(reactionText)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft)
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 6)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.6)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(coach) reaction: \(reactionText)")
    }
}

/// Minimal flow layout for the uncertainty-aware name suggestion chips.
/// SwiftUI's HStack would clip on iPhone widths when alternatives are
/// long ("Ppyeo-haejangguk (pork bone soup)"); this wraps onto a second
/// row instead. iOS 17+ `Layout` protocol — no third-party dep.
struct NameSuggestionFlow: Layout {
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
