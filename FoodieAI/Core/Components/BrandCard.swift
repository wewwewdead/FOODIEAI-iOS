import SwiftUI

/// Web equivalent: shared `.card` style on About / Education / Login.
/// brandCream fill, xl radius, cardPad, card↔cardHover shadow swap on press.
struct BrandCard<Content: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                BrandCardSurface(isPressed: false, content: content)
            }
            .buttonStyle(BrandCardButtonStyle(content: content))
        } else {
            BrandCardSurface(isPressed: false, content: content)
        }
    }
}

/// The visual surface — kept separate so the press-state ButtonStyle can
/// re-render it with `isPressed: true` when a tap is in flight.
private struct BrandCardSurface<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.cardPad)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(Color.brandCream)
        )
        .appShadow(isPressed ? .cardHover : .card)
        .offset(y: isPressed ? -5 : 0)
        .animation(.appPress, value: isPressed)
    }
}

/// Button style that rebuilds the card surface with the live press flag so
/// the shadow swap and translateY both animate in lockstep.
private struct BrandCardButtonStyle<Content: View>: ButtonStyle {
    @ViewBuilder let content: () -> Content
    func makeBody(configuration: Configuration) -> some View {
        BrandCardSurface(isPressed: configuration.isPressed, content: content)
            .contentShape(Rectangle())
    }
}

#Preview("BrandCard variants") {
    ScrollView {
        VStack(spacing: AppSpacing.lg) {
            BrandCard {
                Text("How It Works").appFont(.displayMD).foregroundStyle(Color.textPrimary)
                Text("Upload a meal photo. Our AI breaks it down into calories, carbs, and a celebrity coach's witty take.")
                    .appFont(.body).foregroundStyle(Color.textBody)
                Text("→ Get instant and structured results")
                    .appFont(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.greenCalorie)
            }

            BrandCard(onTap: {}) {
                Text("Why I Built This").appFont(.displayMD).foregroundStyle(Color.textPrimary)
                Text("After tracking macros by hand for years, I wanted a phone-camera shortcut. Foodie is that shortcut.")
                    .appFont(.body).foregroundStyle(Color.textBody)
                Text("→ Tap me — I'm a button")
                    .appFont(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.greenCalorie)
            }

            BrandCardSurface_PreviewWrapper()
        }
        .padding(AppSpacing.lg)
    }
    .background(Color.brandIvory)
}

/// Forces the pressed state for the visual sample.
private struct BrandCardSurface_PreviewWrapper: View {
    var body: some View {
        BrandCardSurface(isPressed: true) {
            Text("How I Built foodieAi.").appFont(.displayMD).foregroundStyle(Color.textPrimary)
            Text("Built with SwiftUI + Supabase. Gemini does the analyzing on a small Express proxy.")
                .appFont(.body).foregroundStyle(Color.textBody)
            Text("→ Forced pressed state preview")
                .appFont(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.greenCalorie)
        }
    }
}
