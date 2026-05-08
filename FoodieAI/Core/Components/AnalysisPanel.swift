import SwiftUI

/// Web equivalent: `.analysis-column` and its `.benefits` / `.drawbacks`
/// modifiers (HomePage). 8pt panelBorder inner stroke, lg radius, md
/// padding, min-height 200pt. Body is typewriter-rendered, one item at a
/// time at 20ms/char.
struct AnalysisPanel: View {
    enum Kind {
        case nutrients, benefits, drawbacks

        var fill: Color {
            switch self {
            case .nutrients: .brand
            case .benefits:  .panelBenefits
            case .drawbacks: .panelDrawbacks
            }
        }

        var textColor: Color {
            switch self {
            case .nutrients: .greenAnalysis
            case .benefits:  .textPrimary
            case .drawbacks: .textPrimary
            }
        }

        /// Bundled brand SVGs from the web client (Phase 3 follow-up). Each
        /// imageset uses Single-Scale + preserves-vector-representation; the
        /// path fills are `currentColor` so SwiftUI's `.foregroundStyle`
        /// tints them via template rendering.
        var iconAssetName: String {
            switch self {
            case .nutrients: "PanelIcons/nutrients"
            case .benefits:  "PanelIcons/benefits"
            case .drawbacks: "PanelIcons/drawbacks"
            }
        }
    }

    let kind: Kind
    let title: String
    let items: [String]
    let startTyping: Bool

    @StateObject private var controller: TypewriterController

    init(kind: Kind, title: String, items: [String], startTyping: Bool) {
        self.kind = kind
        self.title = title
        self.items = items
        self.startTyping = startTyping
        self._controller = StateObject(wrappedValue: TypewriterController(items: items))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Image(kind.iconAssetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(kind.textColor)
                Text(title)
                    .appFont(.displayMD)
                    .foregroundStyle(kind.textColor)
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(Array(controller.displayedText.enumerated()), id: \.offset) { _, line in
                    if !line.isEmpty {
                        Text(line)
                            .appFont(.body)
                            .foregroundStyle(kind.textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(kind.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 8)
        )
        .onChange(of: items) { _, newItems in
            controller.reset(items: newItems)
            if startTyping { controller.start() }
        }
        .onChange(of: startTyping) { _, started in
            if started { controller.start() } else { controller.reset() }
        }
        .onAppear {
            if startTyping { controller.start() }
        }
    }
}

#Preview("AnalysisPanel — three variants") {
    AnalysisPanelPreview()
}

private struct AnalysisPanelPreview: View {
    @State private var typingKey = 0
    @State private var startTyping = true

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                Button("Restart typewriter") {
                    startTyping = false
                    typingKey += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        startTyping = true
                    }
                }
                .buttonStyle(.bordered)

                AnalysisPanel(
                    kind: .nutrients,
                    title: "Nutrients",
                    items: [
                        "Calcium: bone health — score 70",
                        "Lycopene: antioxidant",
                        "Protein: muscle synthesis"
                    ],
                    startTyping: startTyping
                ).id("nutrients-\(typingKey)")

                AnalysisPanel(
                    kind: .benefits,
                    title: "Benefits",
                    items: [
                        "Provides calcium for bone health",
                        "Contains lycopene from tomato sauce",
                        "Source of protein from cheese"
                    ],
                    startTyping: startTyping
                ).id("benefits-\(typingKey)")

                AnalysisPanel(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: [
                        "High in refined carbs",
                        "Sodium content can be elevated",
                        "Consider whole-grain crust"
                    ],
                    startTyping: startTyping
                ).id("drawbacks-\(typingKey)")
            }
            .padding(AppSpacing.lg)
        }
        .background(Color.brandIvory)
    }
}
