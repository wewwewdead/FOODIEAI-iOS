import SwiftUI
import PhotosUI
import UIKit

/// Home tab root — Phase 14 redesign.
///
/// Layout matches mockup-1-capture.svg:
///   - bgCanvas warm off-white background
///   - "foodie." wordmark left, avatar circle right
///   - "What did / you eat?" hero copy in display1, "?" in brand
///   - Subtitle in body ink-mute
///   - White photo card (no dashed border) — empty state shows a
///     brand-tinted icon stack + "Tap to add a photo" / "Library or
///     camera"; filled state shows the picked photo
///   - Subtle "• Best with bright light" chip below the card
///   - PrimaryButton "Take a photo" pinned near the bottom
///
/// The picker/analyze/save plumbing from Phase 5+ is preserved unchanged:
/// confirmationDialog → camera or PhotosPicker → setPhoto → analyze.
/// `DashedDropZone` is no longer rendered (kept in the project per
/// Phase 14 soft constraint with a deprecation comment in its file).
///
/// When the analyze flow finishes (.ready / .noFood / .failed), the
/// result rendering replaces the empty-state hero copy in place. The
/// SavedConfirmationSheet still presents from .saved.
struct CaptureView: View {
    @StateObject private var viewModel = CaptureViewModel()
    /// Phase 18 — observed so we can drop the mood pulse rather than
    /// ambush the user when they re-foreground the app.
    @Environment(\.scenePhase) private var scenePhase

    @State private var pickerSheet: PickerSheet? = nil
    @State private var showingSourceDialog = false
    @State private var photosSelection: PhotosPickerItem? = nil
    @State private var isShowingLibrary = false
    /// Phase 15 — Quick Re-log picker presentation flag.
    @State private var showingRecentMeals = false
    /// Phase 16 — one-time coach picker after the user's first save.
    /// Driven by `CoachPickerOnboardingSheet.didSee`; flipped on close
    /// so subsequent saves never re-present.
    @State private var showingCoachPicker = false
    /// Phase 17 — pre-prompt permission sheet, gated by
    /// `NotificationGate.shouldPresentPermissionSheet()`. Presented
    /// after the third save's success-sheet dismiss, with a small
    /// guard so it doesn't fight the coach picker for the same slot.
    @State private var showingNotificationPermission = false

