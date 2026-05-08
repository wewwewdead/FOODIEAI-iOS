import SwiftUI

/// Visual roll-call for every Phase 3 component. Reachable via the
/// `FoodieAI-ComponentGallery` Xcode scheme.
struct ComponentGallery: View {
    /// Anchors so the screenshot harness can scroll to a specific section
    /// via the LAUNCH_COMPONENT_GALLERY_SECTION env var.
    private enum Anchor: String {
        case pills, cards, circles, bubble, drop, panels, badges, nav
    }

    @State private var dropImage: UIImage? = nil
    @State private var typewriterKey = 0

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                        Spacer().frame(height: 64) // clear nav bar

                        Section("PillButton — primary, outline, ghost", anchor: .pills) {
                            VStack(spacing: AppSpacing.md) {
                                PillButton(title: "Sign Up!", variant: .primary) {}
                                PillButton(title: "Analyze", variant: .outline) {}
                                PillButton(title: "Analyzing…", variant: .outline, isLoading: true) {}
                            }
                            VStack(spacing: AppSpacing.md) {
                                PillButton(title: "Try for FREE", variant: .ghost) {}
                            }
                            .padding(AppSpacing.lg)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(colors: [.greenCalorie, .greenAnalysis],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .cornerRadius(AppRadius.lg)
                            )
                        }

                        Section("BrandCard — static and tappable", anchor: .cards) {
                            BrandCard {
                                Text("How It Works").appFont(.displayMD).foregroundStyle(Color.textPrimary)
                                Text("Snap. Analyze. Save. The whole loop in three taps.")
                                    .appFont(.body).foregroundStyle(Color.textBody)
                                Text("→ Get instant and structured results")
                                    .appFont(.body).fontWeight(.bold)
                                    .foregroundStyle(Color.greenCalorie)
                            }
                            BrandCard(onTap: {}) {
                                Text("Tap me").appFont(.displayMD).foregroundStyle(Color.textPrimary)
                                Text("This card responds to press with a -5pt lift and a deeper shadow.")
                                    .appFont(.body).foregroundStyle(Color.textBody)
                            }
                        }

                        Section("CircleActionButton — save / cancel", anchor: .circles) {
                            HStack(spacing: AppSpacing.lg) {
                                CircleActionButton(kind: .cancel) {}
                                CircleActionButton(kind: .save) {}
                            }
                        }

                        Section("SpeechBubble", anchor: .bubble) {
                            SpeechBubble(
                                text: "E = mc²… and a slice of pizza ≈ 285 kcal.",
                                coachName: "Albert Einstein"
                            )
                            SpeechBubble(
                                text: "Hark! This dish containeth more sugar than the Globe Theatre's punch bowl. Pace thyself.",
                                coachName: "William Shakespeare"
                            )
                        }

                        Section("BouncingBadge — free / reminder", anchor: .badges) {
                            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                                HStack {
                                    BouncingBadge(text: "free!", style: .free)
                                    Spacer()
                                }
                                .padding(AppSpacing.md)
                                .background(Color.brandCream, in: RoundedRectangle(cornerRadius: AppRadius.md))

                                BouncingBadge(text: "Daily tracker resets every 12:00 am",
                                              style: .reminder)
                                    .padding(AppSpacing.md)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        LinearGradient(colors: [.brand, .brandBright],
                                                       startPoint: .topTrailing, endPoint: .bottomLeading),
                                        in: RoundedRectangle(cornerRadius: AppRadius.lg)
                                    )
                            }
                        }

                        Section("DashedDropZone — empty + filled", anchor: .drop) {
                            HStack(alignment: .top, spacing: AppSpacing.lg) {
                                DashedDropZone(image: nil) {}
                                    .scaleEffect(0.5, anchor: .topLeading)
                                    .frame(width: 160, height: 160)
                                DashedDropZoneSurface(
                                    image: UIImage(systemName: "fork.knife.circle.fill")?
                                        .withTintColor(.systemBrown,
                                                       renderingMode: .alwaysOriginal),
                                    isPressed: true
                                )
                                .scaleEffect(0.5, anchor: .topLeading)
                                .frame(width: 160, height: 160)
                            }
                        }

                        Section("AnalysisPanel — three variants, typewriter live",
                                anchor: .panels) {
                            VStack(spacing: AppSpacing.lg) {
                                AnalysisPanel(
                                    kind: .nutrients,
                                    title: "Nutrients",
                                    items: [
                                        "Calcium: bone health — score 70",
                                        "Lycopene: antioxidant",
                                        "Protein: muscle synthesis"
                                    ],
                                    startTyping: true
                                ).id("nutrients-\(typewriterKey)")

                                AnalysisPanel(
                                    kind: .benefits,
                                    title: "Benefits",
                                    items: [
                                        "Provides calcium for bone health",
                                        "Contains lycopene from sauce",
                                        "Source of protein from cheese"
                                    ],
                                    startTyping: true
                                ).id("benefits-\(typewriterKey)")

                                AnalysisPanel(
                                    kind: .drawbacks,
                                    title: "Drawbacks",
                                    items: [
                                        "High in refined carbs",
                                        "Sodium content elevated",
                                        "Consider whole-grain crust"
                                    ],
                                    startTyping: true
                                ).id("drawbacks-\(typewriterKey)")

                                Button("Restart typewriter") { typewriterKey += 1 }
                                    .buttonStyle(.bordered)
                            }
                        }

                        Section("BlurredNavBar — see top of screen", anchor: .nav) {
                            Text("Material translucency is visible only over scrolling content. The bar is mounted at the top of this gallery; scroll up to see it.")
                                .appFont(.body).foregroundStyle(Color.textBody)
                        }

                        Spacer().frame(height: 80)
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                .background(Color.brandIvory.ignoresSafeArea())
                .onAppear {
                    if let s = ProcessInfo.processInfo.environment["LAUNCH_COMPONENT_GALLERY_SECTION"],
                       let anchor = Anchor(rawValue: s) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(nil) { proxy.scrollTo(anchor.rawValue, anchor: .top) }
                        }
                    }
                }
            }

            BlurredNavBar {
                PillButton(title: "Sign Up!", variant: .primary) {}
                    .scaleEffect(0.55, anchor: .trailing)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - Section helper

    @ViewBuilder
    private func Section<Content: View>(_ title: String,
                                        anchor: Anchor,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(title)
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)
            content()
        }
        .id(anchor.rawValue)
    }
}
