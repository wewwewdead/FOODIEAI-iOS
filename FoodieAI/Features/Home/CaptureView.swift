import SwiftUI
import PhotosUI
import UIKit

/// Home tab root — replaces the Phase 4 placeholder. Layout per
/// DESIGN_SYSTEM.md §HomePage, mobile-stacked.
///
///   - Welcome heading ("Upload or snap a meal to get insights!")
///     fades out once any non-idle state is reached.
///   - DashedDropZone (320×320) renders empty or filled per current image.
///   - PillButton "Analyze" / "Analyze new food" / "Analyzing..." switches
///     label and action by state. Hidden when idle.
///   - When state is .ready/.noFood/.failed, AnalysisResultView takes over
///     below the drop zone.
struct CaptureView: View {
    @StateObject private var viewModel = CaptureViewModel()

    @State private var pickerSheet: PickerSheet? = nil
    @State private var showingSourceDialog = false
    @State private var photosSelection: PhotosPickerItem? = nil

    enum PickerSheet: Identifiable {
        case camera
        var id: String { "camera" }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.brandCream.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    welcomeHeader
                        .opacity(viewModel.state.isIdle ? 1 : 0)
                        .frame(maxHeight: viewModel.state.isIdle ? .infinity : 0)
                        .animation(.easeOut(duration: 0.25), value: viewModel.state.isIdle)

                    dropZone

                    analyzeButton

                    resultSection
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.xl3)
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog(
            "Add a meal photo",
            isPresented: $showingSourceDialog,
            titleVisibility: .visible
        ) {
            // The simulator has no camera; only show the option on real devices.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { pickerSheet = .camera }
            }
            Button("Choose from Library") {
                // Triggering the PhotosPicker via sheet selection means we
                // don't need a hidden button. We surface the picker via a
                // PhotosPicker view rendered inline (see below) and toggle
                // its presentation by setting selection to nil and tapping.
                presentLibraryPicker()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $pickerSheet) { sheet in
            switch sheet {
            case .camera:
                CameraPicker(
                    onPicked: { image in
                        pickerSheet = nil
                        viewModel.setPhoto(image)
                    },
                    onCancel: { pickerSheet = nil }
                )
                .ignoresSafeArea()
            }
        }
        .photosPicker(
            isPresented: $isShowingLibrary,
            selection: $photosSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photosSelection) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.setPhoto(image)
                }
                photosSelection = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.state.isSaved },
            set: { isPresented in
                if !isPresented { viewModel.discardSaved() }
            }
        )) {
            SavedConfirmationSheet(onClose: { viewModel.discardSaved() })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Subviews

    private var welcomeHeader: some View {
        Text("Upload or snap a meal to get insights!")
            .appFont(.displayMD)
            .fontWeight(.black) // displayMD already heavy; this nudges to 900
            .foregroundStyle(Color.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.top, AppSpacing.lg)
    }

    private var dropZone: some View {
        DashedDropZone(image: viewModel.state.image) {
            // Tap action: present source dialog if no image; otherwise
            // re-present so user can swap photos before analyzing.
            showingSourceDialog = true
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
            PillButton(
                title: "Analyzing...",
                variant: .outline,
                isLoading: true
            ) {}
        case .ready, .noFood, .failed, .saving, .saved, .saveFailed:
            PillButton(title: "Analyze new food", variant: .outline) {
                viewModel.resetToPick()
                showingSourceDialog = true
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch viewModel.state {
        case .ready(_, let response):
            AnalysisResultView(
                response: response,
                isSaving: false,
                onSave:   { Task { await viewModel.save() } },
                onCancel: { viewModel.discardCurrent() }
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .saving(_, let response):
            AnalysisResultView(
                response: response,
                isSaving: true,
                onSave:   { /* in flight */ },
                onCancel: { /* disabled while saving */ }
            )
        case .saved(_, let response, _):
            AnalysisResultView(
                response: response,
                isSaving: false,
                onSave:   { },
                onCancel: { }
            )
        case .saveFailed(_, let response, let error):
            VStack(spacing: AppSpacing.lg) {
                AnalysisResultView(
                    response: response,
                    isSaving: false,
                    onSave:   { Task { await viewModel.retrySave() } },
                    onCancel: { viewModel.discardCurrent() }
                )
                Text(error.localizedDescription)
                    .appFont(.body)
                    .foregroundStyle(Color.redError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.lg)
            }
        case .noFood:
            NoFoodView(onTryAnother: {
                viewModel.resetToPick()
                showingSourceDialog = true
            })
            .transition(.opacity)
        case .failed(_, let error):
            FailedView(
                error: error,
                onRetry: { Task { await viewModel.analyze() } }
            )
            .transition(.opacity)
        case .idle, .picked, .analyzing:
            EmptyView()
        }
    }

    // MARK: - Library picker plumbing

    @State private var isShowingLibrary = false

    private func presentLibraryPicker() {
        // Reset prior selection so onChange fires even if user picks the
        // same image twice in a row.
        photosSelection = nil
        isShowingLibrary = true
    }
}

// MARK: - No-food and Failed states

/// Shown when the server returns `analysis.fallback` (no food detected).
private struct NoFoodView: View {
    let onTryAnother: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("No food detected!")
                .appFont(.displayMD)
                .foregroundStyle(Color.redError)
                .multilineTextAlignment(.center)
            Text("Try a clearer photo of a meal, snack, or drink.")
                .appFont(.body)
                .foregroundStyle(Color.textBody)
                .multilineTextAlignment(.center)
            PillButton(title: "Try another photo", variant: .outline,
                       action: onTryAnother)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

/// Shown when `AnalyzeService.analyze` throws.
private struct FailedView: View {
    let error: AnalyzeError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Something went wrong")
                .appFont(.displayMD)
                .foregroundStyle(Color.redError)
                .multilineTextAlignment(.center)
            Text(error.errorDescription ?? "Please try again.")
                .appFont(.body)
                .foregroundStyle(Color.textBody)
                .multilineTextAlignment(.center)
            PillButton(title: "Try again", variant: .outline, action: onRetry)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("CaptureView — idle") {
    CaptureView()
}
#endif
