import SwiftUI

/// Visual roll-call for every Phase 3 component. Reachable via the
/// `FoodieAI-ComponentGallery` Xcode scheme.
struct ComponentGallery: View {
    /// Anchors so the screenshot harness can scroll to a specific section
    /// via the LAUNCH_COMPONENT_GALLERY_SECTION env var.
    private enum Anchor: String {
        case pills, cards, circles, bubble, drop, panels, badges, nav
        // v2 (Phase 14)
        case v2, v2hero, v2chips, v2ring, v2bars, v2meal, v2accordion
        case v2quote, v2coach, v2button, v2segment
    }

    @State private var dropImage: UIImage? = nil
    @State private var typewriterKey = 0
    /// Phase 14: drives the gallery's segmented-control demo.
    @State private var v2DemoSegment: V2DemoSegment = .today

    /// Phase 14 demo segment used solely by the gallery preview row.
    enum V2DemoSegment: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week", month = "Month"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                        Spacer().frame(height: 64) // clear nav bar

                        v2Sections.id(Anchor.v2.rawValue)

                        Divider().background(Color.borderHairline)
                        Text("v1 (legacy — Phase 0–13 components)")
                            .appFont(.title1)
                            .foregroundStyle(Color.inkMute)

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
                .background(Color.bgCanvas.ignoresSafeArea())
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

    // MARK: - v2 sections (Phase 14)

    /// Ten new components, each in its own labeled block.
    @ViewBuilder
    private var v2Sections: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl2) {
            HStack(spacing: AppSpacing.sm) {
                Text("v2")
                    .appFont(.title1)
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm).fill(Color.brandSoft)
                    )
                Text("redesign components")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
            }

            v2Block(title: "HeroNumber", anchor: .v2hero) {
                HeroNumber(label: "Calories", value: 285,
                            unit: "of 2,000", size: .large)
            }

            v2Block(title: "MacroChip", anchor: .v2chips) {
                HStack(spacing: AppSpacing.sm) {
                    MacroChip(label: "Carbs",   value: 35, unit: "g")
                    MacroChip(label: "Sugar",   value: 4,  unit: "g")
                    MacroChip(label: "Protein", value: 12, unit: "g")
                    MacroChip.more(count: 3)
                }
            }

            v2Block(title: "ProgressRing", anchor: .v2ring) {
                ProgressRing(value: 1247, goal: 2000, label: "Calories")
                    .frame(maxWidth: .infinity)
            }

            v2Block(title: "MacroProgressBar", anchor: .v2bars) {
                VStack(spacing: AppSpacing.lg) {
                    MacroProgressBar(label: "Carbs",   value: 142, goal: 250, tint: .brand)
                    MacroProgressBar(label: "Sugar",   value: 28,  goal: 50,  tint: .accentWarm)
                    MacroProgressBar(label: "Protein", value: 52,  goal: 90,  tint: .accentCool)
                }
            }

            v2Block(title: "MealCard", anchor: .v2meal) {
                VStack(spacing: AppSpacing.md) {
                    MealCard(log: GalleryFixtures.pizza, onTap: {})
                    MealCard(log: GalleryFixtures.salad, onTap: {})
                }
            }

            v2Block(title: "CategoryAccordion", anchor: .v2accordion) {
                VStack(spacing: AppSpacing.md) {
                    CategoryAccordion(
                        kind: .nutrients, title: "Nutrients",
                        items: [
                            "Calcium: bone health — score 70",
                            "Lycopene: antioxidant",
                            "Protein: muscle synthesis"
                        ],
                        startsExpanded: true
                    )
                    CategoryAccordion(
                        kind: .benefits, title: "Benefits",
                        items: [
                            "Provides calcium for bone health",
                            "Contains lycopene from tomato sauce"
                        ]
                    )
                    CategoryAccordion(
                        kind: .drawbacks, title: "Drawbacks",
                        items: [
                            "High in refined carbs",
                            "Sodium content can be elevated"
                        ]
                    )
                }
            }

            v2Block(title: "EditorialQuote", anchor: .v2quote) {
                EditorialQuote(
                    text: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself.",
                    attribution: "Albert Einstein"
                )
            }

            v2Block(title: "CoachBadge", anchor: .v2coach) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 232/255, green: 184/255, blue: 92/255),
                                Color(red: 154/255, green:  74/255, blue: 31/255)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(height: 200)
                    CoachBadge(name: "Albert Einstein")
                        .padding(20)
                }
            }

            v2Block(title: "PrimaryButton", anchor: .v2button) {
                VStack(spacing: AppSpacing.md) {
                    PrimaryButton(title: "Take a photo",
                                  leadingSystemImage: "camera.fill") {}
                    PrimaryButton(title: "Save to today") {}
                }
            }

            v2Block(title: "AppSegmentedControl", anchor: .v2segment) {
                AppSegmentedControl<V2DemoSegment>(
                    selection: $v2DemoSegment,
                    titleProvider: { $0.rawValue }
                )
                Text("Selected: \(v2DemoSegment.rawValue)")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .padding(.top, AppSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private func v2Block<Content: View>(title: String,
                                        anchor: Anchor,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(title).eyebrow()
                .foregroundStyle(Color.inkMute)
            content()
        }
        .id(anchor.rawValue)
    }

    // MARK: - Section helper (v1)

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

/// Phase 14: shared `FoodLog` fixtures used by gallery v2 sections so we
/// don't duplicate the verbose memberwise init across multiple previews.
private enum GalleryFixtures {
    static let pizza: FoodLog = make(
        name: "Margherita Pizza",
        calories: 285, carbs: 35, sugar: 4, protein: 12,
        time: "12:30 PM"
    )
    static let salad: FoodLog = make(
        name: "Greek Salad",
        calories: 962, carbs: 107, sugar: 24, protein: 40,
        time: "7:15 AM"
    )

    private static func make(name: String,
                             calories: Double,
                             carbs: Double,
                             sugar: Double,
                             protein: Double,
                             time: String) -> FoodLog {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        let parsed = f.date(from: time) ?? Date()
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbs,
            sugarG: sugar,
            proteinG: protein,
            fatG: nil,
            fiberG: nil,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: parsed,
            createdAt: Date(),
            origin: .analyzed,
            sourceLogId: nil,
            mood: nil
        )
    }
}
