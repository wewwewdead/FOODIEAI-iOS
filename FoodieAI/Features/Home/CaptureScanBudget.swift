import SwiftUI
import UIKit

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The manual-log toast, the scan-counter chip, the scan-limits explainer sheet, and the reveal modifier used by it. Types are module-scoped so CaptureView still references them.

// MARK: - Manual log toast (Phase 21)

/// Lightweight banner shown after a successful manual save. Carries
/// two slots:
///   1. an optional quest-complete reward line (only when the save
///      just completed today's quest), and
///   2. a free-tier nudge ("Try a photo scan?" or "Upgrade for 5
///      photo scans/day", depending on `scansRemaining`).
///
/// The host owns dismissal so the action buttons can route tab
/// switches / scan starts cleanly — this modifier is just the
/// presentation envelope.
struct ManualLogToastModifier: ViewModifier {
    @Binding var toast: CaptureView.ManualLogToast?
    let onScanAction: () -> Void
    let onTrackerAction: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ManualLogToastView(
                        toast: toast,
                        onScanAction: onScanAction,
                        onTrackerAction: onTrackerAction
                    )
                    .padding(.bottom, 96)
                    .padding(.horizontal, AppSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        do {
                            try await Task.sleep(nanoseconds: 4_000_000_000)
                        } catch {
                            return
                        }
                        withAnimation(.appReveal) {
                            self.toast = nil
                        }
                    }
                }
            }
            .animation(.motionBase, value: toast?.id)
    }
}

struct ManualLogToastView: View {
    let toast: CaptureView.ManualLogToast
    let onScanAction: () -> Void
    let onTrackerAction: () -> Void

    /// Scan-nudge line under the manual-log toast. Pro reads as
    /// unlimited (no remaining-count number, ever); free users see the
    /// count and, when out, an "unlimited" upsell — never a cap number.
    private var scanNudgeCopy: String {
        if toast.isUnlimited {
            return "Try a photo scan?"
        }
        if toast.scansRemaining > 0 {
            return "Try a photo scan? \(toast.scansRemaining) left today"
        }
        return "Upgrade for unlimited photo scans"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Manual log saved")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.ink)
                    Text(toast.foodName)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    onTrackerAction()
                } label: {
                    Text("View today")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                }
                .buttonStyle(.plain)
            }

            if let reward = toast.questRewardCopy {
                Text(reward)
                    .appFont(.caption)
                    .foregroundStyle(Color.brandDeep)
            }

            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.inkMute)
                Button {
                    Haptics.tap()
                    onScanAction()
                } label: {
                    Text(scanNudgeCopy)
                        .appFont(.caption)
                        .foregroundStyle(Color.brandDeep)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.brandDeep)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }
}

// MARK: - Scan counter chip

/// The cutesy/premium pill that lives in the top bar showing scans
/// left today. Lives in its own struct so the animation state — pulse,
/// halo breathe, one-shot wiggle on the "ran out" moment — survives
/// CaptureView re-renders without re-starting on every tick.
///
/// Three visual states keyed off `remaining` and `isPro`:
///   • Plenty (remaining > 1 free, or pro any-N): brand-soft pill, a
///     mini camera (free) or a depleting progress ring (pro), and a
///     count that contentTransitions between values.
///   • Low (remaining == 1, free only): pill stays brand-soft but the
///     count shifts to a warm honey tone — a soft cue without nagging.
///   • Out (remaining == 0): pill morphs to a warm peach with an
///     orangeBadge halo gently breathing behind it. Icon swaps to a
///     crown via SF Symbols' `.replace` effect, the label fades in
///     "Out · Go Pro" (free) or "Maxed today" (pro), and the badge
///     does a one-shot wiggle the first frame it enters this state so
///     the user actually notices they ran out. Tappable → paywall.
///
/// `accessibilityReduceMotion` kills the wiggle and the halo breathe;
/// state-transition crossfades stay since they're geometry-stable.
struct ScanCounterChip: View {
    let remaining: Int
    let limit: Int
    let isPro: Bool
    /// When true (Pro), the chip drops the counter entirely and just
    /// reads "Unlimited" — no number, no depletion ring, and it never
    /// enters the out/warning state (the silent safety cap is invisible).
    var isUnlimited: Bool = false
    /// Fires on every tap regardless of state. The parent decides
    /// what to present — historically out-state went straight to
    /// the paywall, but the chip now always opens the explainer
    /// sheet so users can learn the scan budget before being
    /// upsold.
    let onTap: () -> Void
    /// Whether the Home tab is the active tab. The heartbeat loop only runs
    /// when true, so the chip stops animating on inactive tabs (TabView keeps
    /// the view alive otherwise).
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haloBreathe = false
    @State private var wiggle: Double = 0
    /// Heartbeat scale — driven by `runHeartbeatLoop` while scans
    /// remain so users actually notice the chip exists. Skipped when
    /// out of scans (the warning halo + wiggle already own the
    /// attention budget there) and under Reduce Motion.
    @State private var heartbeatScale: CGFloat = 1.0

