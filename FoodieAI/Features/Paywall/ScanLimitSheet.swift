import SwiftUI

/// Phase 22 — shown when /analyze returns the structured 429
/// scan_limit_reached. Not a dead-end: manual logging is always
/// available, so we frame it as a real second option rather than a
/// punishment for hitting the cap.
///
/// Two actions:
///   • Upgrade to Pro → presents PaywallView
///   • Log this meal manually → fires the host's `onManualLog`
///
/// The host decides what "manual" means — the sheet just calls back so
/// the same component can be reused from Capture (use the current
/// photo's context) or from any other surface that hits the cap.
struct ScanLimitSheet: View {
    /// Authoritative payload from the server's 429 body. Drives the
    /// counter line and the resetsAt timestamp.
    let info: ScanLimitInfo
    let onUpgrade: () -> Void
    let onManualLog: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer(minLength: AppSpacing.md)

            // Big "you're out of scans" indicator, but friendly.
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.brandDeep)
                .padding(.bottom, 4)

            Text(headlineCopy)
                .appFont(.display2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, AppSpacing.lg)

            Text(resetsCopy)
                .appFont(.bodyV2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.inkMute)
                .padding(.horizontal, AppSpacing.lg)

            // Pro users already pay — don't ask them to upgrade. They
            // get manual logging as the single primary action; free
            // users get upgrade above the manual fallback.
            VStack(spacing: AppSpacing.md) {
                if isPro {
                    PrimaryButton(title: "Log this meal manually",
                                  leadingSystemImage: "square.and.pencil") {
                        Haptics.tap()
                        onManualLog()
                    }
                } else {
                    PrimaryButton(title: "Upgrade to Pro",
                                  leadingSystemImage: "sparkles") {
                        onUpgrade()
                    }
                    Button {
                        Haptics.tap()
                        onManualLog()
                    } label: {
                        Text("Log this meal manually")
                            .appFont(.title2)
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(
                                Capsule()
                                    .stroke(Color.ink, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)

            Spacer(minLength: AppSpacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgCanvas)
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap()
                onDismiss()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.bgSurface))
                    .appShadow(.shadowCard)
            }
            .padding(AppSpacing.md)
            .accessibilityLabel("Close")
        }
    }

    private var isPro: Bool { info.tier == "pro" }

    private var headlineCopy: String {
        // Pro is marketed as unlimited — if a Pro user somehow trips the
        // silent server-side safety cap, the message must NOT reveal the
        // number. Frame it as a gentle "you've done a lot today" instead.
        isPro
            ? "You've scanned a lot today, take a break?"
            : "You've used today's \(info.limit) photo scans."
    }

    private var resetsCopy: String {
        if isPro {
            return "We'll reset your scans at midnight."
        }
        if let when = info.resetsAt {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "Resets at \(f.string(from: when)) tonight."
        }
        return "Resets at midnight."
    }
}

#if DEBUG
#Preview("ScanLimitSheet — free") {
    ScanLimitSheet(
        info: ScanLimitInfo(limit: 2, tier: "free",
                            resetsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))),
        onUpgrade: {},
        onManualLog: {},
        onDismiss: {}
    )
}

#Preview("ScanLimitSheet — pro") {
    ScanLimitSheet(
        info: ScanLimitInfo(limit: 100, tier: "pro",
                            resetsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))),
        onUpgrade: {},
        onManualLog: {},
        onDismiss: {}
    )
}
#endif
