import Foundation
import SwiftUI

/// LifeOS-style Home preview of the user's Food Mirror. Stacks an
/// eyebrow, a bold title, an optional muted body, a gentle nudge
/// line, a tiny evidence caption, and a CTA — designed to feel like
/// a living personal-intelligence preview rather than a single tip.
///
/// The surface is a custom premium card (bgSurface w/ brandSoft glow,
/// hairline border, floating sparkle orb) rather than BrandCard so the
/// Mirror reads as its own distinct, reflective object on Home — calmer
/// than the photo CTA, but unmistakably tappable.
///
/// `onTap` is optional. The Home surface wires it through
/// `NotificationRouter.requestTab(2)` so the existing tab-routing
/// publisher handles navigation — no new router introduced.
struct HomeMirrorPreviewCard: View {
    let model: HomeMirrorPreviewCardModel
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var arrowNudge: CGFloat = 0

    var body: some View {
        Button {
            Haptics.tap()
            onTap?()
        } label: {
            cardSurface
        }
        .buttonStyle(MirrorCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Open Food Mirror"))
        .accessibilityHint(Text("Shows your eating patterns and weekly insights."))
        .accessibilityAddTraits(.isButton)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let curve = reduceMotion ? Animation.appReduced : Animation.appBouncy
            withAnimation(curve) { hasAppeared = true }
            scheduleArrowNudge()
        }
    }

    // MARK: - Layout

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            headerRow

            Text(model.title)
                .appFont(.title1)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let body = model.body {
                Text(body)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let nudge = model.nudgeLine {
                nudgeChip(nudge)
            }

            if case .learning(let progress) = model.kind {
                learningProgressBar(progress)
            }

            footerRow
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundLayer)
        .overlay(borderLayer)
        .appShadow(.shadowCard)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(model.eyebrow)
                .eyebrow()
                .foregroundStyle(Color.brandDeep)
            Spacer(minLength: 0)
            MirrorOrb(reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private func nudgeChip(_ nudge: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.brandDeep)
                .padding(.top, 4)
            Text(nudge)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.brandDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(Color.brandSoft.opacity(0.55))
        )
        .padding(.top, AppSpacing.xs)
    }

    @ViewBuilder
    private func learningProgressBar(_ progress: LearningProgress) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.bgSurfaceSoft)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.brand, Color.brandDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(
                                12,
                                geo.size.width
                                    * CGFloat(progress.mealsLoggedInWindow)
                                    / CGFloat(max(progress.target, 1))
                            )
                        )
                        .animation(
                            reduceMotion ? .appReduced : .motionProgressFill,
                            value: progress.mealsLoggedInWindow
                        )
                }
            }
            .frame(height: 8)
        }
        .padding(.top, AppSpacing.xs)
    }

    private var footerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            if let evidence = model.evidenceLine {
                Text(evidence)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(model.ctaText.replacingOccurrences(of: " →", with: ""))
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.brandDeep)
                    .offset(x: arrowNudge)
            }
        }
        .padding(.top, AppSpacing.xs)
    }

    // MARK: - Surface

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl)
            .fill(Color.bgSurface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.brandSoft.opacity(0.55),
                                Color.brandSoft.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var borderLayer: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl)
            .strokeBorder(Color.borderHairline, lineWidth: 1)
    }

    // MARK: - Motion

    /// Nudges the CTA arrow a couple of points on appear so the card
    /// reads as actively inviting a tap. Skipped under Reduce Motion.
    private func scheduleArrowNudge() {
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.appBouncy) { arrowNudge = 4 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.appBouncy) { arrowNudge = 0 }
            }
        }
    }
}

/// Tactile press state for the Mirror card. Slight lift + scale on
/// press; matches the cadence of `BrandCard` but tuned softer since
/// the Mirror surface is calmer than the photo capture card.
private struct MirrorCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? -2 : 0)
            .animation(
                reduceMotion ? .appReduced : .appPress,
                value: configuration.isPressed
            )
    }
}