    // Treat ANY Pro entitlement as unlimited in the chip, independent of the
    // server `isUnlimited` flag. That flag defaults false and only flips true
    // when the server echoes it, so a Pro response that predates or omits the
    // flag must NOT fall through to a numeric "X / limit" chip — that would
    // surface the silent abuse cap (the number the app must never show). Pro =
    // "Unlimited" here, always; the soft over-scan warning is delivered by
    // ScanLimitSheet on the server 429, not by this persistent chip.
    private var effectivelyUnlimited: Bool { isUnlimited || isPro }

    // Unlimited Pro never reads as "out" — the silent safety cap stays
    // invisible, so even if `remaining` hits 0 the chip keeps saying
    // "Unlimited" rather than flipping to the warning state.
    private var isOut: Bool { !effectivelyUnlimited && remaining == 0 }
    private var isLow: Bool { !isPro && remaining == 1 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                iconView
                labelView
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fillBackground)
            .overlay(rimStroke)
            .background(outerHalo)
            .rotationEffect(.degrees(wiggle))
            // Heartbeat scale sits outside the rotation so the lub-dub
            // doesn't stretch the wiggle into a jelly wobble. Layout
            // size is unaffected — scaleEffect is purely visual.
            .scaleEffect(heartbeatScale)
            // The geometry-stable animation: state→state recolor and
            // crossfade of the inner content. Spring keeps it bouncy
            // without overshoot.
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isOut)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isLow)
            .animation(.snappy, value: remaining)
        }
        .buttonStyle(.plain)
        .onAppear(perform: startBreathing)
        // .task auto-cancels on view disappear, so the heartbeat loop
        // exits cleanly when the user navigates away — no leaked
        // timers, no zombie animations against a defunct chip. Keyed on
        // `isActive` so it also stops on inactive tabs (where the chip stays
        // alive in the TabView) and restarts when Home is reselected.
        .task(id: isActive) {
            guard isActive else { return }
            await runHeartbeatLoop()
        }
        .onChange(of: isOut) { _, nowOut in
            if nowOut { runOutWiggle() }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isOut ? "Opens the Pro upgrade screen" : "")
    }

    // MARK: - Inner pieces

    // Icon morphs between three glyphs via SF Symbols' replace effect
    // (iOS 17+): camera → progress ring (pro) → crown (out). Bounce on
    // out so the swap reads as a tiny celebration of "go pro" rather
    // than a dead-end.
    @ViewBuilder
    private var iconView: some View {
        if effectivelyUnlimited {
            // Crown, not a depletion ring — a ring would encode a
            // proportion of the hidden cap. The crown reads as "Pro".
            Image(systemName: "crown.fill")
                .font(.system(size: 11, weight: .heavy))
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: isOut ? "crown.fill" : "camera.fill")
                .font(.system(size: 11, weight: .heavy))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: isOut)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // Label is two states behind one Group so the whole chunk
    // crossfades cleanly when the chip flips to out. Inside each
    // state the number uses .contentTransition(.numericText) so the
    // digit rolls when a scan is consumed.
    @ViewBuilder
    private var labelView: some View {
        Group {
            if effectivelyUnlimited {
                Text("Unlimited")
                    .appFont(.captionStrong)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if isOut {
                // Free-only: Pro is always `effectivelyUnlimited` above, so it
                // never reaches the out state on the chip (its over-scan
                // warning is the ScanLimitSheet on the server 429).
                Text("Out · Go Pro")
                    .appFont(.captionStrong)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                HStack(spacing: 3) {
                    Text("\(remaining)")
                        .appFont(.captionStrong)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(remaining == 1 ? "left!" : "left today")
                        .appFont(.captionStrong)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Style tokens

    private var foreground: Color {
        if isOut { return .orangeCancel }
        if isLow { return .orangeBadge }
        return .brandDeep
    }

    private var fillBackground: some View {
        Capsule().fill(
            isOut
                ? Color.catDrawbacks                // soft peach
                : (isLow ? Color.brandCream : Color.brandSoft)
        )
    }

    private var rimStroke: some View {
        Capsule().strokeBorder(
            isOut
                ? Color.orangeCancel.opacity(0.35)
                : (isLow
                    ? Color.orangeBadge.opacity(0.40)
                    : Color.brand.opacity(0.25)),
            lineWidth: 1
        )
    }

    // Soft warm halo that only appears in the out state. Slowly
    // breathes scale + opacity so the chip feels alive — the same
    // trick the pro badge uses, tuned warmer so it reads as
    // "attention, friendly" instead of "alarm".
    @ViewBuilder
    private var outerHalo: some View {
        if isOut {
            Capsule()
                .fill(Color.orangeBadge.opacity(0.45))
                .blur(radius: 9)
                .scaleEffect(haloBreathe ? 1.22 : 1.05)
                .opacity(haloBreathe ? 0.95 : 0.55)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Animations

    private func startBreathing() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloBreathe = true
        }
    }

    /// Lub-dub-rest heartbeat that draws the eye to the chip without
    /// being constant. Three-phase scale: quick lub (1.22), quick dub
    /// (0.94 — undershoot reads as the recoil after a heartbeat),
    /// then a settle back to 1.0 followed by a long rest.
    ///
    /// Runs in every state — including out — so the chip stays
    /// noticeable when the user has nothing left and needs to tap to
    /// upgrade. The out-state halo breathes behind the chip; the
    /// heartbeat scales the chip itself; the two layers reinforce
    /// "tap me" rather than compete.
    ///
    /// Killed only under Reduce Motion. `.task` cancels the loop when
    /// the chip leaves the view tree.
    private func runHeartbeatLoop() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            // Lub — fast contraction outward.
            await MainActor.run {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                    heartbeatScale = 1.22
                }
            }
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Dub — quick rebound below 1.0 so it reads as a real
            // double-beat instead of a single pop.
            await MainActor.run {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                    heartbeatScale = 0.94
                }
            }
            try? await Task.sleep(nanoseconds: 160_000_000)

            // Settle back to rest.
            await MainActor.run {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                    heartbeatScale = 1.0
                }
            }

            // Long pause between beats — keeps the motion noticeable
            // when it lands rather than blending into ambient noise.
            try? await Task.sleep(nanoseconds: 1_900_000_000)
        }
    }

    // One-shot wobble: -7° → 7° → -3° → 0. Fires only the moment the
    // chip flips into the out state so the user notices; subsequent
    // re-renders of the out chip don't wiggle again.
    private func runOutWiggle() {
        guard !reduceMotion else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
            wiggle = -7
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
                wiggle = 7
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) {
                wiggle = -3
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                wiggle = 0
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        // Pro is always `effectivelyUnlimited`, so VoiceOver never reads a
        // Pro scan count (which would voice the silent cap).
        if effectivelyUnlimited { return "Unlimited photo scans with Pro" }
        if isOut { return "Out of scans today. Tap to upgrade to Pro." }
        return remaining == 1
            ? "1 free scan left today"
            : "\(remaining) free scans left today"
    }
}