    /// True once the `/analyze` request has returned with a usable
    /// response and the result view is on screen. Used to auto-scroll
    /// the typewriter cascade into view as the analysis lands.
    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    enum PickerSheet: Identifiable {
        case camera
        var id: String { "camera" }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                            .padding(.top, AppSpacing.md)

                        // Idle state: hero copy + photo card.
                        // Non-idle state: result rendering takes over below.
                        switch viewModel.state {
                        case .idle, .picked, .analyzing, .moodPulse:
                            // .moodPulse is rendered as the empty/idle
                            // hero with the mood sheet on top — the
                            // result rendering would be a misleading
                            // background while the user reflects.
                            emptyOrPickedFlow
                        case .ready, .saving, .saved, .saveFailed,
                             .noFood, .failed:
                            resultFlow
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, 120) // breathing room above the pinned CTA
                }
                .onChange(of: isReady) { _, ready in
                    guard ready else { return }
                    // Phase 14 delight: smoothly scroll the typewriter
                    // cascade into focus once analyze returns. Delay the
                    // scroll briefly so the user sees the hero number
                    // count-up + stamp land at the top before the screen
                    // travels down — feels like the result is settling
                    // before the page draws our eye to the substance.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 700)
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                            proxy.scrollTo(
                                AnalysisResultView.cascadeAnchorID,
                                anchor: .top
                            )
                        }
                    }
                }
            }

            bottomCTA
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
            Button("Choose from Library") { presentLibraryPicker() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $pickerSheet) { sheet in
            switch sheet {
            case .camera:
                CameraPicker(
                    onPicked: { image in
                        pickerSheet = nil
                        viewModel.setPhoto(image, source: .camera)
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
                    viewModel.setPhoto(image, source: .library)
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
        // Phase 18 — mood pulse, presented after `.saved` auto-
        // transitions (1.2s) or the user closes the success sheet.
        // Pulse-skip and pulse-pick both route through the view model
        // so the state machine remains the single source of truth.
        .sheet(isPresented: Binding(
            get: { viewModel.state.isMoodPulse },
            set: { isPresented in
                if !isPresented { viewModel.skipMoodPulse() }
            }
        )) {
            MoodPulseSheet(
                onPick: { mood in
                    Task { await viewModel.recordMood(mood) }
                },
                onSkip: { viewModel.skipMoodPulse() }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        // Phase 15 — Quick Re-log picker sheet.
        .sheet(isPresented: $showingRecentMeals) {
            RecentMealsSheet { picked in
                Task { await viewModel.relog(picked) }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Phase 16 — one-time coach picker after the first save. Fires
        // on the .saved transition; the gate is the local UserDefaults
        // flag inside `CoachPickerOnboardingSheet`. We don't fire on
        // re-logs (which also flip into `.saved` cousins) because
        // `state.isSaved` is true only for the analyze→save path —
        // a re-log goes through `relogToast`, not the `.saved` state.
        .onChange(of: viewModel.state.isSaved) { _, isSaved in
            guard isSaved, !CoachPickerOnboardingSheet.didSee else { return }
            // Defer so the SavedConfirmationSheet's appear animation
            // doesn't race with our sheet present. SwiftUI can only
            // present one sheet at a time; we let the success sheet
            // dismiss first via discardSaved, then ride that exit.
            // Implementation: trigger after the user closes the
            // success sheet (state goes saved → idle).
        }
        .onChange(of: viewModel.state.isIdle) { wasIdle, isIdle in
            // Edge: success sheet dismissed (.saved → .idle).
            // Guard against the no-op idle→idle case.
            guard !wasIdle, isIdle else { return }
            // Coach picker (Phase 16) wins the slot if it hasn't been
            // shown — newer users hit it first; the notification
            // permission sheet (Phase 17) is gated on save count and
            // earns its turn from the third save onward.
            if !CoachPickerOnboardingSheet.didSee {
                showingCoachPicker = true
                return
            }
            // Phase 17: pre-prompt notification permission sheet, gated
            // by save-count + 30-day defer + system status not-determined.
            Task {
                if await NotificationGate.shouldPresentPermissionSheet() {
                    await MainActor.run { showingNotificationPermission = true }
                }
            }
        }
        .sheet(isPresented: $showingCoachPicker) {
            CoachPickerOnboardingSheet(onClosed: {})
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Phase 18 — scene-phase guard: if the app backgrounds while
        // the success sheet or mood pulse is up, drop the pulse rather
        // than ambush the user on next foreground. Confirmation sheet
        // closing here also avoids two stacked sheets re-presenting
        // when SwiftUI restores the prior state.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.cancelMoodPulseIfPresent()
            }
        }
        // Phase 17 — notification permission pre-prompt sheet.
        .sheet(isPresented: $showingNotificationPermission) {
            NotificationPermissionView(
                onGranted: {
                    // Kick a reschedule so the meal reminders land
                    // immediately after grant.
                    Task {
                        await AppForegroundOrchestrator.shared
                            .runOnForeground(caller: "notificationPermission.onGranted")
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Phase 15 — re-log success / failure toast. Sits above the
        // bottom CTA so it's visible without overlapping the primary
        // affordance. Auto-fades after 1.6s.
        .overlay(alignment: .bottom) {
            if let toast = viewModel.relogToast {
                RelogToastView(toast: toast)
                    .padding(.bottom, 96) // clear of the pinned PrimaryButton
                    .padding(.horizontal, AppSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.appReveal) {
                            viewModel.clearRelogToast()
                        }
                    }
            }
        }
        .animation(.motionBase, value: viewModel.relogToast?.id)
    }

    // MARK: - Top bar (wordmark + avatar)

    private var topBar: some View {
        HStack(alignment: .center) {
            Text("foodie.")
                .appFont(.title1)
                .foregroundStyle(Color.ink)

            Spacer()

            ZStack {
                Circle()
                    .fill(Color.bgSurface)
                    .overlay(
                        Circle().strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
                    .frame(width: 36, height: 36)
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 32, height: 32)
                Text("L")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty / picked flow

    @ViewBuilder
    private var emptyOrPickedFlow: some View {
        // Hero copy
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text("What did")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("you eat")
                        .appFont(.display1)
                        .foregroundStyle(Color.ink)
                    Text("?")
                        .appFont(.display1)
                        .foregroundStyle(Color.brand)
                }
            }
            Text("Snap a meal — we'll break it down.")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
        }
        .padding(.top, AppSpacing.xl2) // 48pt breathing room

        // Photo card (always 354 wide-ish via maxWidth; aspect-ratio 1)
        photoCard
            .padding(.top, AppSpacing.xl2)

        // Subtle hint chip
        if viewModel.state.isIdle {
            hintChip
                .padding(.top, AppSpacing.lg)
                .frame(maxWidth: .infinity)
                .transition(.opacity)

            // Phase 15 — secondary affordance under the photo card so the
            // re-log path is visible without competing with the primary
            // CTA. Only shown in idle state; once a photo is picked the
            // user is committed to the analyze flow.
            quickRelogLink
                .padding(.top, AppSpacing.md)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }

        // Analyze status / errors hover here while a request is in flight
        analyzeStatus
            .padding(.top, AppSpacing.lg)
    }

    private var photoCard: some View {
        Button {
            Haptics.tap()
            showingSourceDialog = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xl2)
                    .fill(Color.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xl2)
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
                    .appShadow(.shadowCard)

                if let image = viewModel.state.image {
                    DelightfulImageEntry(image: image)
                        .id(ObjectIdentifier(image))
                    if viewModel.state.isAnalyzing {
                        AnalyzingImageAura()
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                } else {
                    photoCardEmptyContent
                        .transition(
                            .scale(scale: 1.06).combined(with: .opacity)
                        )
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            viewModel.state.isAnalyzing ? "Analyzing meal photo"
            : viewModel.state.image == nil ? "Tap to add a photo"
                                           : "Change meal photo"
        )
        // Bouncy spring for the empty ↔ image swap so the photo lands
        // with a Duolingo-style overshoot. The image's own entrance
        // choreography (DelightfulImageEntry) layers on top of this,
        // so the user sees: empty halo pops out → image scales in past
        // 1.0, settles, then a tiny secondary stamp confirms the moment.
        .animation(.appBouncy, value: viewModel.state.image == nil)
        .animation(.motionBase, value: viewModel.state.isAnalyzing)
        .disabled(viewModel.state.isAnalyzing)
        // Floating "change photo" affordance so the user can swap the
        // captured/picked photo without having to know the whole card
        // is tappable. Visible only in `.picked` — once analyze fires
        // or a result is on screen, those states own their own
        // discard/retry flow and a redundant button here would just
        // race them.
        .overlay(alignment: .topTrailing) {
            if showsChangePhotoButton {
                ChangePhotoButton {
                    Haptics.tap()
                    showingSourceDialog = true
                }
                .padding(AppSpacing.sm)
                .transition(
                    .scale(scale: 0.6).combined(with: .opacity)
                )
            }
        }
        .animation(.appBouncy, value: showsChangePhotoButton)
    }

    /// Show the floating "change photo" button only after the user has
    /// a working image AND we're still in the pre-analyze window.
    private var showsChangePhotoButton: Bool {
        if case .picked = viewModel.state { return true }
        return false
    }

    private var photoCardEmptyContent: some View {
        VStack(spacing: AppSpacing.md) {
            // Phase 14 delight: gentle breathing animation on the camera
            // halo so the empty state feels alive, not static.
            BreathingCameraHalo()

            VStack(spacing: 4) {
                Text("Tap to add a photo")
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                Text("Library or camera")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
            }
        }
    }

    /// Phase 15. Subtle text link "Or pick from your recent meals →".
    /// Hidden when there's no list to show — but we don't pre-fetch
    /// here; the sheet itself handles loading + the empty state, and
    /// always-rendering this affordance keeps the layout stable across
    /// users with and without prior saves.
    private var quickRelogLink: some View {
        Button {
            Haptics.tap()
            showingRecentMeals = true
        } label: {
            HStack(spacing: 6) {
                Text("Or pick from your recent meals")
                    .appFont(.captionStrong)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pick from recent meals to re-log")
    }

    private var hintChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.brand)
                .frame(width: 6, height: 6)
            Text("Best with bright light")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.bgSurface)
        )
        .overlay(
            Capsule().strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var analyzeStatus: some View {
        switch viewModel.state {
        case .analyzing:
            HStack(spacing: AppSpacing.sm) {
                ProgressView().tint(Color.brand)
                Text("Analyzing…")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    // MARK: - Result flow (analyze succeeded / no food / failed)

    /// Pull (image, response) out of any save-flow state so the result
    /// view can be rendered from a single branch. Keeping all four states
    /// (.ready / .saving / .saved / .saveFailed) on the *same* SwiftUI
    /// branch preserves `AnalysisResultView`'s identity across the save
    /// transition — without this, `_ConditionalContent` would tear down
    /// and rebuild the result subtree on every state hop, restarting the
    /// typewriter cascade in the background while the confirmation sheet
    /// is presenting.
    private var saveFlowPayload: (image: UIImage, response: AnalyzeResponse)? {
        switch viewModel.state {
        case .ready(let i, let r),
             .saving(let i, let r),
             .saved(let i, let r, _),
             .saveFailed(let i, let r, _):
            return (i, r)
        default:
            return nil
        }
    }

    private var saveFailedError: Error? {
        if case .saveFailed(_, _, let err) = viewModel.state { return err }
        return nil
    }

    @ViewBuilder
    private var resultFlow: some View {
        if let payload = saveFlowPayload {
            VStack(spacing: AppSpacing.md) {
                AnalysisResultView(
                    image: payload.image,
                    response: payload.response,
                    isSaving: viewModel.state.isSaving,
                    onSave:   { handleSaveTapped() },
                    onCancel: { handleCancelTapped() }
                )
                if let err = saveFailedError {
                    Text(err.localizedDescription)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.lg)
                }
            }
            .padding(.top, AppSpacing.lg)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            switch viewModel.state {
            case .noFood:
                NoFoodView(onTryAnother: {
                    viewModel.resetToPick()
                    showingSourceDialog = true
                })
                .padding(.top, AppSpacing.xl2)
                .transition(.opacity)

            case .failed(_, let error):
                FailedView(
                    error: error,
                    onRetry: { Task { await viewModel.analyze() } },
                    onTryAnother: {
                        viewModel.resetToPick()
                        showingSourceDialog = true
                    }
                )
                .padding(.top, AppSpacing.xl2)
                .transition(.opacity)

            default:
                EmptyView()
            }
        }
    }

    /// Routes the Save button based on current state. Identity-preserving
    /// closure so the result view doesn't change shape between states.
    private func handleSaveTapped() {
        switch viewModel.state {
        case .ready:       Task { await viewModel.save() }
        case .saveFailed:  Task { await viewModel.retrySave() }
        default:           break
        }
    }

    private func handleCancelTapped() {
        switch viewModel.state {
        case .ready, .saveFailed: viewModel.discardCurrent()
        default: break
        }
    }

    // MARK: - Bottom CTA

    @ViewBuilder
    private var bottomCTA: some View {
        switch viewModel.state {
        case .idle:
            PrimaryButton(title: "Take a photo",
                          leadingSystemImage: "camera.fill") {
                Haptics.tap()
                showingSourceDialog = true
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
        case .picked:
            PrimaryButton(title: "Analyze",
                          leadingSystemImage: "sparkles") {
                Task { await viewModel.analyze() }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
        case .analyzing:
            PrimaryButton(title: "Analyzing…", isLoading: true) {}
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.md)
        case .ready, .saving, .saved, .saveFailed, .noFood, .failed:
            // Result flow renders its own pinned PrimaryButton inside
            // AnalysisResultView (Tier 3.2). No bottom CTA at the screen
            // level; would be redundant.
            EmptyView()
        case .moodPulse:
            // Background looks idle; the mood sheet is presented over
            // it. Keeping the bottom CTA empty avoids drawing the
            // primary "Take a photo" button while the user is mid-
            // reflection.
            EmptyView()
        }
    }

    // MARK: - Library picker plumbing

    private func presentLibraryPicker() {
        // Reset prior selection so onChange fires even if user picks the
        // same image twice in a row.
        photosSelection = nil
        isShowingLibrary = true
    }
}

// MARK: - Breathing camera halo

/// Phase 14 delight: the empty-state camera icon with a gentle breathing
/// scale loop on the brand-soft halo and a subtle counter-bob on the
/// camera glyph itself. The motion is slow (2.4s period) and small in
/// amplitude (±4%) so it feels alive without being distracting.
///
/// Animation kicks off on first appear via `.appBreathing` (an autoreversing
/// `.easeInOut` repeating forever, defined in `AppAnimation.swift`).
private struct BreathingCameraHalo: View {
    @State private var breathing: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.brandSoft,
                             Color(red: 232/255, green: 239/255, blue: 194/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 88, height: 88)
                .scaleEffect(breathing ? 1.04 : 1.0)

            Image(systemName: "camera.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.brand)
                // Counter-direction bob so the camera glyph "floats"
                // rather than scaling with the halo.
                .scaleEffect(breathing ? 0.98 : 1.0)
        }
        .onAppear {
            withAnimation(.appBreathing) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Change-photo floating button

/// Small floating "swap photo" button overlaid on the captured image
/// so the user can re-pick from camera or library without the whole
/// "tap-the-card" affordance being invisible. Visual:
///   - 32pt circle, ultra-thin material fill — stays legible over any
///     food photo, light or dark
///   - white hairline stroke for edge contrast
///   - SF Symbol `arrow.triangle.2.circlepath` (the conventional swap
///     glyph) in ink color
///   - soft drop shadow, press-scale to 0.88× tied to `.appPress`
private struct ChangePhotoButton: View {
    let action: () -> Void
    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.ink.opacity(0.22), radius: 6, x: 0, y: 2)
            .scaleEffect(pressed ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.appPress) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.appPress) { pressed = false }
                }
        )
        .accessibilityLabel("Change photo")
        .accessibilityHint("Pick a different photo from camera or library")
    }
}

// MARK: - Delightful image entrance

/// Duolingo-style "land" choreography for a freshly captured or picked
/// image. Three coordinated beats:
///
///   1. **Drop in** (`.appBouncy`, 0–~0.55s): the image enters at
///      0.55× scale with a slight −6° tilt and zero opacity. The
///      `appBouncy` spring (response 0.55, damping 0.55) overshoots
///      its target before settling, so the photo "bounces" into place
///      instead of fading in flat.
///   2. **Land haptic** (~0.32s): a soft impact fires just before the
///      bounce settles. Paired with the visual overshoot it reads as
///      the photo physically thudding onto the card.
///   3. **Stamp pulse** (~0.40s, then `.appPress`): a quick 1.0 → 1.04
///      → 1.0 scale pop confirms the moment and gives the card a
///      heartbeat — the same cue the analyze-result hero number uses.
///
/// The view is keyed by `ObjectIdentifier(image)` at the call site so
/// SwiftUI tears it down and rebuilds it whenever the user picks a new
/// photo, which re-runs the whole choreography from the top.
private struct DelightfulImageEntry: View {
    let image: UIImage
    @State private var landed: Bool = false
    @State private var stamping: Bool = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
            .scaleEffect(scale)
            .rotationEffect(.degrees(landed ? 0 : -6))
            .opacity(landed ? 1 : 0)
            .onAppear { runEntrance() }
    }

    private var scale: CGFloat {
        if !landed { return 0.55 }
        return stamping ? 1.04 : 1.0
    }

    private func runEntrance() {
        // Beat 1 — bounce in.
        withAnimation(.appBouncy) {
            landed = true
        }
        Task {
            // Beat 2 — soft land haptic just before the bounce settles.
            try? await Task.sleep(nanoseconds: 320_000_000)
            await MainActor.run { Haptics.soft() }

            // Beat 3 — stamp pulse, then release back to identity.
            try? await Task.sleep(nanoseconds:  80_000_000)
            await MainActor.run {
                withAnimation(.appStamp) { stamping = true }
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                withAnimation(.appPress) { stamping = false }
            }
        }
    }
}

// MARK: - Analyzing image aura

/// Siri-inspired analyzing state for the selected image. The effect uses
/// the same ingredients common to Siri-like recreations: layered color,
/// blur, blend modes, and continuously shifting sine-wave ribbons. It is
/// decorative only; the actual analyze state remains driven by
/// `CaptureViewModel.State.analyzing`.
private struct AnalyzingImageAura: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Color.black.opacity(0.16)

                SiriFluidGlow(time: seconds)
                    .blur(radius: 26)
                    .opacity(0.82)
                    .blendMode(.screen)

                SiriWaveRibbons(time: seconds)
                    .blendMode(.screen)

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.ink.opacity(0.34)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )

                analyzingBadge
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .bottomTrailing)
            }
        }
        .accessibilityHidden(true)
    }

    private var analyzingBadge: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                AnalyzingDot(delay: Double(index) * 0.16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct AnalyzingDot: View {
    let delay: Double
    @State private var isLifted = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 6, height: 6)
            .scaleEffect(isLifted ? 1.35 : 0.75)
            .opacity(isLifted ? 1 : 0.48)
            .animation(
                .easeInOut(duration: 0.62)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: isLifted
            )
            .onAppear { isLifted = true }
    }
}

private struct SiriFluidGlow: View {
    let time: TimeInterval

    private let colors: [Color] = [
        Color(red: 0.15, green: 0.86, blue: 1.00),
        Color(red: 0.90, green: 0.21, blue: 1.00),
        Color(red: 1.00, green: 0.63, blue: 0.18),
        Color.brandBright
    ]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                ForEach(colors.indices, id: \.self) { index in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    colors[index].opacity(0.82),
                                    colors[index].opacity(0.0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: side * 0.42
                            )
                        )
                        .frame(width: side * blobScale(index),
                               height: side * blobScale(index))
                        .position(position(for: index, in: proxy.size))
                }
            }
        }
    }

    private func blobScale(_ index: Int) -> CGFloat {
        [0.72, 0.62, 0.54, 0.48][index]
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let phase = time * (0.48 + Double(index) * 0.08) + Double(index) * 1.7
        let x = size.width * (0.5 + 0.27 * cos(phase))
        let y = size.height * (0.5 + 0.24 * sin(phase * 1.17))
        return CGPoint(x: x, y: y)
    }
}

