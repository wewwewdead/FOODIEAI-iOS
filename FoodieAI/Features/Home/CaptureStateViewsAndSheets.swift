import SwiftUI
import UIKit

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The no-food and failed-analysis state views, and the sheet/toast presentation modifiers (calorie-scan warning, re-log toast, name-confirm, quantity-clarification). Types are module-scoped so CaptureView still references them.

// MARK: - No-food and Failed states

/// Shown when the server returns `analysis.fallback` (no food detected).
struct NoFoodView: View {
    let onTryAnother: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color.inkLight)
            Text("No food detected")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text("Try a clearer photo of a meal, snack, or drink.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Try another photo",
                          leadingSystemImage: "camera.fill",
                          action: onTryAnother)
                .padding(.top, AppSpacing.md)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

/// Shown when `AnalyzeService.analyze` throws.
struct FailedView: View {
    let error: AnalyzeError
    let onRetry: () -> Void
    let onTryAnother: () -> Void

    /// HTTP 400 from `/analyze` typically means Gemini couldn't get a
    /// structured response off the photo (server bodies look like
    /// "No structured response received" / "Failed to analyze image").
    /// That's a photo-quality problem, not a backend outage — surface
    /// copy the user can act on instead of the generic message, and
    /// flip the CTA priority so picking a *different* photo is the
    /// primary action (retrying the same broken image is futile).
    private var isUnreadablePhoto: Bool {
        if case .serverError(let status, _) = error, status == 400 {
            return true
        }
        return false
    }

    private var title: String {
        isUnreadablePhoto ? "We couldn't read this photo" : "Something went wrong"
    }

    private var detail: String {
        if isUnreadablePhoto {
            return "We couldn't read this photo clearly. Try a brighter shot or a different angle?"
        }
        return error.errorDescription ?? "Please try again."
    }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color.error.opacity(0.85))
            Text(title)
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)

            // Unreadable-photo path: picking a different photo is the
            // useful action; retrying the same broken upload is the
            // fallback. Genuine network errors keep "Try again" as
            // primary because the same image will probably succeed
            // once connectivity is back.
            if isUnreadablePhoto {
                PrimaryButton(title: "Try another photo",
                              leadingSystemImage: "camera.fill",
                              action: onTryAnother)
                    .padding(.top, AppSpacing.md)
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .heavy))
                        Text("Try again with this photo")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.inkMute)
                }
                .buttonStyle(.plain)
            } else {
                PrimaryButton(title: "Try again",
                              leadingSystemImage: "arrow.clockwise",
                              action: onRetry)
                    .padding(.top, AppSpacing.md)
                Button(action: onTryAnother) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .heavy))
                        Text("Pick a different photo")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.inkMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Quantity Clarification sheet modifier

/// Quantity Clarification — extracted ViewModifier so the new sheet
/// presentation doesn't bloat the main CaptureView body's modifier
/// chain past the Swift type-checker's budget. Same behavior as an
/// inline `.sheet`: presents whenever `state == .clarifying(...)`,
/// dismissal routes through `acceptOriginalAnalysis` so the user is
/// never stuck with no usable analysis after closing.
/// Phase 20 calorie-goal scan warning, lifted out of CaptureView's main
/// modifier chain so the type-checker doesn't have to thread three more
/// closures + a presenting-binding through the rest of the body.
struct CalorieScanWarningModifier: ViewModifier {
    @Binding var kind: CaptureView.ScanWarningKind?
    let onScanAnyway: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            kind.map(CaptureView.scanWarningTitle) ?? "",
            isPresented: Binding(
                get: { kind != nil },
                set: { presented in
                    if !presented { kind = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: kind
        ) { _ in
            Button("Scan anyway") {
                kind = nil
                onScanAnyway()
            }
            Button("View tracker") {
                kind = nil
                NotificationRouter.shared.requestTab(1)
            }
            Button("Cancel", role: .cancel) {
                kind = nil
            }
        } message: { kind in
            Text(CaptureView.scanWarningMessage(kind))
        }
    }
}

/// Phase 15 re-log toast overlay + auto-fade Task, extracted so the
/// trailing `.overlay { … }` + `.animation` modifiers no longer count
/// against CaptureView's main expression complexity budget.
struct RelogToastModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = viewModel.relogToast {
                    RelogToastView(toast: toast)
                        .padding(.bottom, 96) // clear of the pinned PrimaryButton
                        .padding(.horizontal, AppSpacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            // `try?` would swallow CancellationError but
                            // still run the clear, so a newly-arrived toast
                            // (id flips) would be cleared by the *prior*
                            // task's continuation. Bail explicitly on cancel.
                            do {
                                try await Task.sleep(nanoseconds: 1_600_000_000)
                            } catch {
                                return
                            }
                            withAnimation(.appReveal) {
                                viewModel.clearRelogToast()
                            }
                        }
                }
            }
            .animation(.motionBase, value: viewModel.relogToast?.id)
    }
}

