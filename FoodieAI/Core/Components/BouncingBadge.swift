import SwiftUI

/// Web equivalents:
///   `.free` (Login title corner)        — `.free` style.
///   `.reminder` (DailyTracker header)   — `.reminder` style.
struct BouncingBadge: View {
    enum Style {
        case free      // oliveDrab / white / weight 800 / pill
        case reminder  // orangeBadge / white / weight 600 / md radius
    }

    let text: String
    var style: Style

    @State private var animate = false

    var body: some View {
        Text(text)
            .appFont(font(for: style))
            .foregroundStyle(.white)
            .padding(padding(for: style))
            .background(
                Group {
                    switch style {
                    case .free:     Capsule().fill(Color.oliveDrab)
                    case .reminder: RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.orangeBadge)
                    }
                }
            )
            .offset(y: animate ? -3 : 3)
            .animation(
                .easeInOut(duration: duration(for: style)).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear { animate = true }
            .accessibilityLabel(text)
    }

    // MARK: - Per-style tokens

    private func font(for style: Style) -> AppFont.Style {
        switch style {
        case .free:     .metaExtraBold
        case .reminder: .metaSemiBold
        }
    }

    private func padding(for style: Style) -> EdgeInsets {
        switch style {
        case .free:
            EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.sm,
                       bottom: AppSpacing.xs, trailing: AppSpacing.sm)
        case .reminder:
            EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.xs,
                       bottom: AppSpacing.xs, trailing: AppSpacing.xs)
        }
    }

    private func duration(for style: Style) -> Double {
        switch style {
        case .free:     1.2
        case .reminder: 2.0
        }
    }
}

#Preview("BouncingBadge — both styles") {
    VStack(spacing: AppSpacing.xl) {
        VStack {
            BouncingBadge(text: "free!", style: .free)
            Text(".free on cream").appFont(.meta).foregroundStyle(Color.textMeta)
        }
        .padding(AppSpacing.lg)
        .background(Color.brandCream)
        .cornerRadius(AppRadius.xl)

        VStack {
            BouncingBadge(text: "Daily tracker resets every 12:00 am", style: .reminder)
            Text(".reminder on tracker gradient").appFont(.meta).foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(AppSpacing.lg)
        .background(
            LinearGradient(colors: [.brand, .brandBright],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        )
        .cornerRadius(AppRadius.lg)
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.brandIvory)
}