// MARK: - Scan limits explainer

/// Modal that explains the scan budget in one screen so users
/// understand "why N today" without leaving Home. Surfaces:
///   • Today's usage (X of Y, with the remaining count up top so
///     the user's actual state is the first thing they read).
///   • Free policy spelled out — 4/day for the first week, then 2/day
///     forever. Bonus framing rather than "your cap will drop".
///   • Pro policy — unlimited photo scans, every day, cancel anytime.
///   • Action row: free users get a gold "Try Pro" pill that opens
///     the existing `PaywallView`; pro users get a quiet "You're on
///     Pro" confirmation + Close.
///
/// Entrance choreography (the "alive" feel): inner content stays
/// invisible until the sheet finishes its native slide-up, then
/// each block reveals in turn with a small offset + spring. Total
/// reveal ~0.55s; total perceived presentation ~1s including the
/// sheet itself.
///
/// Lives inline in CaptureView.swift to avoid manual pbxproj file
/// adds (project doesn't use synchronized folders).
struct ScanLimitsExplainerSheet: View {
    let used: Int
    let limit: Int
    let isPro: Bool
    /// Pro is presented as unlimited — the today strip and the Pro card
    /// render "Unlimited" with no number when this is set.
    var isUnlimited: Bool = false
    let onTryPro: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Master reveal flag. Flipped via `.task` after a short delay so
    /// inner content lands *after* the system sheet slide; staggered
    /// per-block delays do the rest.
    @State private var revealed = false

