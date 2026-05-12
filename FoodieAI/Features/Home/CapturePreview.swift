#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only helper used by `LAUNCH_CAPTURE_SAMPLE=<state>` to render a
/// CaptureView-equivalent layout in any of its non-idle states without
/// needing a running Express server or simulator UI taps. Used in Phase 5
/// verification to capture screenshots of `picked`, `analyzing`, `ready`,
/// `noFood`, and `failed` states.
///
/// Valid values for the env var:
///   - "picked"     → photo loaded, awaiting analyze tap
///   - "analyzing"  → request mid-flight (spinner)
///   - "ready"      → success result with sample analysis
///   - "noFood"     → server returned `fallback`
///   - "failed"     → analyzer threw an error
///   - "panels"     → ONLY the three sequenced AnalysisPanels at top of
///                     screen; lets a single screenshot see the typewriter
///                     coordinator advancing through nutrients → benefits
///                     → drawbacks without scrolling.
enum CapturePreview {
    @ViewBuilder
    static func view(forSample sample: String) -> some View {
        SampleCaptureContainer(sample: sample)
    }
}

/// LAUNCH_CAPTURE_LIVE entry point. Loads an image into a real
/// `CaptureViewModel` and immediately triggers `analyze()` — which runs the
/// full production pipeline: `ImagePreparation.compress` →
/// `AnalyzeService.analyze` → multipart POST → JSON decode → state
/// transition. No mocking.
///
/// Env values:
///   - `LAUNCH_CAPTURE_LIVE=1` (or anything else): use the bundled
///     `LandingHero` food photo — exercises the `.ready` path.
///   - `LAUNCH_CAPTURE_LIVE=nofood`: render a programmatically-generated
///     plain-text image — exercises the `.noFood` path so we can verify
///     the live `fallback: "No food detected"` server response.
///   - `LAUNCH_CAPTURE_LIVE=save`: same as the food path, but chains
///     `viewModel.save()` immediately after `.ready` is reached —
///     exercises the upload + insert pipeline against Supabase. Requires
///     a signed-in session; without one the call routes to `.saveFailed`
///     with `FoodImageError.notSignedIn`, which is itself useful evidence
///     that the save error path is wired correctly.
struct LiveAnalyzeProbeView: View {
    @StateObject private var viewModel = CaptureViewModel()
    @State private var didTrigger = false

    private var useNonFoodImage: Bool {
        ProcessInfo.processInfo.environment["LAUNCH_CAPTURE_LIVE"] == "nofood"
    }