private struct SiriWaveRibbons: View {
    let time: TimeInterval

    private let ribbonColors: [[Color]] = [
        [
            Color(red: 0.22, green: 0.92, blue: 1.00),
            Color(red: 0.73, green: 0.35, blue: 1.00),
            Color(red: 1.00, green: 0.53, blue: 0.28)
        ],
        [
            Color.brandBright,
            Color(red: 0.98, green: 0.30, blue: 0.92),
            Color(red: 0.18, green: 0.78, blue: 1.00)
        ],
        [
            Color.white.opacity(0.95),
            Color(red: 0.45, green: 0.86, blue: 1.00),
            Color(red: 1.00, green: 0.79, blue: 0.22)
        ]
    ]

    var body: some View {
        Canvas { context, size in
            var softenedContext = context
            softenedContext.addFilter(.blur(radius: 9))
            drawWaves(in: &softenedContext, size: size, softened: true)

            drawWaves(in: &context, size: size, softened: false)
        }
        .drawingGroup()
    }

    private func drawWaves(in context: inout GraphicsContext,
                           size: CGSize,
                           softened: Bool) {
        let baseY = size.height * 0.52
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        for index in ribbonColors.indices {
            var path = Path()
            let phase = time * (1.22 + Double(index) * 0.18)
                + Double(index) * 1.35
            let amplitude = height * (softened ? 0.055 : 0.042)
                * (1 + 0.22 * sin(time * 1.4 + Double(index)))
            let frequency = 1.55 + Double(index) * 0.38
            let verticalOffset = CGFloat(index - 1) * height * 0.065

            for step in 0...120 {
                let progress = CGFloat(step) / 120
                let x = progress * width
                let envelope = sin(Double(progress) * .pi)
                let primary = sin(Double(progress) * .pi * 2 * frequency + phase)
                let secondary = sin(Double(progress) * .pi * 4.2 + phase * 0.72)
                let y = baseY + verticalOffset
                    + CGFloat((primary + secondary * 0.34) * envelope) * amplitude

                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let gradient = Gradient(colors: ribbonColors[index])
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: baseY - height * 0.14),
                endPoint: CGPoint(x: width, y: baseY + height * 0.14)
            )

            context.stroke(
                path,
                with: shading,
                style: StrokeStyle(
                    lineWidth: softened ? height * 0.075 : height * 0.018,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}

// MARK: - No-food and Failed states

/// Shown when the server returns `analysis.fallback` (no food detected).
private struct NoFoodView: View {
    let onTryAnother: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color.inkLight)
            Text("No food detected")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text("Try a clearer photo of a meal, snack, or drink.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Try another photo",
                          leadingSystemImage: "camera.fill",
                          action: onTryAnother)
                .padding(.top, AppSpacing.md)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

/// Shown when `AnalyzeService.analyze` throws.
private struct FailedView: View {
    let error: AnalyzeError
    let onRetry: () -> Void
    let onTryAnother: () -> Void

    /// HTTP 400 from `/analyze` typically means Gemini couldn't get a
    /// structured response off the photo (server bodies look like
    /// "No structured response received" / "Failed to analyze image").
    /// That's a photo-quality problem, not a backend outage — surface
    /// copy the user can act on instead of the generic message, and
    /// flip the CTA priority so picking a *different* photo is the
    /// primary action (retrying the same broken image is futile).
    private var isUnreadablePhoto: Bool {
        if case .serverError(let status, _) = error, status == 400 {
            return true
        }
        return false
    }

    private var title: String {
        isUnreadablePhoto ? "We couldn't read this photo" : "Something went wrong"
    }

    private var detail: String {
        if isUnreadablePhoto {
            return "We couldn't read this photo clearly. Try a brighter shot or a different angle?"
        }
        return error.errorDescription ?? "Please try again."
    }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color.error.opacity(0.85))
            Text(title)
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)

            // Unreadable-photo path: picking a different photo is the
            // useful action; retrying the same broken upload is the
            // fallback. Genuine network errors keep "Try again" as
            // primary because the same image will probably succeed
            // once connectivity is back.
            if isUnreadablePhoto {
                PrimaryButton(title: "Try another photo",
                              leadingSystemImage: "camera.fill",
                              action: onTryAnother)
                    .padding(.top, AppSpacing.md)
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .heavy))
                        Text("Try again with this photo")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.inkMute)
                }
                .buttonStyle(.plain)
            } else {
                PrimaryButton(title: "Try again",
                              leadingSystemImage: "arrow.clockwise",
                              action: onRetry)
                    .padding(.top, AppSpacing.md)
                Button(action: onTryAnother) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .heavy))
                        Text("Pick a different photo")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.inkMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Re-log toast

/// Phase 15. Lightweight pill toast for quick-re-log confirmations.
/// Distinct from `SavedConfirmationSheet`'s full-screen success
/// choreography — re-logs are a frequency action, not a moment, so
/// this lives at the bottom of the screen and fades in 1.6s.
private struct RelogToastView: View {
    let toast: CaptureViewModel.RelogToast

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: toast.kind == .success
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(toast.kind == .success
                                 ? Color.success
                                 : Color.error)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.kind == .success ? "Re-logged" : "Couldn't re-log")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Text(toast.foodName)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            toast.kind == .success
            ? "Re-logged \(toast.foodName)"
            : "Couldn't re-log \(toast.foodName)"
        )
    }
}

#if DEBUG
#Preview("CaptureView — idle") {
    CaptureView()
}
#endif