/// Mandatory name confirmation — presents `NameConfirmSheet` whenever
/// the view model is in `.confirmingName` (every successful first-pass
/// analyze lands there). Mirrors `ClarificationSheetModifier`:
/// visibility is entirely state-driven and the binding's `set` is a true
/// no-op. We do NOT route dismissal through `confirmDetectedName` here —
/// doing so would race `correctNameAndContinue` (which flips state to
/// `.analyzing`) the same way the clarification path could race the
/// refine Task. "Looks right" / drag-to-dismiss call `confirmDetectedName`
/// from inside the sheet view itself (via its `onConfirm` + `onDisappear`
/// default).
struct NameConfirmSheetModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { viewModel.state.isConfirmingName },
            set: { _ in /* no-op, state machine owns dismissal */ }
        )) {
            if case .confirmingName(_, let response) = viewModel.state {
                NameConfirmSheet(
                    detectedName: viewModel.editedFoodName
                        ?? response.analysis.food
                        ?? "this dish",
                    nameAlternatives: response.analysis.nameAlternatives ?? [],
                    onConfirm: {
                        viewModel.confirmDetectedName()
                    },
                    onCorrect: { name in
                        Task { await viewModel.correctNameAndContinue(name) }
                    },
                    visualSuggestion: viewModel.visualSuggestedName,
                    visualTimesSeen: viewModel.visualTimesSeen
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

struct ClarificationSheetModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        // Fix A — the binding's `set` is a TRUE no-op. We do NOT
        // route dismissal through `acceptOriginalAnalysis` here:
        // doing so raced the refine Task and flipped state to
        // `.ready` before the Task body ran, causing the guard in
        // `refineAnalysis` to fail. Instead the sheet visibility is
        // entirely state-driven (presents on `.clarifying`,
        // dismisses on any other state). "Looks about right" /
        // drag-to-dismiss call `acceptOriginalAnalysis` from inside
        // the sheet view itself.
        content.sheet(isPresented: Binding(
            get: { viewModel.state.isClarifying },
            set: { _ in /* no-op, state machine owns dismissal */ }
        )) {
            if case .clarifying(_, _, let items) = viewModel.state {
                QuantityClarificationSheet(
                    items: items,
                    onConfirm: { quantities in
                        Task { await viewModel.refineAnalysis(with: quantities) }
                    },
                    onDismiss: {
                        viewModel.acceptOriginalAnalysis()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Re-log toast

/// Phase 15. Lightweight pill toast for quick-re-log confirmations.
/// Distinct from `SavedConfirmationSheet`'s full-screen success
/// choreography — re-logs are a frequency action, not a moment, so
/// this lives at the bottom of the screen and fades in 1.6s.
struct RelogToastView: View {
    let toast: CaptureViewModel.RelogToast

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: toast.kind == .success
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(toast.kind == .success
                                 ? Color.success
                                 : Color.error)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.kind == .success ? "Re-logged" : "Couldn't re-log")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Text(toast.foodName)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            toast.kind == .success
            ? "Re-logged \(toast.foodName)"
            : "Couldn't re-log \(toast.foodName)"
        )
    }
}