    private var chainSaveAfterReady: Bool {
        ProcessInfo.processInfo.environment["LAUNCH_CAPTURE_LIVE"] == "save"
    }

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    DashedDropZone(image: viewModel.state.image) {}
                    analyzeButton
                    resultSection
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.xl3)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            guard !didTrigger else { return }
            didTrigger = true
            let image: UIImage? = useNonFoodImage
                ? Self.makeNonFoodImage()
                : UIImage(named: "LandingHero")
            guard let image else {
                NSLog("[LiveProbe] FAILED to load image")
                return
            }
            let label = useNonFoodImage ? "non-food (generated)" : "food (LandingHero)"
            viewModel.setPhoto(image)
            NSLog("[LiveProbe] %@ photo loaded (%.0fx%.0f); calling analyze()",
                  label, image.size.width, image.size.height)
            await viewModel.analyze()
            NSLog("[LiveProbe] analyze() returned; state=%@",
                  String(describing: viewModel.state))

            if chainSaveAfterReady {
                if case .ready = viewModel.state {
                    NSLog("[LiveProbe] chaining save() after .ready")
                    await viewModel.save()
                    NSLog("[LiveProbe] save() returned; state=%@",
                          String(describing: viewModel.state))
                } else {
                    NSLog("[LiveProbe] skipping save() — not in .ready (state=%@)",
                          String(describing: viewModel.state))
                }
            }
        }
    }

    /// Generates a plain text image with no food content — Gemini should
    /// route this to the no-food branch via the `fallback` field.
    private static func makeNonFoodImage() -> UIImage {
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            let text = "PHASE 5 NON-FOOD TEST\n\nThis is a screenshot of text — there is no food in this image. The analyzer should respond with the no-food fallback."
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.black,
                .font: UIFont.systemFont(ofSize: 56, weight: .semibold),
                .paragraphStyle: paragraph
            ]
            let textRect = CGRect(x: 80, y: 200, width: size.width - 160, height: size.height - 400)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    @ViewBuilder
    private var analyzeButton: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .picked:
            PillButton(title: "Analyze", variant: .outline) {
                Task { await viewModel.analyze() }
            }
        case .analyzing:
            PillButton(title: "Analyzing...", variant: .outline, isLoading: true) {}
        case .ready, .noFood, .failed, .saving, .saved, .saveFailed,
             .moodPulse, .clarifying:
            PillButton(title: "Analyze new food", variant: .outline) {}
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch viewModel.state {
        case .ready(let image, let response):
            AnalysisResultView(
                image: image,
                response: response,
                onSave: { Task { await viewModel.save() } },
                onCancel: { NSLog("[LiveProbe] cancel tapped") }
            )
        case .saving(let image, let response):
            AnalysisResultView(
                image: image,
                response: response,
                isSaving: true,
                onSave: {},
                onCancel: {}
            )
        case .saved(let image, let response, _):
            AnalysisResultView(
                image: image,
                response: response,
                onSave: {},
                onCancel: {}
            )
        case .saveFailed(let image, let response, let error):
            VStack(spacing: AppSpacing.lg) {
                AnalysisResultView(
                    image: image,
                    response: response,
                    onSave: { Task { await viewModel.retrySave() } },
                    onCancel: {}
                )
                Text(error.localizedDescription)
                    .appFont(.body)
                    .foregroundStyle(Color.redError)
            }
        case .noFood:
            VStack(spacing: AppSpacing.lg) {
                Text("No food detected!")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.redError)
                Text("Try a clearer photo of a meal, snack, or drink.")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                    .multilineTextAlignment(.center)
            }
            .padding(AppSpacing.lg)
        case .failed(_, let error):
            VStack(spacing: AppSpacing.lg) {
                Text("Something went wrong")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.redError)
                Text(error.errorDescription ?? "")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                    .multilineTextAlignment(.center)
            }
            .padding(AppSpacing.lg)
        case .idle, .picked, .analyzing, .moodPulse, .clarifying:
            EmptyView()
        }
    }
}

private struct SampleCaptureContainer: View {
    let sample: String

    enum Stage {
        case picked, analyzing, ready, noFood, failed, panels, savedSheet
        /// Phase 14: render the new `AnalysisResultView` in isolation
        /// against `bgCanvas`, with no legacy DashedDropZone or
        /// "Analyze new food" PillButton above it.
        case resultV2

        init(_ raw: String) {
            switch raw {
            case "analyzing":   self = .analyzing
            case "ready":       self = .ready
            case "noFood":      self = .noFood
            case "failed":      self = .failed
            case "panels":      self = .panels
            case "saved-sheet": self = .savedSheet
            case "result-v2":   self = .resultV2
            default:            self = .picked
            }
        }
    }

