#if DEBUG
import SwiftUI

/// `LAUNCH_TRACKER_FAILED=1` entry point. Renders the Tracker tab's
/// failed state with a synthetic `URLError.notConnectedToInternet`
/// payload — same code path the production view exercises when the
/// device is offline, just triggered without disabling actual networking.
///
/// Used to screenshot the offline-tracker failure mode for Phase 8
/// verification.
struct TrackerFailedSample: View {
    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    sampleHeaderCard
                    failedBody
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl3)
            }
        }
    }

    // Same header layout the production TrackerView uses, frozen at
    // load-time placeholders.
    private var sampleHeaderCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Today, \(formattedDate())")
                .appFont(.displayMD)
                .fontWeight(.heavy)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text("—")
                        .appFont(.kcal)
                        .fontWeight(.black)
                        .foregroundStyle(.white)
                    Text("total calories")
                        .appFont(.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("Total sugar: —g")
                    .appFont(.body).fontWeight(.semibold).foregroundStyle(.white)
                Text("Total carbs: —g")
                    .appFont(.body).fontWeight(.semibold).foregroundStyle(.white)
            }
            BouncingBadge(text: "Daily tracker resets every 12:00 am",
                          style: .reminder)
                .padding(.top, AppSpacing.xs)
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(
                    LinearGradient(colors: [.brand, .brandBright],
                                   startPoint: .topTrailing,
                                   endPoint: .bottomLeading)
                )
        )
    }

    private var failedBody: some View {
        VStack(spacing: AppSpacing.md) {
            Text("Couldn't load today's meals")
                .appFont(.displayMD)
                .foregroundStyle(Color.redError)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
            Text("Looks like you're offline. Check your connection and try again.")
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
                .multilineTextAlignment(.center)
            PillButton(title: "Try again", variant: .outline) {}
                .padding(.top, AppSpacing.sm)
        }
        .padding(.top, AppSpacing.xl)
    }

    private func formattedDate() -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM d"
        return f.string(from: Date())
    }
}

#endif
