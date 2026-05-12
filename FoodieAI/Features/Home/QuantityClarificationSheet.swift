import SwiftUI

/// Quantity Clarification — sheet presented when first-pass /analyze
/// returns a non-empty `portionAmbiguousItems`.
///
/// One row per ambiguous item with three preset buttons: Less / About
/// this / More. The assumed quantity ("1 cup", "1 bowl", …) is parsed
/// for its leading number; the preset rows halve / preserve / double
/// that number while keeping the unit string intact. When parsing
/// fails — the model returned a non-numeric quantity like "small
/// portion" — the buttons fall back to generic labels ("Half portion"
/// / "About this" / "Double portion") and pass through descriptive
/// strings.
///
/// "Update analysis" sends the chosen quantities upstream via
/// `onConfirm`, which routes through `CaptureViewModel.refineAnalysis`.
/// "Looks about right" (and drag-to-dismiss) routes through
/// `onDismiss` → `acceptOriginalAnalysis`, reusing the first-pass
/// analysis with no second network call.
struct QuantityClarificationSheet: View {
    let items: [GeminiAnalysis.AmbiguousItem]
    let onConfirm: ([String: String]) -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Per-item user choice. Defaults to `.about` (no change). Keyed by
    /// `AmbiguousItem.name` since the server guarantees uniqueness
    /// within a single response.
    @State private var choices: [String: QuantityChoice] = [:]

    /// Fix A — track whether the user confirmed (Update Analysis).
    /// On confirm we let `refineAnalysis` flip state to `.analyzing`
    /// and SwiftUI dismisses the sheet via the state-driven binding;
    /// `onDisappear` must not then fire `onDismiss` and stomp the
    /// refine. For "Looks about right" / drag-to-dismiss, didConfirm
    /// stays false and `onDisappear` routes through `onDismiss`.
    @State private var didConfirm: Bool = false

    enum QuantityChoice: Hashable { case less, about, more }