/// Floating "mirror orb" badge — a small circle with a soft brand
/// glow and a sparkles SF Symbol inside. Breathes gently to signal
/// the card is alive without being noisy. Disabled under Reduce
/// Motion so the badge sits still.
private struct MirrorOrb: View {
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.brandSoft)
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .strokeBorder(Color.brand.opacity(0.35), lineWidth: 1)
                )
                .scaleEffect(pulse ? 1.06 : 1.0)
                .shadow(color: Color.brand.opacity(0.18),
                        radius: pulse ? 10 : 6, x: 0, y: 2)
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}

/// Drives the Home Food Mirror preview card. Thin wrapper around the
/// same `FoodLogService.logs(from:to:)` fetches the Mirror tab issues —
/// kept separate so Home stays independent of the Mirror tab's own
/// `@StateObject`.
///
/// Production behavior:
///   - First successful refresh populates `cardModel`.
///   - Subsequent failures preserve the previous card (the Home
///     surface stays "quietly correct" instead of flickering empty
///     on a flaky network).
///   - `CancellationError` is silently swallowed; no log spam.
///   - A monotonic refresh token guards against an older fetch
///     overwriting a newer one when refreshes overlap.
@MainActor
final class HomeMirrorPreviewViewModel: ObservableObject {

    @Published private(set) var cardModel: HomeMirrorPreviewCardModel?

    private let foodLogs: any FoodLogsFetching

    /// Monotonic token. Each `refresh()` captures it on entry and
    /// bails on commit if a newer refresh has overtaken it — older,
    /// slower fetches can't overwrite the newer, fresher result.
    private var refreshToken: UInt64 = 0

    init(foodLogs: any FoodLogsFetching = FoodLogService()) {
        self.foodLogs = foodLogs
    }

    /// Refresh the preview. Two narrow PostgREST queries; quietly
    /// keeps the previous card on transient failure so a network
    /// blip never blanks the Home surface.
    func refresh(now: Date = Date(),
                 timeZone: TimeZone = .current) async {
        refreshToken &+= 1
        let myToken = refreshToken

        let (sevenStart, sevenEnd) =
            FoodMirrorViewModel.window(daysBack: 7,  now: now, timeZone: timeZone)
        let (thirtyStart, thirtyEnd) =
            FoodMirrorViewModel.window(daysBack: 30, now: now, timeZone: timeZone)
        let prevSevenStart = sevenStart.addingTimeInterval(-7 * 24 * 60 * 60)
        let prevSevenEnd   = sevenStart

        do {
            async let sevenTask  = foodLogs.logs(from: sevenStart,  to: sevenEnd)
            async let thirtyTask = foodLogs.logs(from: thirtyStart, to: thirtyEnd)

            let sevenLogs  = try await sevenTask
            let thirtyLogs = try await thirtyTask

            // A newer refresh started while we were waiting on the
            // network — let it win, even if our payload is fine. The
            // newer fetch saw a strictly newer database state.
            guard myToken == refreshToken else { return }

            let prevSevenLogs = thirtyLogs.filter {
                $0.eatenAt >= prevSevenStart && $0.eatenAt < prevSevenEnd
            }

            let summary = FoodMirrorInsightService.compute(
                thirtyDayLogs:        thirtyLogs,
                sevenDayLogs:         sevenLogs,
                previousSevenDayLogs: prevSevenLogs,
                now:                  now,
                timeZone:             timeZone
            )
            cardModel = HomeMirrorPreview.cardModel(for: summary)
        } catch is CancellationError {
            // Swallow silently — cancellation is normal (tab switch,
            // view disappear) and doesn't deserve a log entry.
            return
        } catch {
            #if DEBUG
            NSLog("[HomeMirrorPreview] refresh failed: %@", "\(error)")
            #endif
            // Only blank the surface when we've never shown anything
            // yet. Once we have a successful render, keep showing it —
            // a transient blip should never flicker the Home card.
            if cardModel == nil {
                cardModel = nil
            }
        }
    }
}
