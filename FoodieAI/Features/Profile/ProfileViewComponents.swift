import SwiftUI
import UIKit

// Extracted from ProfileView.swift (2026-07) to shrink the file.
// Profile UI helpers: pressable-row button style, decorative dot grid, staggered-appearance modifier, and the goal number field. Types are module-scoped so the parent view still references them.

// MARK: - Press-on-tap style for nav rows / chips

struct PressableRowStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

// MARK: - Decorative dot grid for the hero card

struct DotGridDecoration: View {
    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 18
            let radius: CGFloat = 1.4
            let cols = Int(size.width / spacing) + 1
            let rows = Int(size.height / spacing) + 1
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = CGFloat(c) * spacing + (r.isMultiple(of: 2) ? 0 : spacing / 2)
                    let y = CGFloat(r) * spacing
                    let rect = CGRect(x: x, y: y,
                                      width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(.greenCalorie.opacity(0.5)))
                }
            }
        }
    }
}

// MARK: - Staggered entrance modifier

struct StaggeredAppearance: ViewModifier {
    let index: Int
    let appeared: Bool
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 28)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.85)
                    .delay(Double(index) * 0.06),
                value: appeared
            )
    }
}

extension View {
    func staggered(_ index: Int, appeared: Bool) -> some View {
        modifier(StaggeredAppearance(index: index, appeared: appeared))
    }
}

// MARK: - Goal number field

/// Numeric text input for daily goals. Replaces the prior `Stepper`
/// affordance — users with goals like "2350" no longer have to tap +/-
/// 47 times.
///
/// Behavior:
///   - `.numberPad` keyboard, no decimal/sign keys.
///   - The buffer is filtered to ASCII digits 0–9 on every change, so
///     a paste of "2,400" or "300g" lands as "2400" / "300".
///   - Out-of-range values are clamped to the row's bounds; the buffer
///     is rewritten so the displayed text always matches the bound Int.
///   - Empty buffer is allowed *while editing* (so the user can clear
///     and retype) but normalizes to the row's lower bound on blur.
struct GoalNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    @State private var buffer: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $buffer)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.font(.kcal))
                .fontWeight(.heavy)
                .foregroundStyle(isFocused ? Color.brandDeep : Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(minWidth: 60, maxWidth: 130, alignment: .trailing)
                .focused($isFocused)
                .tint(Color.brand)
                .onAppear { buffer = String(value) }
                .onChange(of: value) { _, newValue in
                    if Int(buffer) != newValue {
                        buffer = String(newValue)
                    }
                }
                .onChange(of: buffer) { _, newText in
                    let filtered = newText.filter { ("0"..."9").contains($0) }
                    if filtered != newText {
                        buffer = filtered
                        return
                    }
                    guard !filtered.isEmpty, let parsed = Int(filtered) else {
                        return
                    }
                    let clamped = min(max(parsed, range.lowerBound),
                                      range.upperBound)
                    let normalized = String(clamped)
                    if normalized != filtered {
                        buffer = normalized
                        return
                    }
                    if clamped != value {
                        value = clamped
                        Haptics.selection()
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        if buffer.isEmpty {
                            value = range.lowerBound
                            buffer = String(value)
                        } else if Int(buffer) != value {
                            buffer = String(value)
                        }
                    }
                }
                .animation(.appPress, value: isFocused)

            if !unit.isEmpty {
                Text(unit)
                    .appFont(.kcal)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.textMeta)
                    .monospacedDigit()
            }
        }
    }
}
