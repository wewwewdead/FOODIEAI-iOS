import SwiftUI

/// Phase 21 — typing-based meal logging.
///
/// Three internal steps managed by `ManualLogViewModel`:
///   .search   → search field + Quick Add chips + result list + custom link
///   .quantity → multiplier picker (½, 1, 1.5, 2 + free numeric)
///   .confirm  → computed totals review + Save
///   .custom   → free-form name + macros entry
///
/// The sheet does not own streak/quest side-effects. After save it
/// fires `onSaved(inserted)` and the host wires those in. This keeps
/// the sheet replaceable / testable without dragging the engagement
/// services into its dependency graph.
struct ManualLogSheet: View {
    /// Called after a successful insert. The host uses this to drop a
    /// success banner, refresh Tracker, kick streak/quest updates, and
    /// dismiss the sheet.
    let onSaved: (FoodLog) -> Void
    let onCancelled: () -> Void

    @StateObject private var viewModel = ManualLogViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    switch viewModel.step {
                    case .search:    searchStep
                    case .quantity:  quantityStep
                    case .confirm:   confirmStep
                    case .custom:    customStep
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl2)
            }
        }
        .background(Color.bgCanvas)
        .task {
            await viewModel.loadQuickAddSuggestions()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            if viewModel.step != .search {
                Button {
                    Haptics.tap()
                    if viewModel.step == .confirm {
                        viewModel.step = .quantity
                    } else {
                        viewModel.goBackToSearch()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.ink)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Back")
            }

            Text(stepTitle)
                .appFont(.display2)
                .foregroundStyle(Color.ink)

            Spacer()

            Button {
                onCancelled()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.inkMute)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    private var stepTitle: String {
        switch viewModel.step {
        case .search:   return "Log a meal"
        case .quantity: return "How much?"
        case .confirm:  return "Confirm"
        case .custom:   return "Custom food"
        }
    }

    // MARK: - Step: search

    @ViewBuilder
    private var searchStep: some View {
        searchField

        addCustomFoodButton

        if viewModel.query.isEmpty, !viewModel.quickAddSuggestions.isEmpty {
            quickAddRow
        }

        resultsList
    }

    private var addCustomFoodButton: some View {
        Button {
            Haptics.tap()
            viewModel.openCustom()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .heavy))
                Text("Add a custom food")
                    .appFont(.captionStrong)
            }
            .foregroundStyle(Color.brandDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.brandSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.inkMute)
            TextField("Search foods", text: $viewModel.query)
                .focused($queryFocused)
                .font(AppFont.font(.body))
                .foregroundStyle(Color.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.inkLight)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private var quickAddRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("QUICK ADD").eyebrow()
                .foregroundStyle(Color.inkMute)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(viewModel.quickAddSuggestions) { log in
                        Button {
                            Haptics.tap()
                            viewModel.selectQuickAdd(log)
                        } label: {
                            Text(log.foodName)
                                .appFont(.captionStrong)
                                .foregroundStyle(Color.brandDeep)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(Color.brandSoft)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = viewModel.searchResults
        if results.isEmpty {
            VStack(spacing: 6) {
                Text("No matches")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
                Text("Use \u{201C}Add a custom food\u{201D} above.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.xl)
        } else {
            VStack(spacing: 0) {
                ForEach(results) { food in
                    Button {
                        Haptics.tap()
                        viewModel.selectCommonFood(food)
                    } label: {
                        searchRow(food: food)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, AppSpacing.md)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.borderHairline, lineWidth: 1)
            )
        }
    }

    private func searchRow(food: CommonFood) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                Text(food.servingDesc)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Spacer()
            Text("\(Int(food.calories.rounded()))")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.brandDeep)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.inkLight)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Step: quantity

    private static let presetMultipliers: [Double] = [0.5, 1.0, 1.5, 2.0]

    @ViewBuilder
    private var quantityStep: some View {
        if let food = viewModel.pickedFood {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(food.name)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                Text(food.servingDesc)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }

            HStack(spacing: AppSpacing.sm) {
                ForEach(Self.presetMultipliers, id: \.self) { value in
                    Button {
                        Haptics.tap()
                        viewModel.quantityMultiplier = value
                    } label: {
                        Text(formatMultiplier(value))
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(
                                viewModel.quantityMultiplier == value
                                    ? Color.ink
                                    : Color.brandDeep
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.lg)
                                    .fill(viewModel.quantityMultiplier == value
                                          ? Color.brand
                                          : Color.brandSoft)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("OR ENTER").eyebrow()
                    .foregroundStyle(Color.inkMute)
                MultiplierField(value: $viewModel.quantityMultiplier)
            }

            // Live preview of the totals at the picked multiplier so
            // the user sees the consequence of changing it before
            // committing.
            quantityPreview

            PrimaryButton(title: "Next", leadingSystemImage: "arrow.right") {
                Haptics.tap()
                viewModel.proceedToConfirm()
            }
            .padding(.top, AppSpacing.sm)
        }
    }

    private func formatMultiplier(_ value: Double) -> String {
        if value == 0.5 { return "½" }
        if value == 1.5 { return "1½" }
        if value == value.rounded() { return "\(Int(value))" }
        return String(format: "%g", value)
    }

    @ViewBuilder
    private var quantityPreview: some View {
        let totals = viewModel.computedTotals
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Calories")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Spacer()
                Text("\(Int(totals.calories.rounded()))")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
            }

            Divider()

            VStack(spacing: 6) {
                macroPreviewRow(label: "Carbs",   value: totals.carbs as Double?)
                macroPreviewRow(label: "Protein", value: totals.protein)
                macroPreviewRow(label: "Fat",     value: totals.fat)
                macroPreviewRow(label: "Fiber",   value: totals.fiber)
                macroPreviewRow(label: "Sugar",   value: totals.sugar)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private func macroPreviewRow(label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
            Spacer()
            Text(value.map { "\(Int($0.rounded()))g" } ?? "—")
                .appFont(.bodyEmphasis)
                .foregroundStyle(value == nil ? Color.inkLight : Color.ink)
                .monospacedDigit()
        }
    }

    // MARK: - Step: confirm

    @ViewBuilder
    private var confirmStep: some View {
        if let food = viewModel.pickedFood {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(food.name)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                let servingLine = abs(viewModel.quantityMultiplier - 1.0) < 0.001
                    ? food.servingDesc
                    : "\(formatMultiplierBare(viewModel.quantityMultiplier))× \(food.servingDesc)"
                Text(servingLine)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }

            quantityPreview

            if let err = viewModel.lastError {
                Text(err)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
            }

            PrimaryButton(
                title: viewModel.isSaving ? "Saving…" : "Save",
                leadingSystemImage: viewModel.isSaving ? nil : "checkmark",
                isLoading: viewModel.isSaving
            ) {
                Task { await commitCommonFoodSave() }
            }
            .padding(.top, AppSpacing.sm)
        }
    }

    private func formatMultiplierBare(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        return String(format: "%g", value)
    }

    private func commitCommonFoodSave() async {
        viewModel.lastError = nil
        viewModel.isSaving = true
        defer { viewModel.isSaving = false }
        do {
            let inserted = try await viewModel.saveCommonFoodEntry()
            Haptics.success()
            onSaved(inserted)
            dismiss()
        } catch {
            #if DEBUG
            NSLog("[ManualLog] save FAILED: %@", "\(error)")
            #endif
            Haptics.error()
            viewModel.lastError = error.localizedDescription
        }
    }

    // MARK: - Step: custom

    @ViewBuilder
    private var customStep: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            customField(
                label: "NAME",
                placeholder: "e.g., Mom's lasagna",
                text: $viewModel.customName,
                keyboard: .default
            )
            customField(
                label: "CALORIES",
                placeholder: "0",
                text: $viewModel.customCalories,
                keyboard: .decimalPad
            )
            customField(
                label: "CARBS (G)",
                placeholder: "0",
                text: $viewModel.customCarbs,
                keyboard: .decimalPad
            )
            customField(
                label: "PROTEIN (G)",
                placeholder: "0",
                text: $viewModel.customProtein,
                keyboard: .decimalPad
            )
            customField(
                label: "FAT (G)",
                placeholder: "0",
                text: $viewModel.customFat,
                keyboard: .decimalPad
            )
            customField(
                label: "FIBER (G)",
                placeholder: "0",
                text: $viewModel.customFiber,
                keyboard: .decimalPad
            )
            customField(
                label: "SUGAR (G)",
                placeholder: "0",
                text: $viewModel.customSugar,
                keyboard: .decimalPad
            )

            if let err = viewModel.lastError {
                Text(err)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
            }

            PrimaryButton(
                title: viewModel.isSaving ? "Saving…" : "Save",
                leadingSystemImage: viewModel.isSaving ? nil : "checkmark",
                isLoading: viewModel.isSaving
            ) {
                Task { await commitCustomSave() }
            }

            Text("Only calories and name are required. Other macros are helpful for your goals but optional.")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private func customField(label: String,
                             placeholder: String,
                             text: Binding<String>,
                             keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).eyebrow()
                .foregroundStyle(Color.inkMute)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(AppFont.font(.body))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(Color.borderHairline, lineWidth: 1)
                )
        }
    }

    private func commitCustomSave() async {
        viewModel.lastError = nil
        viewModel.isSaving = true
        defer { viewModel.isSaving = false }
        do {
            let inserted = try await viewModel.saveCustomEntry()
            Haptics.success()
            onSaved(inserted)
            dismiss()
        } catch {
            #if DEBUG
            NSLog("[ManualLog] custom save FAILED: %@", "\(error)")
            #endif
            Haptics.error()
            viewModel.lastError = error.localizedDescription
        }
    }
}

// MARK: - Free-form multiplier field

/// Small numeric input bound to the multiplier Double. Editing the
/// text re-parses to a multiplier; an invalid string leaves the prior
/// value untouched.
private struct MultiplierField: View {
    @Binding var value: Double
    @State private var text: String = ""

    var body: some View {
        TextField("1.0", text: $text)
            .keyboardType(.decimalPad)
            .font(AppFont.font(.body))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.borderHairline, lineWidth: 1)
            )
            .onAppear {
                text = formatted(value)
            }
            .onChange(of: text) { _, new in
                if let parsed = Double(new.replacingOccurrences(of: ",", with: ".")),
                   parsed > 0 {
                    value = parsed
                }
            }
            .onChange(of: value) { _, new in
                let formattedNew = formatted(new)
                if formattedNew != text {
                    text = formattedNew
                }
            }
    }

    private func formatted(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%g", v)
    }
}
