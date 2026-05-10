import SwiftUI

/// Phase 14: 64pt-tall white pill rendering one macro on the Result screen.
/// Three or four chips sit in a horizontal row.
///
/// Layout (matches mockup-2-result.svg, lines 75–93):
///   - eyebrow label at top in `inkLight`, +1.5 tracking
///   - large number in `chipNumber` (20pt Nunito ExtraBold, kern -0.3)
///   - "g" unit in 12pt `inkMute` baseline-aligned with the digits
///
/// `MacroChip.more(count:)` is the brand-soft "+N more" variant that
/// expands the chip row when tapped. Same outer geometry, different fill.
struct MacroChip: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).eyebrow()
                .foregroundStyle(Color.inkLight)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text.number(value)
                    .appFont(.chipNumber)
                    .foregroundStyle(Color.ink)
                Text(unit)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 78, height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(value)) \(unit)")
    }

    /// "+N more" variant — same geometry, brand-soft fill, brand-deep ink.
    /// Wrap in a Button at the call site to make it tappable.
    static func more(count: Int) -> some View {
        VStack(spacing: 2) {
            Text.number(count)
                .appFont(.chipNumber)
                .foregroundStyle(Color.brandDeep)
                .overlay(alignment: .leading) {
                    Text("+")
                        .appFont(.chipNumber)
                        .foregroundStyle(Color.brandDeep)
                        .offset(x: -14)
                }
            Text("more")
                .appFont(.caption)
                .foregroundStyle(Color.brandDeep)
        }
        .frame(width: 78, height: 64)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandSoft)
        )
        .accessibilityLabel("\(count) more macros")
    }
}

#if DEBUG
#Preview("MacroChip — row of three + more") {
    HStack(spacing: AppSpacing.sm) {
        MacroChip(label: "Carbs",   value: 35, unit: "g")
        MacroChip(label: "Sugar",   value: 4,  unit: "g")
        MacroChip(label: "Protein", value: 12, unit: "g")
        MacroChip.more(count: 3)
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