    var body: some View {
        ZStack {
            Color.brandIvory.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    header

                    VStack(spacing: AppSpacing.sm) {
                        ForEach(items) { item in
                            QuantityRow(
                                item: item,
                                selection: Binding(
                                    get: { choices[item.name] ?? .about },
                                    set: { newValue in
                                        Haptics.tap()
                                        choices[item.name] = newValue
                                    }
                                )
                            )
                        }
                    }

                    PrimaryButton(title: "Update analysis",
                                  leadingSystemImage: "sparkles") {
                        handleConfirm()
                    }
                    .padding(.top, AppSpacing.sm)

                    Button {
                        // Fix A — call onDismiss; state transitions
                        // .clarifying → .ready, sheet auto-dismisses.
                        // No explicit dismiss() — the state machine
                        // is the single source of truth for
                        // visibility now.
                        Haptics.tap()
                        onDismiss()
                    } label: {
                        Text("Looks about right")
                            .appFont(.captionStrong)
                            .foregroundStyle(Color.inkMute)
                            .padding(.vertical, AppSpacing.sm)
                            .padding(.horizontal, AppSpacing.lg)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep the original analysis — looks about right")
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
        }
        .onAppear {
            // Initialize defaults so binding reads are stable even
            // before the user touches a row.
            for item in items where choices[item.name] == nil {
                choices[item.name] = .about
            }
        }
        .onDisappear {
            // Fix A — sheet went away. If the user confirmed (Update
            // Analysis), didConfirm is true and the view model is
            // already off the `.clarifying` state running the refine;
            // do nothing. Otherwise — drag-to-dismiss, swipe, or
            // anything that bypassed the explicit buttons — route
            // through `onDismiss` so the view model lands in `.ready`
            // with the original analysis. Calling onDismiss when the
            // VM is already past `.clarifying` is harmless: the guard
            // in `acceptOriginalAnalysis` makes it a no-op.
            if !didConfirm {
                NSLog("[Clarify] onDisappear without confirm — calling onDismiss")
                onDismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("How much of this?")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            Text("We weren't sure about a few portion sizes. Adjust if needed, or tap \"Looks about right\".")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
    }

    private func handleConfirm() {
        Haptics.tap()
        // Build {name → chosen quantity string}. Items left on .about
        // are still sent through so the prompt sees the explicit
        // assumed quantity — leaving them out would let the model
        // re-default, which is fine but feels less deliberate.
        var payload: [String: String] = [:]
        for item in items {
            let choice = choices[item.name] ?? .about
            payload[item.name] = Self.formattedQuantity(for: item, choice: choice)
        }
        NSLog("[Clarify] Update tapped; quantities=%@ count=%d",
              "\(payload)", payload.count)
        // Fix A — mark confirm BEFORE invoking the callback so when
        // the state-driven dismissal lands and `.onDisappear` fires,
        // the flag is already true and we don't double-route into
        // `acceptOriginalAnalysis`. Do NOT call `dismiss()` here —
        // the view model's transition to `.analyzing` is what makes
        // the sheet disappear, which keeps the state machine as the
        // single source of truth.
        didConfirm = true
        onConfirm(payload)
    }

    // MARK: - Quantity formatting

    /// Convert (item, choice) into the user-facing quantity string we
    /// send back to the server. Tries to parse the leading number from
    /// `assumedQuantity` so we can halve/double it; falls back to
    /// descriptive labels when the assumed quantity has no number.
    static func formattedQuantity(for item: GeminiAnalysis.AmbiguousItem,
                                  choice: QuantityChoice) -> String {
        if let parsed = ParsedQuantity(raw: item.assumedQuantity) {
            switch choice {
            case .less:  return parsed.scaled(by: 0.5)
            case .about: return parsed.original
            case .more:  return parsed.scaled(by: 2.0)
            }
        }
        // No leading number — use descriptive variants.
        switch choice {
        case .less:  return "Half portion"
        case .about: return item.assumedQuantity
        case .more:  return "Double portion"
        }
    }
}

// MARK: - Row

private struct QuantityRow: View {
    let item: GeminiAnalysis.AmbiguousItem
    @Binding var selection: QuantityClarificationSheet.QuantityChoice

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.capitalized)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                Text("Assumed: \(item.assumedQuantity)")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }

            HStack(spacing: AppSpacing.xs) {
                PresetButton(label: "Less",
                             sub: subLabel(for: .less),
                             isSelected: selection == .less) {
                    selection = .less
                }
                PresetButton(label: "About this",
                             sub: subLabel(for: .about),
                             isSelected: selection == .about) {
                    selection = .about
                }
                PresetButton(label: "More",
                             sub: subLabel(for: .more),
                             isSelected: selection == .more) {
                    selection = .more
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private func subLabel(for choice: QuantityClarificationSheet.QuantityChoice) -> String {
        QuantityClarificationSheet.formattedQuantity(for: item, choice: choice)
    }
}

private struct PresetButton: View {
    let label: String
    let sub: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .appFont(.captionStrong)
                    .foregroundStyle(isSelected ? Color.ink : Color.inkMute)
                Text(sub)
                    .appFont(.caption)
                    .foregroundStyle(isSelected ? Color.brandDeep : Color.inkLight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.vertical, AppSpacing.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(isSelected ? Color.brandSoft : Color.bgCanvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.appPress, value: isSelected)
        .accessibilityLabel("\(label), \(sub)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Quantity parsing

/// Parses a quantity string like "1 cup", "2 bowls", "1.5 scoops", or
/// "½ cup" into a numeric leading component and the trailing unit.
/// When `init` returns non-nil, `scaled(by:)` can produce halved or
/// doubled variants while preserving the unit text.
///
/// Conservative on purpose: handles plain decimals and a small set
/// of common single-glyph fractions. Anything else returns nil so the
/// caller can fall back to descriptive labels.
private struct ParsedQuantity {
    let number: Double
    let unit: String
    let original: String

    init?(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Try unicode-fraction prefix first.
        let fractionMap: [Character: Double] = [
            "½": 0.5, "⅓": 1.0/3, "⅔": 2.0/3,
            "¼": 0.25, "¾": 0.75,
            "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8,
        ]
        if let first = trimmed.first, let value = fractionMap[first] {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            self.number = value
            self.unit = rest
            self.original = trimmed
            return
        }

        // Plain decimal prefix.
        let scanner = Scanner(string: trimmed)
        scanner.charactersToBeSkipped = nil
        guard let value = scanner.scanDouble(), value > 0 else { return nil }

        let rest = String(trimmed[scanner.currentIndex...])
            .trimmingCharacters(in: .whitespaces)
        self.number = value
        self.unit = rest
        self.original = trimmed
    }

    /// Return a formatted "<number> <unit>" string scaled by `factor`.
    /// Number formatting strips trailing zeros and avoids decimals
    /// when the result is an integer; halves render as "½" for the
    /// common 1→½ case so the row reads naturally.
    func scaled(by factor: Double) -> String {
        let scaled = number * factor
        let label = Self.format(number: scaled)
        return unit.isEmpty ? label : "\(label) \(unit)"
    }

    private static func format(number: Double) -> String {
        // Common pretty fractions for clean halving.
        if abs(number - 0.5) < 0.001 { return "½" }
        if abs(number - 0.25) < 0.001 { return "¼" }
        if abs(number - 0.75) < 0.001 { return "¾" }

        if abs(number.rounded() - number) < 0.001 {
            return String(Int(number.rounded()))
        }
        // Up to one decimal place, no trailing zero.
        let s = String(format: "%.1f", number)
        return s
    }
}

#if DEBUG
#Preview("QuantityClarificationSheet") {
    QuantityClarificationSheet(
        items: [
            .init(name: "rice", assumedQuantity: "1 cup"),
            .init(name: "miso soup", assumedQuantity: "1 bowl"),
        ],
        onConfirm: { _ in },
        onDismiss: {}
    )
}
#endif