    private var stage: Stage { Stage(sample) }

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            if stage == .resultV2 {
                // Phase 14: render the new AnalysisResultView alone, on
                // the redesign canvas, with the sample image + response
                // populated.
                ZStack {
                    Color.bgCanvas.ignoresSafeArea()
                    ScrollView {
                        AnalysisResultView(
                            image: SamplePayload.image,
                            response: SamplePayload.successResponse,
                            onSave:   {},
                            onCancel: {}
                        )
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xl3)
                    }
                }
            } else if stage == .savedSheet {
                // Show the post-save confirmation in isolation — same
                // .sheet(.medium) presentation the production CaptureView uses.
                Color.bgCanvas.ignoresSafeArea()
                    .sheet(isPresented: .constant(true)) {
                        SavedConfirmationSheet(onClose: {})
                            .presentationDetents([.medium])
                            .presentationDragIndicator(.visible)
                    }
            } else {
                ScrollView {
                    if stage == .panels {
                        SamplePanelsOnlyView(response: SamplePayload.successResponse)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.top, AppSpacing.xl3)
                            .padding(.bottom, AppSpacing.xl3)
                    } else {
                        VStack(spacing: AppSpacing.xl) {
                            DashedDropZone(image: SamplePayload.image) {}
                            analyzeButton
                            resultSection
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.xl3)
                        .padding(.bottom, AppSpacing.xl3)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var analyzeButton: some View {
        switch stage {
        case .picked:
            PillButton(title: "Analyze", variant: .outline) {}
        case .analyzing:
            PillButton(title: "Analyzing...", variant: .outline, isLoading: true) {}
        case .ready, .noFood, .failed:
            PillButton(title: "Analyze new food", variant: .outline) {}
        case .panels, .savedSheet, .resultV2:
            EmptyView()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch stage {
        case .picked, .analyzing, .panels, .savedSheet, .resultV2:
            EmptyView()
        case .ready:
            AnalysisResultView(
                image: SamplePayload.image,
                response: SamplePayload.successResponse,
                onSave: {},
                onCancel: {}
            )
        case .noFood:
            VStack(spacing: AppSpacing.lg) {
                Text("No food detected!")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.redError)
                    .multilineTextAlignment(.center)
                Text("Try a clearer photo of a meal, snack, or drink.")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try another photo", variant: .outline) {}
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity)
        case .failed:
            VStack(spacing: AppSpacing.lg) {
                Text("Something went wrong")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.redError)
                    .multilineTextAlignment(.center)
                Text(AnalyzeError.networkUnavailable.errorDescription ?? "")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again", variant: .outline) {}
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Renders only the three sequenced AnalysisPanels for the "panels" sample
/// mode. Re-implements the same staging logic as
/// `AnalysisResultView.runEntranceSequence` so a single screenshot can show
/// the typewriter chain advancing through nutrients → benefits → drawbacks
/// without the calorie / food / speech-bubble preamble pushing the panels
/// off-screen.
private struct SamplePanelsOnlyView: View {
    let response: AnalyzeResponse

    enum PanelStage: Int, Comparable {
        case none = 0, nutrients = 1, benefits = 2, drawbacks = 3, done = 4
        static func < (lhs: PanelStage, rhs: PanelStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    @State private var stage: PanelStage = .none

    private var nutrientItems: [String] { response.analysis.nutrients ?? [] }
    private var benefitItems:  [String] { response.analysis.benefits ?? [] }
    private var drawbackItems: [String] { response.analysis.drawbacks ?? [] }

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            if stage >= .nutrients {
                AnalysisPanel(
                    kind: .nutrients,
                    title: "Nutrients",
                    items: nutrientItems,
                    startTyping: stage >= .nutrients
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if stage >= .benefits {
                AnalysisPanel(
                    kind: .benefits,
                    title: "Benefits",
                    items: benefitItems,
                    startTyping: stage >= .benefits
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if stage >= .drawbacks {
                AnalysisPanel(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: drawbackItems,
                    startTyping: stage >= .drawbacks
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.appEntrance, value: stage)
        .task {
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 200)
            stage = .nutrients
            try? await Task.sleep(nanoseconds: typewriterNanos(for: nutrientItems))
            stage = .benefits
            try? await Task.sleep(nanoseconds: typewriterNanos(for: benefitItems))
            stage = .drawbacks
            try? await Task.sleep(nanoseconds: typewriterNanos(for: drawbackItems))
            stage = .done
        }
    }

    private func typewriterNanos(for items: [String]) -> UInt64 {
        let chars = items.reduce(0) { $0 + $1.count }
        let seconds = Double(chars) * 0.02 + 0.4
        return UInt64(seconds * 1_000_000_000)
    }
}

/// Static sample data — a small generated image and a hand-written analysis
/// response for a margherita pizza.
private enum SamplePayload {
    static let image: UIImage = generated()

    static let successResponse = AnalyzeResponse(
        analysis: GeminiAnalysis(
            fallback: nil,
            food: "Margherita Pizza",
            calories: 285,
            carbs: 36,
            sugar: 4,
            protein: 12,
            fat: 11,
            fiber: 2,
            benefits: [
                "Provides calcium for bone health",
                "Contains lycopene from tomato sauce",
                "Source of protein from cheese"
            ],
            drawbacks: [
                "High in refined carbs",
                "Sodium content can be elevated",
                "Consider whole-grain crust"
            ],
            nutrients: [
                "Calcium: bone health",
                "Lycopene: antioxidant",
                "Protein: muscle synthesis"
            ],
            coachAdvice: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself.",
            portionAmbiguousItems: nil
        ),
        coach: "Albert Einstein"
    )

    private static func generated() -> UIImage {
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(red: 0.95, green: 0.65, blue: 0.30, alpha: 1).cgColor,
                UIColor(red: 0.85, green: 0.40, blue: 0.20, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            cg.setFillColor(UIColor(red: 0.99, green: 0.92, blue: 0.78, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 40, y: 40, width: 240, height: 240))
        }
    }
}

#endif
