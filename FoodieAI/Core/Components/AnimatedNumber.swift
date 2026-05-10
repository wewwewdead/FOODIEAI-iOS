import SwiftUI

/// Phase 13: animated numerical text. Combines two effects:
///   - `.contentTransition(.numericText(value:))` (iOS 16+) gives the
///     digit-roll animation when the displayed string changes.
///   - `displayed: Double` interpolates from old to new under
///     `.appNumberTick` so totals "tick up" from a previous value rather
///     than jumping. The `.contentTransition` consumes the intermediate
///     digit changes, so even when the number rolls through 327 → 412
///     each digit transitions smoothly.
///
/// First-paint behavior: `displayed` initializes to 0. On `.onAppear`,
/// the first interpolation runs from 0 → value, giving a count-up
/// entrance. Pass `animateOnAppear: false` to skip this and start at
/// the value immediately (useful when the number is already on screen
/// from a previous render and a fresh appearance shouldn't replay it).
struct AnimatedNumber: View {
    let value: Double
    var formatter: (Double) -> String = { Self.defaultFormatter($0) }
    var animateOnAppear: Bool = true

    @State private var displayed: Double = 0
    @State private var didAppear: Bool = false

    var body: some View {
        Text(formatter(displayed))
            .contentTransition(.numericText(value: displayed))
            .monospacedDigit()
            .onAppear {
                if animateOnAppear, !didAppear {
                    withAnimation(.appNumberTick) {
                        displayed = value
                    }
                } else {
                    displayed = value
                }
                didAppear = true
            }
            .onChange(of: value) { _, newValue in
                withAnimation(.appNumberTick) {
                    displayed = newValue
                }
            }
    }

    /// Default: integer if the value rounds cleanly, one decimal otherwise.
    private static func defaultFormatter(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "—" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }

    /// Convenience: integer-only formatter, no decimals.
    static let integerFormatter: (Double) -> String = { v in
        guard !v.isNaN, !v.isInfinite else { return "—" }
        return "\(Int(v.rounded()))"
    }
}

/// Compact totals line — "Total sugar: 12g" with animated number. Used by
/// the Today / Week / Month gradient header cards and the day-detail
/// totals area. Composes Text + AnimatedNumber + Text in an HStack so the
/// digit-roll animation only affects the number itself.
///
/// Caller styles the whole line (font/weight/foregroundStyle) — these
/// modifiers propagate down to all three children.
struct TotalLine: View {
    let label: String
    let value: Double
    var unit: String? = "g"
    var formatter: (Double) -> String = AnimatedNumber.integerFormatter

    var body: some View {
        HStack(spacing: 0) {
            Text("\(label): ")
            AnimatedNumber(value: value, formatter: formatter)
            if let unit { Text(unit) }
        }
    }
}

#if DEBUG
private struct AnimatedNumberPreview: View {
    @State private var n: Double = 0
    var body: some View {
        VStack(spacing: 24) {
            AnimatedNumber(value: n)
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundStyle(Color.greenCalorie)
            HStack(spacing: 12) {
                Button("0")    { n = 0 }
                Button("325")  { n = 325 }
                Button("1850") { n = 1850 }
                Button("+50")  { n += 50 }
            }
            .buttonStyle(.bordered)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandCream)
    }
}

#Preview("AnimatedNumber") {
    AnimatedNumberPreview()
}
#endif