    private var remaining: Int { max(0, limit - used) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    heroBlock                      // delay 0.00
                        .reveal(revealed, delay: 0.00)
                    todayCard                      // delay 0.08
                        .reveal(revealed, delay: 0.08)
                    freeCard                       // delay 0.16
                        .reveal(revealed, delay: 0.16)
                    proCard                        // delay 0.24
                        .reveal(revealed, delay: 0.24)
                    Spacer(minLength: AppSpacing.md)
                    actionRow                      // delay 0.34
                        .reveal(revealed, delay: 0.34)
                    footerNote
                        .reveal(revealed, delay: 0.40)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.xl)
            }

            // Close X. Sits above the drag indicator so the chrome
            // doesn't fight the eye for the same corner.
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.bgSurface))
                    .appShadow(.shadowCard)
            }
            .padding(AppSpacing.md)
            .accessibilityLabel("Close")
        }
        .background(Color.bgCanvas)
        .task {
            // Wait a beat so the inner reveal doesn't race the
            // sheet's slide-up. ~0.18s lands the first item just as
            // the sheet settles, which reads as a continuous motion
            // chain rather than two separate animations.
            if reduceMotion {
                revealed = true
            } else {
                try? await Task.sleep(nanoseconds: 180_000_000)
                revealed = true
            }
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // Stacked camera + sparkle glyph — reads as "scan magic"
            // without needing illustration. Gold tint nods to Pro
            // even on free, since both tiers are explained inside.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                ProGold.cream.opacity(0.7),
                                ProGold.rose.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.brandDeep)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("Your scan budget")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Simple, no surprises.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Today

    /// Today's usage strip. Keeps the user's actual state visible
    /// throughout the explanation so the abstract policy below maps
    /// to something concrete ("I have N left right now").
    private var todayCard: some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TODAY")
                    .appFont(.labelEyebrow)
                    .foregroundStyle(Color.inkMute)
                Text(todayLine)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
            }
            Spacer()
            // Mini pip strip — one circle per scan in today's limit,
            // filled = used, empty = remaining. Capped at 10 so pro
            // doesn't get an unreadable row. Hidden for unlimited Pro:
            // a finite pip count would imply a cap.
            if !isUnlimited {
                HStack(spacing: 4) {
                    ForEach(0..<min(limit, 10), id: \.self) { i in
                        Circle()
                            .fill(i < used ? Color.brandDeep : Color.brand.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.brandDeep)
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft.opacity(0.65))
        )
    }

    private var todayLine: String {
        if isUnlimited { return "Unlimited scans" }
        if remaining == 0 { return "Out for today" }
        if remaining == 1 { return "1 scan left" }
        return "\(remaining) scans left"
    }

    // MARK: - Free card

    private var freeCard: some View {
        tierCard(
            label: "FREE",
            labelColor: Color.inkMute,
            accent: Color.brand,
            border: Color.borderHairline,
            bigNumber: "4 → 2",
            bigSuffix: "per day",
            lines: [
                "First week: 4 scans/day to help you get the hang of it.",
                "After: 2 scans/day, every day.",
            ],
            crown: false
        )
    }

    // MARK: - Pro card

    private var proCard: some View {
        tierCard(
            label: "PRO",
            labelColor: ProGold.deep,
            accent: ProGold.warm,
            border: ProGold.warm.opacity(0.45),
            bigNumber: "∞",
            bigSuffix: "per day",
            lines: [
                "Unlimited photo scans, every single day.",
                "Cancel anytime in Settings.",
            ],
            crown: true
        )
    }

    /// Shared card shape so the two tiers read as a pair. The Pro
    /// variant gets a warm gold border + crown badge to feel earned
    /// rather than just "the other option".
    private func tierCard(
        label: String,
        labelColor: Color,
        accent: Color,
        border: Color,
        bigNumber: String,
        bigSuffix: String,
        lines: [String],
        crown: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if crown {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    Text(label)
                        .appFont(.labelEyebrow)
                }
                .foregroundStyle(labelColor)

                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(bigNumber)
                    .font(.custom(AppFont.PS.mplusBlack, size: 30))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(bigSuffix)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(border, lineWidth: crown ? 1.5 : 1)
        )
        // Pro card gets a soft gold shadow so it visually lifts off
        // the page — the cue is geometric, not just colored.
        .shadow(
            color: crown ? ProGold.warm.opacity(0.25) : .black.opacity(0.04),
            radius: crown ? 12 : 4,
            x: 0,
            y: crown ? 6 : 2
        )
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        if isPro {
            // Already paying. Don't ask again — just confirm the
            // status and let them dismiss.
            VStack(spacing: AppSpacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .heavy))
                    Text("You're on Pro")
                        .appFont(.title2)
                }
                .foregroundStyle(ProGold.deep)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(
                    Capsule().fill(ProGold.cream.opacity(0.45))
                )
                .overlay(
                    Capsule().strokeBorder(ProGold.warm.opacity(0.45), lineWidth: 1)
                )

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(spacing: AppSpacing.sm) {
                Button {
                    Haptics.tap()
                    onTryPro()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 16, weight: .heavy))
                        Text("Try Pro")
                            .appFont(.title2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [ProGold.warm, ProGold.edgeDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(ProGold.cream.opacity(0.6), lineWidth: 0.8)
                    )
                    .shadow(color: ProGold.warm.opacity(0.45), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Maybe later")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerNote: some View {
        Text("Manual logging is unlimited on both tiers.")
            .appFont(.caption)
            .foregroundStyle(Color.inkLight)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Reveal modifier for the explainer sheet — opacity + small upward
/// offset + tiny scale, driven by a single boolean flipped after the
/// sheet's slide-up so the inner content reads as continuous motion.
struct RevealModifier: ViewModifier {
    let revealed: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1.0 : 0.96)
            .offset(y: revealed ? 0 : 14)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.78).delay(delay),
                value: revealed
            )
    }
}

extension View {
    func reveal(_ revealed: Bool, delay: Double) -> some View {
        modifier(RevealModifier(revealed: revealed, delay: delay))
    }
}
