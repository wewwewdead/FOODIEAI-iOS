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
    let isActive: Bool

    @StateObject private var viewModel = CaptureViewModel()
    /// Phase 18 — observed so we can drop the mood pulse rather than
    /// ambush the user when they re-foreground the app.
    @Environment(\.scenePhase) private var scenePhase
    /// Used to route the after-save "View today / tracker" suggestion
    /// to the Tracker tab via the same channel notification taps use.
    @EnvironmentObject private var notifRouter: NotificationRouter
    /// Phase 21.12 — read for the Healthy Choice toggle so the daily
    /// quest card can hide when the user has opted out in Profile.
    @EnvironmentObject private var profileStore: ProfileStore
    /// Phase 22 — observed so the scan counter chip in the top bar
    /// updates live as `scansUsedToday` / `dailyLimit` change. The
    /// manager is injected at app scope (FoodieAIApp.body).
    @EnvironmentObject private var subscriptions: SubscriptionManager
    /// Drives both the analyzing aura's "lock-in" collapse transition and
    /// the static-aura fallback under Reduce Motion (the food-tinted blobs
    /// and the inward contract are both skipped when this is true).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Photo morphs into a living bubble while analyzing, then un-forms
    /// into the next step." On by default now that it's the intended look;
    /// still gated by a compile-time constant (`BubbleMorphFeature
    /// .isAvailable`) and this runtime toggle, and always bypassed under
    /// Reduce Motion (→ today's static aura). Set false to fall back to the
    /// original aura + crossfade.
    @AppStorage("bubbleMorphEnabled") private var bubbleMorphEnabled = true
    /// "Photo lifts out of the card as an orb, genie-travels to the notch to
    /// 'think', then travels back." Layered on top of the bubble morph as the
    /// analyzing hero. Runtime toggle; always bypassed under Reduce Motion (the
    /// in-card aura then carries the analyzing state). See `AnalyzingOrbJourney`.
    @AppStorage("orbNotchJourneyEnabled") private var orbNotchJourneyEnabled = true
    /// Analyzing animation: OFF = the Metal genie-warp shader + orb in the
    /// Dynamic Island (the default). ON = the experimental GPU particle-fluid
    /// ("dust") simulation. Kept behind the flag so it can be re-enabled, but
    /// the genie warp is the shipping look. See `Genie.metal` / `FluidParticleView`.
    @AppStorage("sphFluidEnabled") private var sphFluidEnabled = false
    /// Single namespace shared by the capture-side photo and the result-
    /// screen meal photo. Declared on the parent that hosts BOTH the
    /// `emptyOrPickedFlow` and `resultFlow` branches — it must live above
    /// both, never inside either, or the geometry match silently breaks.
    @Namespace private var mealMorph

    @State private var pickerSheet: PickerSheet? = nil
    @State private var showingSourceDialog = false
    @State private var photosSelection: PhotosPickerItem? = nil
    @State private var photoLoadTask: Task<Void, Never>? = nil
    @State private var photoLoadGeneration: UInt64 = 0
    @State private var isShowingLibrary = false
    /// Phase 15 — Quick Re-log picker presentation flag.
    @State private var showingRecentMeals = false
    /// Quick-log-favorite picker presentation flag. Same sheet as
    /// `showingRecentMeals` but with the favorites filter applied so the
    /// user sees only hearted meals.
    @State private var showingFavoriteMeals = false
    /// Observed so the favorite-shortcut affordance hides itself the
    /// moment the user un-hearts every meal — no stale "Quick log
    /// favorite" link sitting on Home with no targets.
    @StateObject private var favoritesStore = FavoritesStore.shared
    /// Phase 16 — one-time coach picker after the user's first save.
    /// Driven by `CoachPickerOnboardingSheet.didSee`; flipped on close
    /// so subsequent saves never re-present.
    @State private var showingCoachPicker = false
    /// Phase 17 — pre-prompt permission sheet, gated by
    /// `NotificationGate.shouldPresentPermissionSheet()`. Presented
    /// after the third save's success-sheet dismiss, with a small
    /// guard so it doesn't fight the coach picker for the same slot.
    @State private var showingNotificationPermission = false
    /// Loop-building first-save celebration + reminders opt-in (once ever).
    @State private var showingFirstLogLoop = false

    /// Phase 20 — calorie-goal scan warning. Surfaces a confirmation
    /// dialog before the photo source picker when today's consumed
    /// calories are already at or near the daily goal. Non-blocking:
    /// the user can always proceed via "Scan anyway."
    @State private var calorieScanWarning: ScanWarningKind? = nil
    /// Set to `true` after the user picks "Scan anyway" for the current
    /// session of pressing the CTA, so we don't re-prompt them on the
    /// follow-up source-dialog tap. Cleared whenever the warning fires
    /// fresh again (next CTA press from idle).
    @State private var bypassCalorieWarningOnce: Bool = false
    /// Loaded lazily on demand: the Home tab doesn't query today's
    /// totals as part of its normal idle render, so we only fetch when
    /// the user actually presses "Take a photo" or the photo card. The
    /// fetch is cheap (~one network round-trip) and we cache the result
    /// for the rest of this CaptureView session so the second tap is
    /// instant.
    @State private var cachedCalorieStatus: DailyCalorieGoalStatus? = nil
    /// Retained handle for the delayed "scroll into the cascade" Task.
    /// Stored so a fresh isReady flip can cancel a still-pending scroll
    /// (e.g. user discarded before the 700ms tail fired), and so we can
    /// cancel on disappear.
    @State private var resultScrollTask: Task<Void, Never>? = nil
    /// First-scan magic: a one-time celebratory ring that radiates around
    /// the photo card the moment a brand-new user picks their first
    /// image. Visible-only flag drives whether the subview is mounted;
    /// the subview owns its own fade-out via a SwiftUI `.task` so we
    /// never retain a delayed `Task` here. The fired flag guards against
    /// a second mount in the same session (the rhythm store flips
    /// `totalLoggedDays` to 1 after save, but the user could pick → discard
    /// repeatedly before saving — we only celebrate once).
    @State private var firstScanGlowVisible: Bool = false
    @State private var firstScanGlowFired: Bool = false
    /// Food-derived palette for the analyzing aura. Computed exactly once
    /// per scan (when `.analyzing` begins, from `state.image`) and passed
    /// down into `AnalyzingImageAura` so the free-tier glow picks up the
    /// dish's own hues instead of a fixed rainbow. Empty means "fall back
    /// to the default palette" — set when extraction yields < 2 usable
    /// colors. Pro keeps its champagne override regardless. Never sampled
    /// per frame: the `TimelineView` inside the aura only reads this array.
    @State private var foodPalette: [Color] = []
    /// Today's meal count, fetched alongside `cachedCalorieStatus` so the
    /// daily check-in card can render its primary copy without a second
    /// `todaysLogs` round-trip. `nil` while loading; the card renders
    /// an unobtrusive idle state in that case.
    @State private var cachedTodayMealCount: Int? = nil
    /// Observed so a save-success `markToday()` re-renders the check-in
    /// line ("First check-in logged.") and the personalized empty state
    /// updates when the user crosses midnight without restarting the app.
    @StateObject private var rhythmStore = LoggingRhythmStore.shared
    /// Small "Food Mirror is learning" preview shown below the daily
    /// check-in card. Hidden when no message resolves. Refreshes on
    /// Home appearance and after `.foodLogDidChange` posts.
    @StateObject private var mirrorPreview = HomeMirrorPreviewViewModel()

    /// Phase 21 — manual log sheet presentation flag.
    @State private var showingManualLog: Bool = false
    /// Phase 22 — Paywall presentation. Driven from two surfaces: the
    /// limit-reached sheet's Upgrade button and any future explicit
    /// upgrade affordance.
    @State private var showingPaywall: Bool = false
    /// Phase 22 — scan-budget explainer sheet. Tapping the top-bar
    /// scan counter chip presents this regardless of remaining count
    /// so users always have a one-tap path to "how does this work".
    @State private var showingScanLimitsInfo: Bool = false
    /// Phase 21.5 — action sheet for the daily quest card. Tap on the
    /// card flips this; user picks between Scan or Manual Log paths,
    /// both of which already exist on this view.
    @State private var showingQuestActionSheet: Bool = false
    /// Phase 21 — post-manual-save toast carrying optional quest reward
    /// copy + a free-tier nudge. Cleared automatically after a few
    /// seconds or when the user taps the action.
    @State private var manualLogToast: ManualLogToast? = nil
    /// Manual-log path's equivalent of `state.moodPulse` — the photo
    /// flow drives mood capture through CaptureViewModel's state
    /// machine, but a manual save has no analyze response to thread,
    /// so we hold the just-inserted log here and present
    /// `MoodPulseSheet` directly.
    @State private var pendingManualMoodLog: FoodLog? = nil
    /// When a manual save also completes today's quest, the quest
    /// celebration modal takes priority — we stash the log here while
    /// the modal is up and promote it to `pendingManualMoodLog` once
    /// the modal dismisses. Keeps the two overlays from racing.
    @State private var manualLogAwaitingMood: FoodLog? = nil
    @State private var homeActivationTask: Task<Void, Never>? = nil

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    /// Lightweight after-save banner state. The struct lives inline
    /// because no other surface reads or writes it.
    struct ManualLogToast: Identifiable, Equatable {
        let id = UUID()
        let foodName: String
        let questRewardCopy: String?
        let scansRemaining: Int
        /// Pro users are marketed as unlimited — the toast's scan nudge
        /// must not show a remaining-count number for them.
        var isUnlimited: Bool = false
    }

    enum ScanWarningKind: Identifiable {
        case approaching
        case reached
        var id: String {
            switch self {
            case .approaching: return "approaching"
            case .reached: return "reached"
            }
        }
    }

    /// True once the `/analyze` request has returned with a usable
    /// response and the result view is on screen. Used to auto-scroll
    /// the typewriter cascade into view as the analysis lands.
    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    /// True for any state that paints the AnalysisResultView (or its
    /// sibling no-food / failed views). Drives the cross-branch morph
    /// animation so the picked photo card "settles" into the result.
    private var isShowingResult: Bool {
        switch viewModel.state {
        case .ready, .saving, .saved, .saveFailed, .noFood, .failed:
            return true
        default:
            return false
        }
    }

    /// Whether the matched-geometry morph should engage: feature compiled
    /// in, runtime flag on, and Reduce Motion off. Any one false → the
    /// crossfade fallback. Read everywhere the morph branches, so the whole
    /// feature collapses to today's behavior from a single switch.
    private var bubbleMorphActive: Bool {
        BubbleMorphFeature.isAvailable && bubbleMorphEnabled && !reduceMotion
    }

    /// Whether the orb-to-notch journey owns the analyzing visual. When on, the
    /// photo lifts out of the card and the in-card analyzing chrome (dim field /
    /// badge / aura) is suppressed so the two don't fight. Off under Reduce
    /// Motion (→ in-card aura) and when the user disables it.
    private var orbJourneyActive: Bool {
        orbNotchJourneyEnabled && BubbleMorphFeature.isAvailable && !reduceMotion
    }

    /// Whether the matched-geometry photo→result handoff should engage.
    /// Gated additionally on `resultHandoffAvailable` (off), so the analyzing
    /// bubble can ship without the fragile cross-branch result morph. When
    /// false the result reveal is exactly today's focus-pull crossfade.
    private var photoResultHandoffActive: Bool {
        bubbleMorphActive && BubbleMorphFeature.resultHandoffAvailable
    }

    /// True only while a morph is active AND analysis is underway — the
    /// window where the matched-geometry effect (not `DelightfulImageEntry`'s
    /// bounce or `FirstScanGlow`'s fixed ring) should own the photo's
    /// position/scale/shape. Always false when the morph is disabled, so the
    /// default entrance choreography is untouched.
    private var suppressPhotoEntranceForMorph: Bool {
        bubbleMorphActive && viewModel.state.isThinking
    }

    enum PickerSheet: Identifiable {
        case camera
        var id: String { "camera" }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.bgCanvas.ignoresSafeArea()

            // Premium-polish wave: ambient liveness behind the hero.
            // Anchored to the top so blobs drift around the headline copy
            // and photo card without bleeding past the CTA bar. Fixed
            // height (520pt) so the composition stays put when the user
            // scrolls — the scroll content moves over the floater, not
            // with it.
            VStack {
                AmbientFloater(intensity: 0.45, isActive: isActive)
                    .frame(height: 520)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Idle state: hero copy + photo card.
                        // Non-idle state: result rendering takes over below.
                        // Both branches carry transitions so the cross-
                        // switch state change reads as the photo "landing"
                        // into the result page rather than a hard swap:
                        //   - empty/picked exits with a small upward scale-
                        //     down + fade (the picked card lifts away)
                        //   - result enters scaled slightly oversize and
                        //     settles into 1.0 with a fade (the analysis
                        //     "lands"). Driven by `.appMorph` for a fluid,
                        //     barely-overshooting feel; Reduce Motion swaps
                        //     to a flat opacity fade.
                        Group {
                            switch viewModel.state {
                            case .idle, .picked, .analyzing, .moodPulse,
                                 .clarifying, .confirmingName:
                                // .moodPulse is rendered as the empty/idle
                                // hero with the mood sheet on top — the
                                // result rendering would be a misleading
                                // background while the user reflects.
                                // .clarifying and .confirmingName do the
                                // same — the photo card stays the focal
                                // background while the name-confirmation /
                                // Quantity Clarification sheet is up.
                                emptyOrPickedFlow
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        // When the result handoff is engaged,
                                        // a scale on the whole capture flow
                                        // would fight the traveling photo, so
                                        // the backdrop just fades. With it off
                                        // (today), keep the upward lift.
                                        removal: photoResultHandoffActive
                                            ? AnyTransition.opacity
                                            : .opacity.combined(
                                                with: .scale(scale: 0.94, anchor: .top)
                                            )
                                    ))
                            case .ready, .saving, .saved, .saveFailed,
                                 .noFood, .failed:
                                resultFlow
                            }
                        }
                        .animation(
                            UIAccessibility.isReduceMotionEnabled
                                ? .appReduced
                                : .appMorph,
                            value: isShowingResult
                        )
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, 120) // breathing room above the pinned CTA
                }
                // Pin the wordmark + scan chip + avatar as a fixed top
                // strip so the hero copy can't scroll up into them.
                // The opaque bgCanvas backdrop hides any rubber-band
                // bleed from scroll content beneath.
                .safeAreaInset(edge: .top, spacing: 0) {
                    topBar
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.sm)
                        .background(Color.bgCanvas)
                }
                // Dragging the scroll content interactively pulls the
                // keyboard down with the finger. AnalysisResultView's
                // food-name field watches `foodNameFieldFocused`; when
                // this gesture drops focus mid-edit, the watcher
                // commits the typed value so the user doesn't lose it.
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isReady) { _, ready in
                    // Always cancel a pending scroll first — whether
                    // `ready` is flipping on or off, a stale tail would
                    // fire against a state that no longer wants it.
                    resultScrollTask?.cancel()
                    resultScrollTask = nil
                    guard ready else { return }
                    // Phase 14 delight: smoothly scroll the typewriter
                    // cascade into focus once analyze returns. Delay the
                    // scroll briefly so the user sees the hero number
                    // count-up + stamp land at the top before the screen
                    // travels down — feels like the result is settling
                    // before the page draws our eye to the substance.
                    resultScrollTask = Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 700)
                        } catch {
                            return
                        }
                        // Re-verify we're still in the .ready state — the
                        // user may have cancelled or discarded during the
                        // 700ms tail. Avoids scrolling into a now-empty
                        // result section.
                        guard !Task.isCancelled, isReady else { return }
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                            proxy.scrollTo(
                                AnalysisResultView.cascadeAnchorID,
                                anchor: .top
                            )
                        }
                    }
                }
                .onDisappear {
                    resultScrollTask?.cancel()
                    resultScrollTask = nil
                    photoLoadTask?.cancel()
                    photoLoadTask = nil
                    photosSelection = nil
                    mirrorPreview.cancelPendingRefresh()
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
        // Phase 20 — calorie-goal scan warning. Surfaces before the
        // source picker when today's totals are at/near the daily
        // calorie goal. "Scan anyway" arms `bypassCalorieWarningOnce`
        // so the immediate follow-up picker open isn't re-gated.
        .modifier(CalorieScanWarningModifier(
            kind: $calorieScanWarning,
            onScanAnyway: {
                bypassCalorieWarningOnce = true
                showingSourceDialog = true
            }
        ))
        // Phase 20 — pre-fetch today's calorie status once on appear
        // so `requestScan()` can evaluate synchronously on the first
        // CTA press. The fetch is best-effort: a transient failure
        // resolves to `.invalid` (no warning), which is the safe
        // default for an action that should never be blocked.
        .task(id: viewModel.state.isIdle) {
            // `.task(id:)` fires on every transition of `isIdle` —
            // both true→false and false→true. We only want the fetch
            // to run while we're actually idle (waiting for the user's
            // next press); the leaving-idle pass would otherwise burn a
            // round-trip the analyze/save flow doesn't need.
            guard viewModel.state.isIdle else { return }
            // Re-fetch when the flow returns to idle (after a save),
            // so the next scan attempt evaluates the freshly-updated
            // totals — the just-inserted meal counts now. Also drives
            // the daily check-in card's meal-count copy with the same
            // round-trip (no second fetch).
            let snapshot = await CalorieReminderService.shared.currentSnapshot()
            cachedCalorieStatus = snapshot.status
            // `snapshot.mealCount` is `nil` when the today's-logs fetch
            // failed. Don't clobber a previously-known count with
            // "unknown" — a transient network blip would otherwise
            // collapse the card to the 0-meal empty-state copy. If
            // there is no prior count, the card hides itself via the
            // `if let count = cachedTodayMealCount` guard at the call
            // site, which is the correct behavior under "unknown."
            if let count = snapshot.mealCount {
                cachedTodayMealCount = count
            }
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
            photoLoadTask?.cancel()
            photoLoadGeneration &+= 1
            let generation = photoLoadGeneration
            photoLoadTask = Task {
                #if DEBUG
                let photoLoadStart = Date()
                #endif

                // Load the picker's bytes, then hand them off to a
                // background task that downsamples via ImageIO without
                // ever decoding the full-resolution buffer into memory.
                // A 12 MP HEIC that would otherwise inflate to ~50 MB
                // decoded lands as a ~2048pt-edge UIImage instead, which
                // the existing compressMain/compressThumbnail passes
                // still resize to their target sizes for upload.
                var preparedImage: UIImage?
                do {
                    if let data = try await newItem.loadTransferable(type: Data.self),
                       !Task.isCancelled {
                        preparedImage = await Task.detached(priority: .userInitiated) {
                            ImagePreparation.downsampledImage(from: data)
                                ?? UIImage(data: data)
                        }.value
                    }
                    // `data` (potentially tens of MB for a 12 MP HEIC)
                    // is released here as the enclosing `if let` falls
                    // out of scope — only the downsampled `UIImage`
                    // survives into setPhoto.
                } catch {
                    preparedImage = nil
                }

                if !Task.isCancelled, let image = preparedImage {
                    #if DEBUG
                    NSLog("[Perf] photo library load + downsample %.2fms",
                          Date().timeIntervalSince(photoLoadStart) * 1000)
                    #endif
                    await MainActor.run {
                        guard !Task.isCancelled,
                              photoLoadGeneration == generation else { return }
                        viewModel.setPhoto(image, source: .library)
                    }
                }

                // Clear the selection so the same image can be repicked
                // and so PhotosUI releases its internal reference to the
                // PHAsset.
                await MainActor.run {
                    guard photoLoadGeneration == generation else { return }
                    photosSelection = nil
                    photoLoadTask = nil
                }
            }
        }
        // Phase 21.13 — the success sheet is gated on
        // `justCompletedQuest == nil` so the quest celebration always
        // lands BEFORE this sheet. The view model already transitions
        // to `.saved` only after the evaluator decides; when the
        // quest fires it also sets `justCompletedQuest` *before*
        // flipping state, so this binding stays false until the
        // celebration modal dismisses and clears the trigger.
        .sheet(isPresented: Binding(
            get: { viewModel.state.isSaved && viewModel.justCompletedQuest == nil },
            set: { isPresented in
                if !isPresented { viewModel.discardSaved() }
            }
        )) {
            SavedConfirmationSheet(
                onClose: { viewModel.discardSaved() },
                nextStep: computedNextStepHint(),
                onNextStepAction: handleNextStepAction,
                isPro: subscriptions.tier == .pro
            )
            .presentationDetents([.fraction(0.7), .large])
            .premiumSheet(tint: .brand)
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
        // Mandatory name confirmation — presented on `.confirmingName`
        // (every successful scan lands here first). Extracted to a
        // ViewModifier for the same type-check-budget reason as the
        // clarification sheet below.
        .modifier(NameConfirmSheetModifier(viewModel: viewModel))
        // Quantity Clarification — sheet presentation extracted to a
        // ViewModifier so the type-checker doesn't have to thread the
        // whole CaptureView modifier chain through the new sheet's
        // generic context. Adding it inline pushed
        // `body` past Swift's expression type-check budget.
        .modifier(ClarificationSheetModifier(viewModel: viewModel))
        // Analyzing hero: the meal photo lifts out of its card as an orb,
        // genie-travels to the notch to "think," then back. Self-gated; a
        // no-op when disabled / Reduce Motion (see `orbJourneyActive`).
        .analyzingOrbJourney(
            image: viewModel.state.image,
            isAnalyzing: viewModel.state.isThinking,
            palette: foodPalette,
            isPro: subscriptions.tier == .pro,
            isActive: isActive,
            enabled: orbJourneyActive,
            useFluid: sphFluidEnabled
        )
        // Phase 15 — Quick Re-log picker sheet.
        .sheet(isPresented: $showingRecentMeals) {
            RecentMealsSheet { picked in
                Task { await viewModel.relog(picked) }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Quick log favorite — same sheet, favorites filter applied.
        .sheet(isPresented: $showingFavoriteMeals) {
            RecentMealsSheet(
                onPicked: { picked in
                    Task { await viewModel.relog(picked) }
                },
                favoritesOnly: true
            )
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
        .onChange(of: viewModel.state.image != nil) { _, hasImage in
            // First-scan magic — kicks in only when a lifetime-empty
            // user picks their first image. `rhythm.totalLoggedDays`
            // flips to 1 after the first save, so subsequent sessions
            // never re-trigger. The `fired` guard handles the within-
            // session pick → discard → pick loop.
            guard hasImage,
                  !firstScanGlowFired,
                  rhythmStore.rhythm().totalLoggedDays == 0
            else { return }
            firstScanGlowFired = true
            firstScanGlowVisible = true
        }
        .onChange(of: viewModel.state.isThinking) { _, analyzing in
            // Tint the analyzing aura from the dish itself. Sample exactly
            // once, the moment analysis begins, from the same image the
            // aura overlays — never per frame. Clear on exit so a later
            // scan of a different photo can't inherit a stale palette.
            guard analyzing else {
                foodPalette = []
                return
            }
            guard let image = viewModel.state.image else { return }
            let palette = DominantColors.extract(from: image)
            // Fallback rule lives here so the aura subviews stay simple:
            // < 2 usable colors → empty → they use their default palette.
            foodPalette = palette.count >= 2 ? palette : []
        }
        .onChange(of: viewModel.state.isIdle) { wasIdle, isIdle in
            // Edge: success sheet dismissed (.saved → .idle).
            // Guard against the no-op idle→idle case.
            guard !wasIdle, isIdle else { return }
            // Phase 20 — a fresh return to idle ends the current "scan
            // attempt." Re-arm the calorie-goal warning so the next
            // press evaluates honestly rather than riding the prior
            // "Scan anyway" decision.
            bypassCalorieWarningOnce = false
            // Loop-building first-save hook: the very first saved meal is the
            // aha. Celebrate it as "day 1 of your streak" and ask to turn on
            // meal-time reminders (the external trigger) right after value
            // lands — fires once, ahead of the coach/notification moments. The
            // logged-day guard ensures a real save (not a cancel back to idle).
            if !FirstLogLoopHook.didShow, rhythmStore.rhythm().totalLoggedDays >= 1 {
                FirstLogLoopHook.markShown()
                showingFirstLogLoop = true
                return
            }
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
        // Loop-building first-save celebration + reminders opt-in.
        .sheet(isPresented: $showingFirstLogLoop) {
            FirstLogLoopSheet()
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
        .modifier(RelogToastModifier(viewModel: viewModel))
        // Phase 21 — manual log sheet + post-save toast.
        .sheet(isPresented: $showingManualLog) {
            ManualLogSheet(
                onSaved: { inserted in
                    handleManualLogSaved(inserted)
                },
                onCancelled: {}
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Phase 21.x — mood pulse after a manual log save. Mirrors the
        // photo-flow `MoodPulseSheet` above but is keyed off the
        // inserted FoodLog instead of CaptureViewModel state, since the
        // manual path doesn't pass through `.moodPulse`.
        .sheet(item: $pendingManualMoodLog) { log in
            MoodPulseSheet(
                onPick: { mood in
                    Task { await recordMoodForManualLog(log, mood: mood) }
                },
                onSkip: {}
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .modifier(ManualLogToastModifier(
            toast: $manualLogToast,
            onScanAction: {
                if SubscriptionManager.shared.scansRemainingToday > 0 {
                    manualLogToast = nil
                    requestScan()
                } else {
                    // Phase 22 — over the daily cap: route to the
                    // paywall instead of swallowing the tap silently.
                    manualLogToast = nil
                    showingPaywall = true
                }
            },
            onTrackerAction: {
                manualLogToast = nil
                notifRouter.requestTab(1)
            }
        ))
        // Phase 22 — scan-limit sheet. Driven by the CaptureViewModel's
        // `scanLimitHit`, which is set when /analyze responds with the
        // structured 429. The sheet keeps the user moving: Upgrade to
        // Pro (opens PaywallView) OR Log Manually (opens ManualLogSheet).
        .sheet(item: $viewModel.scanLimitHit) { info in
            ScanLimitSheet(
                info: info,
                onUpgrade: {
                    viewModel.clearScanLimit()
                    showingPaywall = true
                },
                onManualLog: {
                    viewModel.clearScanLimit()
                    showingManualLog = true
                },
                onDismiss: {
                    viewModel.clearScanLimit()
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .environmentObject(SubscriptionManager.shared)
        }
        // Scan-budget explainer. Triggered by tapping the top-bar
        // scan counter chip. Single source of truth for "how do
        // scans work" — wraps the policy explanation and the upsell
        // in one sheet so users always reach both via one tap.
        .sheet(isPresented: $showingScanLimitsInfo) {
            ScanLimitsExplainerSheet(
                used: subscriptions.scansUsedToday,
                limit: subscriptions.dailyLimit,
                isPro: subscriptions.tier == .pro,
                isUnlimited: subscriptions.isUnlimited,
                onTryPro: {
                    // Dismiss this sheet first, then present the
                    // paywall on the next runloop tick. SwiftUI can
                    // only have one sheet at a time; this avoids the
                    // "second sheet swallowed" race.
                    showingScanLimitsInfo = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingPaywall = true
                    }
                }
            )
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(.regularMaterial)
        }
        // Phase 21.5 — quest card → action sheet routing. Both options
        // hand off to the existing scan + manual-log paths. The
        // completion state is used only to swap the title copy so the
        // user understands they can keep logging after the quest is
        // done.
        .confirmationDialog(
            viewModel.questCompleted
                ? "Quest done — want to log more?"
                : "How would you like to log it?",
            isPresented: $showingQuestActionSheet,
            titleVisibility: .visible
        ) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    requestScan()
                }
            }
            Button("Choose from Library") {
                presentLibraryPicker()
            }
            Button("Log Without Photo") {
                showingManualLog = true
            }
            Button("Cancel", role: .cancel) {}
        }
        // Phase 21.5 — load today's quest on appear and on every
        // scene-phase active transition (so a user who left the app
        // running overnight sees today's new quest rather than
        // yesterday's). Fire-and-forget; the load itself is silent
        // on failure.
        .task {
            guard isActive else { return }
            scheduleHomeActivationWork(reason: .initialAppear)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard isActive else { return }
                scheduleHomeActivationWork(reason: .tabBecameActive)
            } else {
                photoLoadTask?.cancel()
                photoLoadTask = nil
                photosSelection = nil
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                scheduleHomeActivationWork(reason: .tabBecameActive)
            } else {
                homeActivationTask?.cancel()
                homeActivationTask = nil
                mirrorPreview.cancelPendingRefresh()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .foodLogDidChange)
        ) { _ in
            // Mirror tab listens to the same event; Home does the
            // same so the preview card stays in sync after a save
            // without the user having to leave Home.
            mirrorPreview.markDirty()
            if isActive {
                mirrorPreview.scheduleDebouncedRefresh(reason: .foodLogChanged)
            }
            // Live "left today" scoreboard: a saved/edited/deleted meal
            // shifts today's totals, so refresh the cached goal status
            // immediately instead of waiting for the next idle pass — the
            // TodayGoalCard + daily check-in update the moment a meal lands.
            Task { @MainActor in
                let snapshot = await CalorieReminderService.shared.currentSnapshot()
                cachedCalorieStatus = snapshot.status
                if let count = snapshot.mealCount {
                    cachedTodayMealCount = count
                }
            }
        }
        // Phase 21.11 — quest-completion celebration modal. Sits on
        // top of all main Home content (zIndex pushes it above the
        // success sheet's adjacent layers too). Renders whenever
        // `justCompletedQuest` is non-nil; clears the trigger from
        // its own `onDismiss` so the parent doesn't need a timer.
        .overlay {
            if let moment = viewModel.justCompletedQuest {
                QuestCelebrationModal(
                    moment: moment,
                    onDismiss: {
                        viewModel.clearJustCompletedQuest()
                        // Promote a stashed manual-log mood pulse so it
                        // appears AFTER the quest celebration instead
                        // of racing it. A short delay lets the modal's
                        // opacity fade finish before the sheet rises.
                        if let log = manualLogAwaitingMood {
                            manualLogAwaitingMood = nil
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 350 * NSEC_PER_MSEC)
                                pendingManualMoodLog = log
                            }
                        }
                        // Phase 21.13 — same handoff for the scan-image
                        // flow. The view model stashed the mood-pulse
                        // snapshot when `discardSaved()` ran with the
                        // quest celebration pending; promote it now so
                        // the order is celebration → mood, not mood
                        // racing or overlaying the modal.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350 * NSEC_PER_MSEC)
                            viewModel.promotePendingMoodPulse()
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .animation(.motionBase, value: viewModel.justCompletedQuest)
    }

    /// Phase 21 — post-manual-save side-effects. Fires streak + quest
    /// updates (best-effort), refreshes the cached scan-warning data,
    /// bumps the local rhythm store so Home's check-in copy reflects
    /// continuity, and drops a small banner with optional quest
    /// reward + free-tier scan nudge.
    private func handleManualLogSaved(_ inserted: FoodLog) {
        LoggingRhythmStore.shared.markToday()
        // Manual logs (database picks + custom entries) feed the same
        // on-device belief store as the photo flow, so the next time
        // the user scans the same dish the personalization chip can
        // light up from the typed entries too.
        LocalNutritionBeliefStore.shared.update(from: inserted)

        // Streak + quest in a detached Task so the toast renders
        // immediately. The quest evaluator's result drives the
        // optional reward copy on the toast — wait for it before
        // setting toast state so the user sees the right thing.
        Task { @MainActor in
            _ = try? await StreakService.shared.recordLog(
                at: inserted.eatenAt
            )
            let evaluation = try? await DailyQuestService.shared
                .evaluateQuestProgress(after: inserted)

            // Phase 21.10 — when a manual save completes today's
            // quest, fire the live-completion animation on the Home
            // quest card. The manual-log sheet dismisses back into
            // Home with the card right in front of the user, so the
            // morph happens in view.
            let questFired = evaluation?.questCompleted == true
                          && evaluation?.rewardCopy != nil
            if questFired, let reward = evaluation?.rewardCopy {
                viewModel.recordQuestCompletion(rewardCopy: reward)
            }

            // Mood pulse ordering: if the quest celebration is about
            // to play, stash the log and promote it after the modal
            // dismisses (handled in the QuestCelebrationModal
            // onDismiss hook). Otherwise present mood pulse now.
            if questFired {
                manualLogAwaitingMood = inserted
            } else {
                pendingManualMoodLog = inserted
            }

            // Refresh the today's-meals count + calorie status caches
            // since the manual save just shifted both.
            let snapshot = await CalorieReminderService.shared.currentSnapshot()
            cachedCalorieStatus = snapshot.status
            if let count = snapshot.mealCount {
                cachedTodayMealCount = count
            }

            manualLogToast = ManualLogToast(
                foodName: inserted.foodName,
                questRewardCopy: evaluation?.rewardCopy,
                scansRemaining: SubscriptionManager.shared.scansRemainingToday,
                isUnlimited: SubscriptionManager.shared.isUnlimited
            )
        }
    }

    /// Writes a mood for a just-saved manual log. Mirrors the photo
    /// flow's `CaptureViewModel.recordMood` but is intentionally
    /// standalone — the manual path doesn't enter `.moodPulse` state,
    /// so there's no view-model anchor to reuse. Failures are silent;
    /// mood is enrichment, not critical.
    ///
    /// FoodOS V2: after a successful DB patch, resolve any pending
    /// "I'll try this" experiment against this log + mood so the
    /// learning loop also closes on the manual flow.
    private func recordMoodForManualLog(_ log: FoodLog, mood: FoodLog.Mood) async {
        let service = FoodLogService()
        do {
            _ = try await service.setMood(mood, on: log.id)
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
            _ = FoodOSMomentFeedbackStore.shared.resolveExperiment(
                for: log, mood: mood, now: Date()
            )
        } catch {
            #if DEBUG
            NSLog("[Mood] manual-log setMood FAILED id=%@ err=%@",
                  log.id.uuidString, "\(error)")
            #endif
        }
    }

    // MARK: - Top bar (wordmark + avatar)

    private var topBar: some View {
        HStack(alignment: .center) {
            Text("foodie.")
                .appFont(.title1)
                .foregroundStyle(Color.ink)

            Spacer()

            // Phase 22 — scan counter chip. Updates live via the
            // @EnvironmentObject SubscriptionManager. Tapping when
            // 0 remaining routes to the paywall; otherwise non-tap
            // (decorative) so the user isn't sent away mid-flow.
            scanCounterChip
                .padding(.trailing, AppSpacing.sm)

            // Tap the avatar to jump to the Profile tab. Uses the
            // notification router so the switch happens at the TabView
            // host (MainTabView) instead of pushing a navigation stack
            // inside Home.
            Button {
                Haptics.tap()
                notifRouter.requestTab(2)
            } label: {
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
                // Pro-only halo around the top-bar avatar — same gold
                // ring as Profile so the cue is consistent everywhere
                // the avatar appears.
                .proAvatarRing(active: subscriptions.tier == .pro, lineWidth: 2, inset: -2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .accessibilityHint("Opens your profile")
        }
        .frame(maxWidth: .infinity)
    }

    /// Phase 22 — small "scans left today" chip lives on the top bar.
    /// Reads the live `SubscriptionManager` so the count decrements
    /// the moment a scan succeeds. At 0 remaining the chip morphs into
    /// a soft peach "Out · Go Pro" warning state with a pulsing halo
    /// and a one-shot wiggle, and becomes the tap target → paywall.
    /// Free users see "N left"; Pro users read "Unlimited" with a crown
    /// and no number — the silent safety cap is never surfaced.
    ///
    /// Visuals & motion are owned by `ScanCounterChip` so it can hold
    /// its own animation state without forcing every CaptureView
    /// render to re-animate.
    @ViewBuilder
    private var scanCounterChip: some View {
        ScanCounterChip(
            remaining: subscriptions.scansRemainingToday,
            limit: subscriptions.dailyLimit,
            isPro: subscriptions.tier == .pro,
            isUnlimited: subscriptions.isUnlimited,
            isActive: isActive
        ) {
            // Any state → explainer modal. The modal carries the
            // "Try Pro" CTA itself so out-of-scans users still have a
            // single tap to upgrade after seeing the policy.
            Haptics.tap()
            showingScanLimitsInfo = true
        }
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

        // Photo card sits directly under the hero so a first-time
        // user sees the scan affordance within the first viewport —
        // no scrolling past secondary cards to find the primary
        // action. The pinned bottom "Take a photo" CTA mirrors it.
        // Live "left today" scoreboard — the always-on goal anchor, placed
        // above the photo card so it's glanceable without scrolling. Shows
        // only when idle and a real goal exists (first-timers without a goal
        // still get an uncrowded photo card at the top). Reads the same
        // cached status the result screen uses; refreshes the instant a meal
        // saves via the `.foodLogDidChange` hook above. Taps to Tracker.
        if viewModel.state.isIdle,
           let status = cachedCalorieStatus, status.hasValidGoal {
            TodayGoalCard(
                status: status,
                goalDirection: profileStore.profile?.weightGoalDirection,
                bodyWeightKg: profileStore.profile?.weightKg
            ) {
                Haptics.tap()
                notifRouter.requestTab(1)
            }
            .padding(.top, AppSpacing.lg)
            .transition(.opacity)
        }

        photoCard
            .padding(.top, AppSpacing.xl)

        if viewModel.state.isIdle {
            // First-time activation hint sits closest to the photo
            // card so the encouragement lands where the user is
            // looking. Drops out after the first save (rhythm store
            // flips totalLoggedDays to 1).
            if rhythmStore.rhythm().totalLoggedDays == 0 {
                firstScanActivationHint
                    .padding(.top, AppSpacing.md)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            // Quick re-log row — promoted secondary path for returning
            // users. Re-logging copies a past meal in two taps (no photo,
            // no AI, no scan credit) — the lowest-friction way to log, so
            // it's a pair of tappable chips, not a buried text link.
            quickLogRow
                .padding(.top, AppSpacing.md)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }

        // Phase 21.5 — daily quest card. Now lives below the primary
        // scan surface so it never crowds the photo card. Gated on
        // `profile.healthyChoicesEnabled` (Phase 21.12).
        if viewModel.state.isIdle,
           let quest = viewModel.dailyQuest,
           profileStore.profile?.healthyChoicesEnabled ?? true {
            DailyQuestCard(
                quest: quest,
                completed: viewModel.questCompleted,
                completionMoment: viewModel.justCompletedQuest,
                onTap: {
                    Haptics.tap()
                    showingQuestActionSheet = true
                }
            )
            .padding(.top, AppSpacing.xl)
            .transition(.opacity)
        }

        // Daily Check-in line. Count-aware, deterministic.
        if viewModel.state.isIdle, let count = cachedTodayMealCount {
            DailyCheckInCard(
                mealCount: count,
                rhythm: rhythmStore.rhythm(),
                status: cachedCalorieStatus,
                now: Date()
            )
            .padding(.top, AppSpacing.md)
            .transition(.opacity)
        }

        // Food Mirror preview — lives below the scan surface so it
        // never competes with "Take a photo". Reads as a calm,
        // tappable side-glance rather than a primary action.
        if viewModel.state.isIdle, let preview = mirrorPreview.cardModel {
            HomeMirrorPreviewCard(model: preview) {
                notifRouter.requestTab(2)
            }
            .padding(.top, AppSpacing.md)
            .transition(.opacity)
        }

        // Analyze status / errors hover here while a request is in flight
        analyzeStatus
            .padding(.top, AppSpacing.lg)
    }

    private var photoCard: some View {
        Button {
            Haptics.tap()
            requestScan()
        } label: {
            // `Color.clear.aspectRatio(1, .fit)` reserves a guaranteed
            // 1:1 layout slot at the parent's width, INDEPENDENT of
            // child sizes — the previous `ZStack { … }.aspectRatio(…)`
            // pattern let a tall input UIImage push the ZStack past the
            // proposed square because `scaledToFill` renders beyond the
            // layout frame. Putting the ZStack inside `.overlay { … }`
            // bounds it to the cleared square; outer `.clipped()` is the
            // final visual safety net so nothing draws past the corners.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.xl2)
                            .fill(Color.bgSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.xl2)
                                    .strokeBorder(Color.borderHairline, lineWidth: 1)
                            )
                            .appShadow(.shadowCard)

                        if let image = viewModel.state.image {
                            // Bubble mode only: a dim + food-tinted living
                            // halo sits BEHIND the photo so the gooey photo
                            // bubble reads as floating on a Siri-like field.
                            // Fades in/out with analyzing via the photoCard's
                            // `.animation(value: isAnalyzing)`.
                            if (bubbleMorphActive || orbJourneyActive),
                               viewModel.state.isThinking {
                                bubbleAnalyzingField
                                    .transition(.opacity)
                            }
                            DelightfulImageEntry(
                                image: image,
                                // Once analysis is underway the morph owns the
                                // photo's shape — gate the bounce-in so it
                                // doesn't fight it. No-op when the morph is off
                                // (initial pick still bounces).
                                suppressEntrance: suppressPhotoEntranceForMorph
                            )
                                .id(ObjectIdentifier(image))
                                // Bubble mode: while analyzing, the photo
                                // itself morphs into a gooey, breathing bubble
                                // (progress 0 = full card → 1 = liquid blob),
                                // then un-forms back to the card as analysis
                                // ends — a fluid handoff into the next step.
                                // No-op (passes through) when the morph is off,
                                // and when the orb journey owns the analyzing
                                // visual (the photo lifts out instead).
                                .modifier(ConditionalBubbleMask(
                                    active: bubbleMorphActive && !orbJourneyActive,
                                    progress: viewModel.state.isThinking ? 1 : 0,
                                    cornerRadius: AppRadius.xl2
                                ))
                                // Matched-geometry SOURCE for the later
                                // photo→result handoff (.confirmingName/
                                // .clarifying → .ready). Gated separately and
                                // currently off; no-op modifier in that case.
                                .modifier(MealMorphMatch(
                                    namespace: photoResultHandoffActive ? mealMorph : nil,
                                    isSource: true
                                ))
                                // Orb journey: this photo's frame is where the
                                // orb launches from / returns to. While the orb
                                // is flying, the in-card photo fades so it reads
                                // as having lifted out of the card.
                                .orbSourceAnchor()
                                .opacity(orbJourneyActive && viewModel.state.isThinking ? 0 : 1)
                                .animation(.easeOut(duration: 0.22),
                                           value: viewModel.state.isThinking)
                            // First-scan magic: brand-tinted glow ring that
                            // radiates around the photo as it lands. Owns its
                            // own fade-out via `.task`. Suppressed during the
                            // morph window so its fixed xl2 ring can't clip
                            // against the photo's changing shape.
                            if firstScanGlowVisible, !suppressPhotoEntranceForMorph {
                                FirstScanGlow {
                                    firstScanGlowVisible = false
                                }
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                            }
                            if viewModel.state.isThinking, !orbJourneyActive {
                                if bubbleMorphActive {
                                    // Bubble mode: the photo IS the bubble, so
                                    // the analyzing chrome is just the dots
                                    // badge floating over it.
                                    bubbleAnalyzingBadge
                                        .transition(.opacity)
                                } else {
                                    // Original mode: aura overlay over the
                                    // photo. Pro analyses get a champagne tint.
                                    AnalyzingImageAura(
                                        isPro: subscriptions.tier == .pro,
                                        foodPalette: foodPalette,
                                        isActive: isActive
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                                    .transition(analyzingAuraTransition)
                                    .allowsHitTesting(false)
                                }
                            }
                        } else {
                            photoCardEmptyContent
                                .transition(
                                    .scale(scale: 1.06).combined(with: .opacity)
                                )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            viewModel.state.isThinking ? "Analyzing meal photo"
            : viewModel.state.image == nil ? "Tap to add a photo"
                                           : "Change meal photo"
        )
        // Bouncy spring for the empty ↔ image swap so the photo lands
        // with a Duolingo-style overshoot. The image's own entrance
        // choreography (DelightfulImageEntry) layers on top of this,
        // so the user sees: empty halo pops out → image scales in past
        // 1.0, settles, then a tiny secondary stamp confirms the moment.
        .animation(.appBouncy, value: viewModel.state.image == nil)
        // Snappy spring so the aura's removal reads as a "lock-in" — the
        // colored blobs collapse toward center as the result reveals,
        // rather than crossfading. Insertion (opacity) barely registers
        // the spring; the contract is where it earns its keep.
        .animation(
            reduceMotion ? .appReduced : .appMorph,
            value: viewModel.state.isThinking
        )
        .disabled(viewModel.state.isThinking)
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
        .overlay(alignment: .topLeading) {
            if showsChangePhotoButton {
                RemovePhotoButton {
                    Haptics.soft()
                    removePickedPhoto()
                }
                .padding(AppSpacing.sm)
                .transition(
                    .scale(scale: 0.6).combined(with: .opacity)
                )
            }
        }
        .animation(.appBouncy, value: showsChangePhotoButton)
    }

    /// Bubble mode only: the ambient field rendered BEHIND the gooey photo
    /// bubble while analyzing — a soft dim plus the food-tinted living glow,
    /// so the bubble reads as floating on a Siri-like surface. Self-timed
    /// via its own TimelineView; clipped to the card and non-interactive.
    @ViewBuilder
    private var bubbleAnalyzingField: some View {
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black.opacity(0.14)
                SiriFluidGlow(
                    time: seconds,
                    isPro: subscriptions.tier == .pro,
                    palette: foodPalette
                )
                .blur(radius: 18)
                .opacity(0.55)
                .blendMode(.screen)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
        .allowsHitTesting(false)
    }

    /// Bubble mode only: the analyzing dots badge floating over the photo
    /// bubble, bottom-trailing. The bubble itself communicates "analyzing,"
    /// so this is the only chrome on top.
    private var bubbleAnalyzingBadge: some View {
        AnalyzingDotsBadge()
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .bottomTrailing)
            .padding(AppSpacing.md)
            .allowsHitTesting(false)
    }

    /// The analyzing aura's "lock-in": insertion is a plain opacity fade,
    /// but removal contracts the colored glow toward center (scale → 0.2,
    /// anchor `.center`) while fading and picking up a small blur bump —
    /// so when analysis finishes the blobs visibly collapse inward as the
    /// result reveals, rather than crossfading out. Driven by the snappy
    /// `.appMorph` spring on the photo card. Under Reduce Motion both
    /// directions degrade to a plain opacity fade.
    private var analyzingAuraTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity,
            removal: .opacity
                .combined(with: .scale(scale: 0.2, anchor: .center))
                .combined(with: .modifier(
                    active: AuraCollapseBlur(radius: 8),
                    identity: AuraCollapseBlur(radius: 0)
                ))
        )
    }

    /// The result reveal's "focus-pull". The analysis content enters
    /// diffuse (blur 16) and resolves to crisp as it rises and fades in,
    /// timed to the same `.appMorph` spring that animates the idle→result
    /// switch — so the analysis "comes into focus" exactly as the analyzing
    /// bubble collapses inward (see `analyzingAuraTransition`). Under Reduce
    /// Motion the blur ramp is dropped for a plain opacity fade.
    private var resultRevealTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        // Only when the matched-geometry result handoff is engaged does the
        // photo carry itself into place — then a container move + focus-pull
        // blur would fight it. With the handoff off (today), keep the full
        // focus-pull crossfade below.
        if photoResultHandoffActive {
            return .opacity
        }
        return .opacity
            .combined(with: .move(edge: .bottom))
            .combined(with: .modifier(
                active: FocusPullBlur(radius: 16),
                identity: FocusPullBlur(radius: 0)
            ))
    }

    /// Show the floating "change photo" button only after the user has
    /// a working image AND we're still in the pre-analyze window.
    private var showsChangePhotoButton: Bool {
        if case .picked = viewModel.state { return true }
        return false
    }

    private func removePickedPhoto() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photosSelection = nil
        firstScanGlowVisible = false
        viewModel.discardCurrent()
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

    /// Promoted quick-log row for returning users: re-log a recent meal or a
    /// favorite in two taps — no photo, no AI, no scan credit. This is the
    /// lowest-friction path in the app, so it's surfaced as tappable chips
    /// rather than the old buried text link. The favorites chip only appears
    /// once the user has hearted at least one meal.
    private var quickLogRow: some View {
        VStack(spacing: AppSpacing.xs) {
            Text("Already had it? Re-log in a tap")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
            HStack(spacing: AppSpacing.sm) {
                quickLogChip(title: "Recent meals",
                             systemImage: "clock.arrow.circlepath") {
                    showingRecentMeals = true
                }
                if !favoritesStore.favorites.isEmpty {
                    quickLogChip(title: "Favorites",
                                 systemImage: "heart.fill") {
                        showingFavoriteMeals = true
                    }
                }
            }
        }
    }

    /// One tappable pill in `quickLogRow`. Bordered so it reads as a button,
    /// not a text link — matching the brand's quiet-but-clear chip style.
    private func quickLogChip(title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .appFont(.captionStrong)
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.bgSurface))
            .overlay(Capsule().strokeBorder(Color.brand.opacity(0.30), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) — re-log a meal without a photo")
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

    /// Lifetime-empty activation hint. One short, encouraging line so the
    /// first session feels obvious without instructional copy or modals.
    /// `LoggingRhythmStore.markToday()` flips the lifetime counter on
    /// first save; this view drops out on the next render — no dismissal
    /// flag needed.
    private var firstScanActivationHint: some View {
        Text("Your first photo starts the picture.")
            .appFont(.caption)
            .foregroundStyle(Color.brandDeep)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Tip: your first photo starts the picture.")
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

    /// Map the current capture state to the reward pill's phase.
    /// `.ready` and `.saveFailed` collapse to `.idle` so the pill
    /// doesn't claim success before the row lands — and so a transient
    /// save failure doesn't briefly read "Added to today" while the
    /// state was already passing through `.saving`.
    private var saveRewardPhase: SaveRewardPhase {
        switch viewModel.state {
        case .saving:           return .saving
        case .saved, .moodPulse: return .saved
        default:                 return .idle
        }
    }

    @ViewBuilder
    private var resultFlow: some View {
        if let payload = saveFlowPayload {
            VStack(spacing: AppSpacing.md) {
                AnalysisResultView(
                    image: payload.image,
                    response: payload.response,
                    isSaving: viewModel.state.isSaving,
                    saveRewardPhase: saveRewardPhase,
                    // Pass the pre-scan calorie status so the result view
                    // can render its small day-aware impact line. Status
                    // is taken at scan-time (before this meal), exactly
                    // what `predictedImpactCopy` expects to fold the
                    // analyzed calories into.
                    dailyStatus: cachedCalorieStatus,
                    // Strava-for-food loop: goal direction + body weight let
                    // the result show "X left today" and, when over (and not
                    // a gain goal), a personalized "earn it back" walk/jog.
                    goalDirection: profileStore.profile?.weightGoalDirection,
                    bodyWeightKg: profileStore.profile?.weightKg,
                    foodNameOverride: viewModel.editedFoodName,
                    patternInsight: viewModel.patternInsight,
                    onFoodNameEdited: { name in
                        viewModel.applyFoodNameEdit(name)
                    },
                    onFoodNameCorrected: { name in
                        Task { await viewModel.reanalyzeWithCorrectedName(name) }
                    },
                    // Destination half of the matched-geometry pair. Gated on
                    // the (currently-off) result handoff, so it's nil today
                    // and the result photo renders with its normal reveal.
                    // Declared after onFoodNameCorrected, so it must appear
                    // here (before onSave) to match memberwise-init order.
                    morphNamespace: photoResultHandoffActive ? mealMorph : nil,
                    // Hold the breakdown reveal until the genie warp lands, so
                    // the warp plays first and the text doesn't type over a
                    // mid-flight orb. Zero when the orb journey is off (Reduce
                    // Motion / feature flag / non-DI) → today's instant reveal.
                    revealDelay: orbJourneyActive ? AnalyzingOrbTiming.returnSettleSeconds : 0,
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
            .transition(resultRevealTransition)
        } else {
            switch viewModel.state {
            case .noFood:
                NoFoodView(onTryAnother: {
                    viewModel.resetToPick()
                    requestScan()
                })
                .padding(.top, AppSpacing.xl2)
                .transition(.opacity)

            case .failed(_, let error):
                FailedView(
                    error: error,
                    onRetry: { Task { await viewModel.analyze() } },
                    onTryAnother: {
                        viewModel.resetToPick()
                        requestScan()
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
            bottomCTAChrome {
                VStack(spacing: AppSpacing.sm) {
                    PrimaryButton(title: "Take a photo",
                                  leadingSystemImage: "camera.fill") {
                        Haptics.tap()
                        requestScan()
                    }
                    // Phase 21 — secondary path for typing-based logging.
                    // Lives directly under the primary so the user can see
                    // both options at once without an extra tap to reveal.
                    Button {
                        Haptics.tap()
                        showingManualLog = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .heavy))
                            Text("Or log without a photo")
                                .appFont(.captionStrong)
                        }
                        .foregroundStyle(Color.brandDeep)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log a meal without a photo")
                }
            }
        case .picked:
            bottomCTAChrome {
                PrimaryButton(title: "Analyze",
                              leadingSystemImage: "sparkles") {
                    Task { await viewModel.analyze() }
                }
            }
        case .analyzing:
            bottomCTAChrome {
                PrimaryButton(title: "Analyzing…", isLoading: true) {}
            }
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
        case .clarifying, .confirmingName:
            // The name-confirmation / Quantity Clarification sheet owns
            // the user's attention. No bottom CTA so the underlying photo
            // card reads as a quiet background, not a competing affordance.
            EmptyView()
        }
    }

    /// Background chrome for the pinned bottom CTA cluster. Wraps the
    /// passed content with horizontal/vertical padding plus a
    /// canvas-colored fill that extends through the bottom safe area,
    /// preceded by a short gradient fade so the scrolling content above
    /// dissolves into the canvas instead of bleeding through the buttons.
    /// Applied per-case (not on the whole ZStack overlay) so the empty
    /// CTA states — `.ready`, `.moodPulse`, `.clarifying`, etc. — don't
    /// draw a phantom bar.
    @ViewBuilder
    private func bottomCTAChrome<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.bgCanvas.opacity(0), Color.bgCanvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                    Color.bgCanvas
                }
                .ignoresSafeArea(edges: .bottom)
            }
    }

    // MARK: - Calorie-goal scan warning (Phase 20)

    /// Entry point for a fresh photo-source dialog. Checks today's
    /// calorie status first; if the user is approaching/over their
    /// daily goal we surface a friendly confirmation before opening
    /// the picker. Non-blocking — the user can always pick "Scan
    /// anyway." The bypass flag is consumed so the very next press
    /// re-evaluates honestly.
    ///
    /// If the cache hasn't landed yet (first press during the appear
    /// fetch), we fall through to the picker rather than block the user
    /// on a network round-trip. The pre-fetch in `.task` is fast enough
    /// for this race to be exceedingly rare; the in-app reminder on
    /// Tracker remains the reliable guidance path.
    private func requestScan() {
        if bypassCalorieWarningOnce {
            bypassCalorieWarningOnce = false
            showingSourceDialog = true
            return
        }

        if let cached = cachedCalorieStatus,
           let kind = Self.scanWarningKind(for: cached) {
            calorieScanWarning = kind
            return
        }

        showingSourceDialog = true
    }

    private static func scanWarningKind(
        for status: DailyCalorieGoalStatus
    ) -> ScanWarningKind? {
        guard status.hasValidGoal else { return nil }
        switch status.warningState {
        case .reached:     return .reached
        case .approaching: return .approaching
        case .safe:        return nil
        }
    }

    /// Title / body / action labels for the calorie-goal warning dialog.
    /// Static so `CalorieScanWarningModifier` can reuse them without a
    /// view-instance reference.
    fileprivate static func scanWarningTitle(_ kind: ScanWarningKind) -> String {
        switch kind {
        case .reached:     return "You've reached today's goal."
        case .approaching: return "You're close to today's goal."
        }
    }

    fileprivate static func scanWarningMessage(_ kind: ScanWarningKind) -> String {
        switch kind {
        case .reached:
            return "Log gently from here — this one will tip you over."
        case .approaching:
            return "Still room for this one — just a friendly heads up."
        }
    }

    // MARK: - After-save next-step suggestion

    /// Computes a small inline hint for the saved-confirmation sheet.
    /// Inputs come from caches already maintained by this view plus the
    /// just-saved response carried by the current `.saved` state — no
    /// new fetch is started here.
    ///
    /// `cachedCalorieStatus` is taken at scan-time, which is *before*
    /// the meal we just inserted. To pick the right copy we estimate
    /// the post-save status by folding the saved meal's calories into
    /// the cached `consumed`. Otherwise a meal that crosses the goal
    /// would still read "Still room left today."
    private func computedNextStepHint() -> NextStepHint? {
        let lifetimeDays = rhythmStore.rhythm().totalLoggedDays

        // First-ever save — celebrate without nudging anywhere in
        // particular. "View today" is the natural follow-up.
        if lifetimeDays <= 1 {
            return NextStepHint(
                message: "Nice — your first day is started.",
                actionLabel: "View today",
                action: .viewTracker
            )
        }

        // From here we need a valid pre-save status to give useful
        // direction. Missing/invalid status falls back to the generic
        // "Added to today." line.
        guard let cached = cachedCalorieStatus, cached.hasValidGoal else {
            return NextStepHint(
                message: "Added to today.",
                actionLabel: nil,
                action: nil
            )
        }

        // Fold the just-saved meal's calories into the pre-save total.
        // Calories may be nil on a sparse analyze response — treat that
        // as 0 rather than wedge the suggestion path. Reuses the same
        // `compute` rules as the rest of the app so the hint can never
        // disagree with the Today ring's warning state.
        let savedCalories = savedMealCalories ?? 0
        let postSaveStatus = DailyCalorieGoalStatus.compute(
            consumed: cached.consumed + savedCalories,
            goal: cached.goal
        )

        if postSaveStatus.warningState == .reached || postSaveStatus.exceededBy > 0 {
            return NextStepHint(
                message: "Goal reached for today.",
                actionLabel: "View tracker",
                action: .viewTracker
            )
        }
        if postSaveStatus.warningState == .approaching {
            return NextStepHint(
                message: "You're close to today's goal.",
                actionLabel: "View tracker",
                action: .viewTracker
            )
        }
        return NextStepHint(
            message: "Still room left today.",
            actionLabel: "Scan another meal",
            action: .scanAnother
        )
    }

    /// Pulls the calories of the meal we just saved out of the current
    /// state. Only valid inside the `.saved` window — the suggestion
    /// path is only invoked there, but the lookup is defensive in case
    /// the state has moved on by the time SwiftUI re-evaluates the
    /// sheet body.
    private var savedMealCalories: Double? {
        if case .saved(_, let response, _) = viewModel.state {
            return response.analysis.calories
        }
        return nil
    }

    /// Routes the inline next-step action. The sheet dismisses itself
    /// after this fires; we only need to set up where the user ends up.
    private func handleNextStepAction(_ action: NextStepHint.Action) {
        viewModel.discardSaved()
        switch action {
        case .viewTracker:
            notifRouter.requestTab(1)
        case .scanAnother:
            // Already on Home; dismissing the saved sheet lets the
            // user return to the idle capture flow. Nothing to do.
            break
        }
    }

    // MARK: - Library picker plumbing

    private func presentLibraryPicker() {
        // Reset prior selection so onChange fires even if user picks the
        // same image twice in a row.
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photosSelection = nil
        isShowingLibrary = true
    }

    private func scheduleHomeActivationWork(reason: RefreshReason) {
        homeActivationTask?.cancel()
        homeActivationTask = Task { @MainActor in
            TabPerformanceProbe.appeared(.home)
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            TabPerformanceProbe.firstFrameYielded(.home)
            await viewModel.loadQuest()
            await mirrorPreview.refresh(reason: reason, tab: .home)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Reduce Motion: don't start the breathing loop. Halo stays
            // at rest; the camera icon still reads as the affordance.
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Daily Check-in card

/// Retention-polish replacement for the prior `TodayPulseCard`. Combines:
///
///   1. **Primary check-in copy** — deterministic, count-aware, never
///      shaming. Mirrors the design contract:
///          0 meals → "Start today with one photo."
///          1 meal  → "Nice start — 1 meal logged today."
///          2 meals → "You're building today's picture."
///         3+ meals → "Today is well tracked."
///      The 0-meal branch is personalized when the local rhythm store
///      knows the user logged recently:
///          yesterdayLogged → "Back from yesterday — start today with one photo."
///          last log ≤ 30d  → "Your last log was {Friday|date}. Ready for today's first meal?"
///
///   2. **Secondary sub-line (optional)** — combined with the count when
///      a valid daily calorie goal exists. Examples:
///          "2 meals logged · about 420 calories left"
///          "3 meals logged · goal reached"
///      Or, on the empty path, a rhythm cue:
///          "First check-in logged." / "You're on a 4-day logging rhythm."
///
///   3. **End-of-day return hook** — inline footer, only visible after
///      20:00 local *and* at least one meal logged today. Quiet, no
///      modal, no notification, no infinite animation:
///          "Your day is almost complete. Come back tomorrow for a fresh pulse."
///
/// All inputs are pure data caches owned by the parent — there is no
/// polling, no timer, no retained `Task`. Repeated renders produce
/// identical copy for the same inputs (deterministic).
/// The always-on "Today" scoreboard on Home — a glanceable mini calorie
/// ring + the running headline ("1,240 left today" / "180 over today")
/// against the daily goal. The first beat of the goal loop made persistent:
/// you see where you stand without having to scan. Taps through to Tracker.
private struct TodayGoalCard: View {
    let status: DailyCalorieGoalStatus
    /// Goal direction + body weight power the "earn it back" line — same
    /// rule as the result screen: only for lose/maintain, never gain, and
    /// the minutes are personalized to the user's weight.
    var goalDirection: CalorieGoalCalculator.GoalDirection? = nil
    var bodyWeightKg: Double? = nil
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOver: Bool {
        status.exceededBy > 0 || status.warningState == .reached
    }
    /// Show the walk/jog burn-off only when genuinely over budget and the
    /// goal isn't to gain (where a surplus is the point).
    private var showBurnOff: Bool {
        status.exceededBy > 0 && goalDirection != .gain
    }
    private var clamped: Double { min(max(status.progress, 0), 1) }
    private var ringColor: Color { isOver ? Color.error : Color.brand }

    /// Headline figure, rounded to the nearest 10 for a calm read and
    /// grouped (1,240) by locale.
    private var headline: String {
        let value = isOver ? status.exceededBy : status.remaining
        let n = Int((value / 10).rounded() * 10)
        return isOver ? "\(n.formatted()) over today"
                      : "\(n.formatted()) left today"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .stroke(Color.borderHairline, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(ringColor,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.6, dampingFraction: 0.85),
                                   value: clamped)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .appFont(.title2)
                        .foregroundStyle(isOver ? Color.error : Color.ink)
                    Text("of \(Int(status.goal).formatted()) kcal goal")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)

                    if showBurnOff {
                        let walk = ActivityBurnEstimator.walkMinutes(
                            toBurn: status.exceededBy, weightKg: bodyWeightKg)
                        let jog = ActivityBurnEstimator.jogMinutes(
                            toBurn: status.exceededBy, weightKg: bodyWeightKg)
                        HStack(spacing: 5) {
                            Image(systemName: "figure.walk")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.brandDeep)
                            Text("\(walk)-min walk or \(jog)-min jog to burn it off")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    } else if let eatLine = MealSuggestionEngine.compactLine(
                                remaining: status.remaining) {
                        // Under goal → one calm line on what fits. The
                        // headline already carries the number.
                        HStack(spacing: 5) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.brandDeep)
                            Text(eatLine)
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
            )
            .appShadow(.shadowCard)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline)
        .accessibilityHint("Opens today's tracker")
    }
}

private struct DailyCheckInCard: View {
    let mealCount: Int
    let rhythm: LoggingRhythmStore.Rhythm
    let status: DailyCalorieGoalStatus?
    let now: Date

    /// Local hour above which the end-of-day return hook is permitted.
    /// Lives here (not in a service) because the hook is purely a UI
    /// concern — there is no notification or scheduler involved.
    private static let endOfDayHourLocal: Int = 20

    private var hasGoal: Bool {
        status?.hasValidGoal == true
    }

    private var isEndOfDay: Bool {
        Calendar.current.component(.hour, from: now) >= Self.endOfDayHourLocal
    }

    private var primaryText: String {
        switch mealCount {
        case 0:
            // Personalize the empty state when the rhythm store knows
            // the user has logged recently. Falls through to the
            // generic copy if there's no usable history.
            if rhythm.yesterdayLogged {
                return "Back from yesterday — start today with one photo."
            }
            if let last = rhythm.lastLoggedDate {
                return "Your last log was \(Self.relativeDayPhrase(for: last, now: now)). Ready for today's first meal?"
            }
            return "Start today with one photo."
        case 1:
            return "Nice start — 1 meal logged today."
        case 2:
            return "You're building today's picture."
        default:
            return "Today is well tracked."
        }
    }

    /// Optional sub-line. Order of precedence:
    ///   1. End-of-day hook (already-logged users in the 20:00+ window).
    ///   2. Calorie hint, combined with the count, when there's a goal
    ///      and at least one meal.
    ///   3. Calorie hint alone (empty state, valid goal).
    ///   4. Rhythm copy (first-ever check-in / multi-day rhythm).
    ///   5. Nothing.
    private var secondaryText: String? {
        if isEndOfDay, mealCount >= 1 {
            return "Your day is almost complete. Come back tomorrow for a fresh pulse."
        }
        // Calorie standing now lives in the always-on TodayGoalCard above,
        // so this card stays focused on rhythm/encouragement and doesn't
        // echo the same "X calories left" number twice on one screen.
        if let status, status.hasValidGoal, mealCount == 0 {
            // Empty state with a goal set — keep the calorie sub-line
            // quiet (we don't want to greet the user with their target
            // before they've logged anything). Surface rhythm instead
            // if it exists.
            if rhythm.consecutiveDays >= 2 {
                return "You're on a \(rhythm.consecutiveDays)-day logging rhythm."
            }
            return nil
        }
        if rhythm.todayLogged, rhythm.totalLoggedDays == 1 {
            return "First check-in logged."
        }
        if rhythm.consecutiveDays >= 2 {
            return "You're on a \(rhythm.consecutiveDays)-day logging rhythm."
        }
        return nil
    }

    /// Combined first line: meal-count copy with the calorie cue
    /// inlined when both are present. Example: "2 meals logged · about
    /// 420 calories left". Kept as a derived view of `primaryText` +
    /// `secondaryText` for the count-with-calorie variant only; all
    /// other states render the two lines stacked.
    private var combinedPrimary: String? {
        guard let status, status.hasValidGoal, mealCount >= 1 else { return nil }
        let countPhrase: String = {
            switch mealCount {
            case 1: return "1 meal logged"
            default: return "\(mealCount) meals logged"
            }
        }()
        let caloriePhrase: String
        if status.warningState == .reached || status.exceededBy > 0 {
            caloriePhrase = "goal reached"
        } else {
            caloriePhrase = "about \(Int(status.remaining.rounded())) calories left"
        }
        return "\(countPhrase) · \(caloriePhrase)"
    }

    private var iconName: String {
        if isEndOfDay, mealCount >= 1 { return "moon.stars.fill" }
        switch mealCount {
        case 0:  return "sun.max.fill"
        case 1:  return "leaf.fill"
        case 2:  return "leaf.fill"
        default: return "checkmark.seal.fill"
        }
    }

    private var iconAccent: Color {
        if mealCount >= 3 { return .brandDeep }
        return .brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.brandSoft)
                        .frame(width: 28, height: 28)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(iconAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(combinedPrimary ?? primaryText)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if combinedPrimary == nil, let secondary = secondaryText {
                        Text(secondary)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity)
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
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let combined = combinedPrimary { return combined }
        if let secondary = secondaryText {
            return "\(primaryText) \(secondary)"
        }
        return primaryText
    }

    /// Compact phrasing of a recent past date relative to `now`. Mirrors
    /// the rhythm store's 30-day cap; older dates would never land here.
    private static func relativeDayPhrase(for date: Date,
                                          now: Date,
                                          calendar: Calendar = .current) -> String {
        let dayDelta = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if dayDelta <= 1 { return "yesterday" }
        if dayDelta < 7 {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return f.string(from: date)
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

private struct RemovePhotoButton: View {
    let action: () -> Void
    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .heavy))
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
        .accessibilityLabel("Remove photo")
        .accessibilityHint("Return to the empty scan card")
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
    /// When true, skip the bounce-in entirely and render at identity. Used
    /// during the bubble→result morph so the matched-geometry effect owns
    /// the photo's transform instead of this entrance fighting it.
    var suppressEntrance: Bool = false
    @State private var landed: Bool = false
    @State private var stamping: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Treat the photo as fully landed (no transform) whenever the entrance
    /// is suppressed — derived rather than written to @State so there's no
    /// opacity-0 flash before `onAppear` would otherwise run.
    private var effectiveLanded: Bool { suppressEntrance || landed }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            // Without this frame cap, a tall input UIImage reports its
            // intrinsic pixel size as its layout size and the parent
            // photo card grows to fit, blowing past the screen. The
            // frame forces the image to accept the parent's proposed
            // size; `.clipped()` enforces the bounds in layout terms
            // before the rounded-rect clip handles the visual edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
            .scaleEffect(scale)
            // Reduce Motion: skip the rotation tilt so the image fades in
            // straight rather than swinging into place.
            .rotationEffect(.degrees(reduceMotion ? 0 : (effectiveLanded ? 0 : -6)))
            .opacity(effectiveLanded ? 1 : 0)
            .onAppear {
                guard !suppressEntrance else { return }
                runEntrance()
            }
    }

    private var scale: CGFloat {
        if suppressEntrance { return 1.0 }
        if reduceMotion { return 1.0 }
        if !landed { return 0.55 }
        return stamping ? 1.04 : 1.0
    }

    private func runEntrance() {
        // Reduce Motion: opacity-only entrance, no bounce, no stamp, no
        // haptic — keeps the user oriented but quiet.
        if reduceMotion {
            withAnimation(.appReduced) { landed = true }
            return
        }
        // Beat 1 — bounce in.
        withAnimation(.appBouncy) {
            landed = true
        }
        Task {
            // Cancellation-aware: if the view is torn down mid-entrance
            // (the photo card was rebuilt with a different image), bail
            // immediately rather than firing late haptics + state writes
            // against a defunct @State storage.
            do {
                // Beat 2 — soft land haptic just before the bounce settles.
                try await Task.sleep(nanoseconds: 320_000_000)
                await MainActor.run { Haptics.soft() }

                // Beat 3 — stamp pulse, then release back to identity.
                try await Task.sleep(nanoseconds:  80_000_000)
                await MainActor.run {
                    withAnimation(.appStamp) { stamping = true }
                }
                try await Task.sleep(nanoseconds: 180_000_000)
                await MainActor.run {
                    withAnimation(.appPress) { stamping = false }
                }
            } catch {
                return
            }
        }
    }
}

// MARK: - First-scan celebratory glow

/// Lifetime-first-scan delight. A brand-tinted ring fades in around the
/// photo card, scales up slightly, then fades out — under a second from
/// start to finish. Owns its own lifecycle via SwiftUI's `.task`, which
/// SwiftUI cancels automatically when the view leaves the tree, so the
/// host doesn't have to retain a delayed `Task` to cancel.
///
/// Reduce Motion path: opacity-only crossfade, no scale, same duration
/// budget. No haptic — DelightfulImageEntry already fires the land
/// haptic and stacking a second would double-tap the user.
private struct FirstScanGlow: View {
    let onDone: () -> Void
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl2)
            .strokeBorder(Color.brand, lineWidth: 3)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
            .task {
                do {
                    if reduceMotion {
                        withAnimation(.appReduced) { opacity = 0.55 }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 700)
                        try Task.checkCancellation()
                        withAnimation(.appReduced) { opacity = 0 }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 220)
                    } else {
                        withAnimation(.easeOut(duration: 0.45)) {
                            opacity = 0.75
                            scale = 1.08
                        }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 520)
                        try Task.checkCancellation()
                        withAnimation(.easeIn(duration: 0.32)) {
                            opacity = 0
                        }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 340)
                    }
                    try Task.checkCancellation()
                } catch {
                    return
                }
                onDone()
            }
    }
}

// MARK: - Analyzing image aura

/// Siri-inspired analyzing state for the selected image. The effect uses
/// the same ingredients common to Siri-like recreations: layered color,
/// blur, blend modes, and continuously shifting sine-wave ribbons. It is
/// decorative only; the actual analyze state remains driven by
/// `CaptureViewModel.State.analyzing`.
///
/// `isPro` swaps the underlying palettes to champagne/gold without
/// touching the motion — same fluid recipe, premium colorway. We don't
/// surface this as a marketing line; it's a quiet daily moment that
/// belongs to Pro users.
private struct AnalyzingImageAura: View {
    var isPro: Bool = false
    /// Food-derived tint for the free path, sampled once per scan by the
    /// photo card and threaded straight into the fluid glow + ribbons.
    /// Empty → the subviews use their default rainbow palette. Ignored on
    /// the Pro path (champagne override) and under Reduce Motion (static
    /// aura draws no blobs).
    var foodPalette: [Color] = []
    /// Pauses the per-frame metaball `TimelineView` when the Home tab isn't
    /// active (e.g. the user switches tabs mid-analyze) — the inactive tab
    /// stays alive in the TabView and would otherwise keep redrawing the
    /// Canvas every frame.
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                // Static aura: a quiet dim + the analyzing badge. No
                // TimelineView, no continuous redraw — the Siri-style
                // motion is purely decorative and the analyzing state
                // is communicated by the badge.
                ZStack {
                    Color.black.opacity(0.22)
                    LinearGradient(
                        colors: [Color.clear, Color.ink.opacity(0.34)],
                        startPoint: .center, endPoint: .bottom
                    )
                    analyzingBadge
                        .padding(AppSpacing.md)
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: .bottomTrailing)
                }
            } else {
                TimelineView(.animation(paused: !isActive)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate

                    ZStack {
                        Color.black.opacity(0.16)

                        // Outer blur is intentionally lighter than the
                        // pre-metaball recipe (was 26): the Canvas now emits
                        // a defined fused silhouette, so a softer halo keeps
                        // the liquid edge legible instead of diffusing the
                        // bubble back into a vague glow.
                        SiriFluidGlow(time: seconds, isPro: isPro,
                                      palette: foodPalette)
                            .blur(radius: 14)
                            .opacity(0.82)
                            .blendMode(.screen)

                        SiriWaveRibbons(time: seconds, isPro: isPro,
                                        palette: foodPalette)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 6, height: 6)
            .scaleEffect(reduceMotion ? 1.0 : (isLifted ? 1.35 : 0.75))
            .opacity(reduceMotion ? 0.85 : (isLifted ? 1 : 0.48))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.62)
                        .repeatForever(autoreverses: true)
                        .delay(delay),
                value: isLifted
            )
            .onAppear {
                guard !reduceMotion else { return }
                isLifted = true
            }
    }
}

private struct SiriFluidGlow: View {
    let time: TimeInterval
    var isPro: Bool = false
    /// Food-derived tint for the bubble. When non-empty (the caller
    /// guarantees ≥ 2 colors before passing it through) its dominant hue
    /// tints the fused silhouette; empty falls back to the classic Siri
    /// cyan. Only the *first* color is read now that the four blobs fuse
    /// into a single metaball — per-blob color is discarded by the alpha
    /// threshold, so multi-hue richness comes from the ribbons drawn over
    /// the bubble instead.
    var palette: [Color] = []

    /// Number of orbiting blobs fused into the bubble. Held at 4 — the
    /// metaball Canvas (blur + alpha-threshold) is the expensive part, so
    /// the blob count stays put for performance regardless of palette size.
    private static let blobCount = 4

    private static let freeColors: [Color] = [
        Color(red: 0.15, green: 0.86, blue: 1.00),
        Color(red: 0.90, green: 0.21, blue: 1.00),
        Color(red: 1.00, green: 0.63, blue: 0.18),
        Color.brandBright,
    ]

    /// Single fill + threshold color for the fused bubble. Pro keeps its
    /// champagne body; otherwise the dominant food hue tints the bubble,
    /// falling back to the classic Siri cyan when no palette was sampled.
    private var bubbleTint: Color {
        if isPro { return ProGold.cream }
        return palette.first ?? Self.freeColors[0]
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // Bubble breathing: a gentle ±4% sin pulse on the blob radius,
            // driven off the same `time` the orbit uses, so the fused shape
            // feels alive while analyzing. This scales the *drawn* blobs,
            // never the blur/threshold parameters — the metaball recipe
            // stays static per frame.
            let breathe = 1 + 0.04 * sin(time * 1.6)

            Canvas { context, size in
                // Gooey metaball fusion. The four orbiting blobs are drawn
                // into one transparency layer, blurred, then alpha-
                // thresholded so their soft fields merge into a single
                // liquid silhouette wherever they overlap — instead of four
                // separate orbs floating apart.
                //
                // Filter order is deliberate: SwiftUI applies the most
                // recently added filter first, so adding the threshold
                // *first* and the blur *last* means the blur runs on the raw
                // blobs (building the gooey field) and the threshold runs on
                // the blurred result (cutting the crisp fused edge). Both
                // filter parameters are constant — only `position(for:)`
                // animates the orbit — so the recipe never re-tunes per
                // frame.
                context.addFilter(.alphaThreshold(min: 0.45, color: bubbleTint))
                context.addFilter(.blur(radius: 18))
                context.drawLayer { layer in
                    for index in 0..<Self.blobCount {
                        let diameter = side * blobScale(index) * breathe
                        let center = position(for: index, in: size)
                        let rect = CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                        layer.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(stops: [
                                    .init(color: bubbleTint.opacity(0.95),
                                          location: 0.0),
                                    .init(color: bubbleTint.opacity(0.90),
                                          location: 0.45),
                                    .init(color: bubbleTint.opacity(0.0),
                                          location: 1.0),
                                ]),
                                center: center,
                                startRadius: 0,
                                endRadius: diameter * 0.5
                            )
                        )
                    }
                }
            }
            // Flatten the metaball into a single Metal-backed layer so the
            // blur + threshold compose once per frame rather than against
            // the parent's blend.
            .drawingGroup()
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
    var isPro: Bool = false
    /// Food-derived tint for the free path. When non-empty it's expanded
    /// into the same 3-ribbon × 3-stop shape the hardcoded
    /// `freeRibbonColors` uses, so the wave geometry below is untouched —
    /// only the colors change. Empty falls back to the default rainbow.
    var palette: [Color] = []

    private static let freeRibbonColors: [[Color]] = [
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

    // Pro palette: each ribbon walks the gold→cream→rose triad with a
    // hint of white on the top ribbon for sparkle. Same three rows so
    // the wave/blur geometry below stays identical.
    private static let proRibbonColors: [[Color]] = [
        [
            ProGold.warm,
            ProGold.cream,
            ProGold.rose,
        ],
        [
            ProGold.cream,
            ProGold.warm,
            ProGold.edgeDark,
        ],
        [
            Color.white.opacity(0.95),
            ProGold.cream,
            ProGold.rose,
        ],
    ]

    private var ribbonColors: [[Color]] {
        if isPro { return Self.proRibbonColors }
        return palette.isEmpty ? Self.freeRibbonColors : Self.ribbons(from: palette)
    }

    /// Expand a flat food palette into 3 ribbons of 3 stops, keeping the
    /// existing 3-ribbon geometry (drawWaves centers its vertical offset
    /// on index 1, so the count must stay 3). Each ribbon walks the
    /// palette from a different offset for variety; a white top-stop on
    /// the first ribbon preserves the sparkle `freeRibbonColors` had.
    private static func ribbons(from palette: [Color]) -> [[Color]] {
        let n = palette.count
        func c(_ i: Int) -> Color { palette[((i % n) + n) % n] }
        return [
            [c(0), c(1), c(2)],
            [c(1), c(2), c(0)],
            [Color.white.opacity(0.9), c(0), c(2)],
        ]
    }

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

/// Transition-only blur for the analyzing aura's "lock-in" collapse — the
/// glow softens slightly as it contracts toward center. Kept as a
/// dedicated modifier so the blur can animate via `.modifier(active:
/// identity:)` inside the asymmetric removal transition.
private struct AuraCollapseBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// Transition-only blur for the result reveal's "focus-pull": the analysis
/// content lands diffuse (blur ~16) and resolves to crisp (blur 0) as the
/// analyzing bubble collapses inward — the analysis "comes into focus."
/// Driven by the same `.appMorph` spring already animating the idle↔result
/// switch; the call site degrades to a plain opacity fade (no blur ramp)
/// under Reduce Motion.
private struct FocusPullBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

// MARK: - Experimental bubble → result-photo morph

/// Gate + constants for the experimental "analyzing bubble physically
/// morphs into the result meal photo" handoff. The morph replaces the
/// capture→result crossfade with a single matched-geometry travel of the
/// photo (position + size + corner radius).
///
/// Two locks, both required to engage (plus Reduce Motion off, checked at
/// the call site): this compile-time `isAvailable` constant, and the
/// `@AppStorage("bubbleMorphEnabled")` runtime toggle (default off). Flip
/// `isAvailable` to false to strip the matched-geometry path entirely
/// without touching persisted user defaults. `internal` (not `private`)
/// so `AnalysisResultView` in its own file can share the same `matchID`.
enum BubbleMorphFeature {
    static let isAvailable = true
    /// Separate, currently-off gate for the matched-geometry photo→result
    /// handoff (capture photo flying into `AnalysisResultView`). Decoupled
    /// from the analyzing-bubble effect because the mandatory `.confirmingName`
    /// step sits between `.analyzing` and `.ready`, so a clean bubble→result
    /// morph isn't possible without state-logic changes. Left in place
    /// (gated off) rather than deleted so it can be revisited.
    static let resultHandoffAvailable = false
    /// Geometry id shared by the capture-side source photo and the
    /// result-side destination photo. Must appear on exactly those two
    /// views and never on two simultaneously-mounted *sources*.
    static let matchID = "mealPhoto"
    /// Near-circular corner radius the result photo starts the morph at,
    /// rounding down to the thumbnail radius as it settles. Large enough
    /// that `RoundedRectangle` clamps it to a circle on the bubble-sized
    /// starting frame.
    static let circularRadius: CGFloat = 200
}

/// Applies the shared meal-photo matched-geometry effect when a namespace
/// is provided; a no-op otherwise, so the flag-off / Reduce-Motion path is
/// structurally identical to today's tree (no matched geometry attached).
struct MealMorphMatch: ViewModifier {
    let namespace: Namespace.ID?
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(
                id: BubbleMorphFeature.matchID,
                in: namespace,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

/// Applies `BubbleMorphMask` only when the morph is engaged for this view;
/// otherwise passes content through untouched, so the flag-off path keeps
/// the photo's plain rounded-rect clip (no mask, no extra redraws).
struct ConditionalBubbleMask: ViewModifier {
    let active: Bool
    let progress: CGFloat
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.modifier(BubbleMorphMask(
                progress: progress,
                cornerRadius: cornerRadius
            ))
        } else {
            content
        }
    }
}

/// Masks a view into a living "jelly" that embodies what the app does while
/// it works: the meal photo melts out of its card into a glossy blob that
/// rhythmically **loosens into lobes and re-fuses** — a visual "we're
/// breaking your meal down" — while it **jiggles** with elastic squash-and-
/// stretch and carries a drifting **wet sheen**. Morphs between a full
/// rounded-rect (progress 0 — the photo card) and the formed jelly
/// (progress 1), un-forming back to the card as analysis ends.
///
/// Three motions, each serving the brief:
///  - Split & merge: the metaball lobes' separation breathes, so the blob
///    gently parts into pieces and rejoins — the decomposition the analyzer
///    is performing, made tactile.
///  - Squash & stretch: anisotropic x/y wobble (out of phase) gives the
///    elastic, edible jiggle that matches the app's bouncy character.
///  - Sheen: a soft white highlight drifts across the surface (overlaid on
///    the photo, masked along with it) so the jelly reads as wet/appetizing.
///
/// Conforms to `Animatable` so `progress` interpolates frame-by-frame; the
/// metaball blur scales with `progress` so progress 0 is a crisp full card
/// (matching the normal photo) and only the formed jelly is gooey.
struct BubbleMorphMask: ViewModifier, Animatable {
    /// 0 = full rounded-rect card; 1 = formed jelly.
    var progress: CGFloat
    /// Card corner radius the silhouette starts from at progress 0.
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        return content
            // Wet sheen — a soft, slowly drifting highlight. It sits over the
            // photo and is clipped by the same jelly mask below, so it only
            // shows on the blob. Fades in with `p`; gone at rest.
            .overlay {
                if p > 0.02 {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        GeometryReader { geo in
                            let w = geo.size.width
                            let h = geo.size.height
                            let r = min(w, h) * 0.42
                            let cx = w * (0.34 + 0.05 * CGFloat(sin(t * 0.7)))
                            let cy = h * (0.28 + 0.04 * CGFloat(cos(t * 0.6)))
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [.white.opacity(0.75 * p),
                                                 .white.opacity(0.18 * p),
                                                 .white.opacity(0.0)],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: r
                                    )
                                )
                                .frame(width: r * 2, height: r * 2)
                                .position(x: cx, y: cy)
                                .blendMode(.screen)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            .mask {
                // Paused when flat so an idle/picked photo card doesn't drive
                // a continuous redraw; runs while the jelly forms or lives.
                TimelineView(.animation(paused: p <= 0.001)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        // Gooey fusion: blur then alpha-threshold (threshold
                        // added first → applied last, since SwiftUI applies
                        // the most recently added filter first). A small base
                        // blur even at progress 0 keeps the rounded-card edge
                        // anti-aliased; it ramps up as the jelly forms.
                        ctx.addFilter(.alphaThreshold(min: 0.5, color: .white))
                        ctx.addFilter(.blur(radius: 0.5 + 17 * p))
                        ctx.drawLayer { layer in
                            let w = size.width
                            let h = size.height
                            let center = CGPoint(x: w / 2, y: h / 2)
                            let side = min(w, h)

                            // Elastic jiggle: width and height wobble out of
                            // phase so the body widens-then-heightens like
                            // settling jelly (subsumes the old uniform breath).
                            let jiggleX = 1 + 0.05 * sin(t * 2.0) * p
                            let jiggleY = 1 + 0.05 * sin(t * 2.0 + .pi) * p

                            // Body: full card → ~58% rounded core as it forms,
                            // corner rounding all the way to a circle. Smaller
                            // core lets the lobes read as distinct pieces.
                            let bodyScale = 1 - 0.42 * p
                            let bw = w * bodyScale * jiggleX
                            let bh = h * bodyScale * jiggleY
                            let circleCorner = min(bw, bh) / 2
                            let corner = cornerRadius
                                + (circleCorner - cornerRadius) * p
                            let bodyRect = CGRect(x: center.x - bw / 2,
                                                  y: center.y - bh / 2,
                                                  width: bw, height: bh)
                            layer.fill(
                                Path(roundedRect: bodyRect, cornerRadius: corner),
                                with: .color(.white.opacity(0.98))
                            )

                            guard p > 0.02 else { return }

                            // Split & merge: separation breathes (~5.7s cycle)
                            // so the lobes gently part — "breaking it down" —
                            // and re-fuse. 0 = merged, 1 = most separated.
                            let split = 0.5 + 0.5 * sin(t * 1.1)
                            let sep = (0.10 + 0.22 * split) * p
                            let scales: [CGFloat] = [0.6, 0.54, 0.48, 0.42]
                            for i in 0..<4 {
                                let phase = t * (0.5 + Double(i) * 0.08)
                                    + Double(i) * 1.7
                                let ox = CGFloat(cos(phase)) * w * sep * jiggleX
                                let oy = CGFloat(sin(phase * 1.13)) * h * sep * jiggleY
                                let bx = center.x + ox
                                let by = center.y + oy
                                let d = side * scales[i] * p
                                    * (jiggleX + jiggleY) / 2
                                guard d > 0.5 else { continue }
                                let r = CGRect(x: bx - d / 2, y: by - d / 2,
                                               width: d, height: d)
                                layer.fill(Path(ellipseIn: r),
                                           with: .color(.white.opacity(0.98)))
                            }
                        }
                    }
                    .drawingGroup()
                }
            }
    }
}

/// The analyzing "dots" badge, extracted so bubble mode can float it over
/// the photo bubble. Mirrors the badge `AnalyzingImageAura` draws.
private struct AnalyzingDotsBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                AnalyzingDot(delay: Double(index) * 0.16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
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

// MARK: - Quantity Clarification sheet modifier

/// Quantity Clarification — extracted ViewModifier so the new sheet
/// presentation doesn't bloat the main CaptureView body's modifier
/// chain past the Swift type-checker's budget. Same behavior as an
/// inline `.sheet`: presents whenever `state == .clarifying(...)`,
/// dismissal routes through `acceptOriginalAnalysis` so the user is
/// never stuck with no usable analysis after closing.
/// Phase 20 calorie-goal scan warning, lifted out of CaptureView's main
/// modifier chain so the type-checker doesn't have to thread three more
/// closures + a presenting-binding through the rest of the body.
private struct CalorieScanWarningModifier: ViewModifier {
    @Binding var kind: CaptureView.ScanWarningKind?
    let onScanAnyway: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            kind.map(CaptureView.scanWarningTitle) ?? "",
            isPresented: Binding(
                get: { kind != nil },
                set: { presented in
                    if !presented { kind = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: kind
        ) { _ in
            Button("Scan anyway") {
                kind = nil
                onScanAnyway()
            }
            Button("View tracker") {
                kind = nil
                NotificationRouter.shared.requestTab(1)
            }
            Button("Cancel", role: .cancel) {
                kind = nil
            }
        } message: { kind in
            Text(CaptureView.scanWarningMessage(kind))
        }
    }
}

/// Phase 15 re-log toast overlay + auto-fade Task, extracted so the
/// trailing `.overlay { … }` + `.animation` modifiers no longer count
/// against CaptureView's main expression complexity budget.
private struct RelogToastModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = viewModel.relogToast {
                    RelogToastView(toast: toast)
                        .padding(.bottom, 96) // clear of the pinned PrimaryButton
                        .padding(.horizontal, AppSpacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            // `try?` would swallow CancellationError but
                            // still run the clear, so a newly-arrived toast
                            // (id flips) would be cleared by the *prior*
                            // task's continuation. Bail explicitly on cancel.
                            do {
                                try await Task.sleep(nanoseconds: 1_600_000_000)
                            } catch {
                                return
                            }
                            withAnimation(.appReveal) {
                                viewModel.clearRelogToast()
                            }
                        }
                }
            }
            .animation(.motionBase, value: viewModel.relogToast?.id)
    }
}

/// Mandatory name confirmation — presents `NameConfirmSheet` whenever
/// the view model is in `.confirmingName` (every successful first-pass
/// analyze lands there). Mirrors `ClarificationSheetModifier`:
/// visibility is entirely state-driven and the binding's `set` is a true
/// no-op. We do NOT route dismissal through `confirmDetectedName` here —
/// doing so would race `correctNameAndContinue` (which flips state to
/// `.analyzing`) the same way the clarification path could race the
/// refine Task. "Looks right" / drag-to-dismiss call `confirmDetectedName`
/// from inside the sheet view itself (via its `onConfirm` + `onDisappear`
/// default).
private struct NameConfirmSheetModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { viewModel.state.isConfirmingName },
            set: { _ in /* no-op — state machine owns dismissal */ }
        )) {
            if case .confirmingName(_, let response) = viewModel.state {
                NameConfirmSheet(
                    detectedName: viewModel.editedFoodName
                        ?? response.analysis.food
                        ?? "this dish",
                    nameAlternatives: response.analysis.nameAlternatives ?? [],
                    onConfirm: {
                        viewModel.confirmDetectedName()
                    },
                    onCorrect: { name in
                        Task { await viewModel.correctNameAndContinue(name) }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct ClarificationSheetModifier: ViewModifier {
    @ObservedObject var viewModel: CaptureViewModel

    func body(content: Content) -> some View {
        // Fix A — the binding's `set` is a TRUE no-op. We do NOT
        // route dismissal through `acceptOriginalAnalysis` here:
        // doing so raced the refine Task and flipped state to
        // `.ready` before the Task body ran, causing the guard in
        // `refineAnalysis` to fail. Instead the sheet visibility is
        // entirely state-driven (presents on `.clarifying`,
        // dismisses on any other state). "Looks about right" /
        // drag-to-dismiss call `acceptOriginalAnalysis` from inside
        // the sheet view itself.
        content.sheet(isPresented: Binding(
            get: { viewModel.state.isClarifying },
            set: { _ in /* no-op — state machine owns dismissal */ }
        )) {
            if case .clarifying(_, _, let items) = viewModel.state {
                QuantityClarificationSheet(
                    items: items,
                    onConfirm: { quantities in
                        Task { await viewModel.refineAnalysis(with: quantities) }
                    },
                    onDismiss: {
                        viewModel.acceptOriginalAnalysis()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
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

// MARK: - Daily quest card (Phase 21.5)

/// One playful prompt per day, rendered on Home above the photo card.
/// Whole card is a Button so a tap anywhere opens the action sheet
/// that routes to Scan or Manual Log. The completion state swaps
/// the title to the reward copy and surfaces a "✨ done" pill, but
/// keeps the card tappable — some users want to continue logging
/// after the quest is satisfied.
private struct DailyQuestCard: View {
    let quest: DailyQuest
    let completed: Bool
    /// Phase 21.10 — non-nil when the user *just* completed the quest
    /// (within the current session). Triggers the live morph
    /// animation. nil means render the resting state for whichever
    /// `completed` value is current (no animation).
    let completionMoment: CaptureViewModel.DailyQuestCompletionMoment?
    let onTap: () -> Void

    // Phase 21.10 — driven by the morph sequence. Start at the
    // values appropriate for "no animation pending":
    //   - `washOpacity = 0`        no overlay tint
    //   - `pillScale` depends on `completed` (set in .onAppear)
    //   - `titleScale = 1`         no pop
    @State private var washOpacity: Double = 0
    @State private var pillScale: CGFloat = 0
    @State private var titleScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedTitle: String {
        completed ? quest.kind.rewardCopy : quest.kind.copy
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                // Persistent quest identity badge. The leaf marks the
                // card as "today's healthy choice" regardless of which
                // prompt the engine picked. On completion it swaps to
                // a checkmark in-place so the slot itself confirms the
                // day's quest is done; the trailing greenSave pill
                // still fires as the celebratory beat.
                ZStack {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 36, height: 36)
                    Image(systemName: completed ? "checkmark" : "leaf.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .id(completed ? "check" : "leaf")
                        .transition(.opacity.combined(with: .scale))
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Eyebrow row — brandDeep ink (not gray) gives
                    // the card its own voice. The check-circle pill
                    // on the right carries the celebratory signal
                    // when completion fires.
                    HStack(alignment: .center) {
                        Text("HEALTHY CHOICE FOR TODAY")
                            .appFont(.captionStrong)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(Color.brandDeep)
                        Spacer()
                        if completed {
                            // Trailing affirmative pill — greenSave
                            // disc with a brandCreamSoft check reads
                            // confidently against the brandSoft card
                            // surface (different green family,
                            // unambiguous).
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .regular))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.brandCreamSoft, Color.greenSave)
                                .scaleEffect(pillScale)
                                .opacity(pillScale)
                        }
                    }

                    Text(displayedTitle)
                        .appFont(.title2)
                        .foregroundStyle(completed ? Color.brandDeep : Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .scaleEffect(titleScale, anchor: .leading)
                        // .id forces SwiftUI to treat the post-morph
                        // text as a *new* view so `.transition(.opacity)`
                        // crossfades instead of snap-replacing.
                        .id(displayedTitle)
                        .transition(.opacity)

                    if completed {
                        Text("Logged · back tomorrow")
                            .appFont(.caption)
                            .foregroundStyle(Color.brandDeep.opacity(0.70))
                            .padding(.top, 2)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 4) {
                            Text("Tap to log this")
                                .appFont(.caption)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.brandDeep)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(questCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
        }
        // Press scale lives in a ButtonStyle so SwiftUI cancels the
        // pressed state the instant an ancestor ScrollView starts
        // panning. A `.simultaneousGesture(DragGesture(min: 0))` here
        // would claim the touch immediately, lose gesture arbitration
        // against the ScrollView, and fire onTap when the user was
        // trying to scroll.
        .buttonStyle(QuestCardButtonStyle())
        .onAppear {
            // Settle the badge into its resting state without
            // animating — re-entering Home with an already-completed
            // quest must show the check in place, not replay
            // yesterday's celebration.
            pillScale = completed ? 1 : 0
        }
        .onChange(of: completionMoment) { _, new in
            guard new != nil else { return }
            runCompletionAnimation()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            completed
            ? "Today's quest complete: \(quest.kind.rewardCopy). Tap to log more."
            : "Today's quest: \(quest.kind.copy). Tap to log it."
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Phase 21.10 morph sequence — runs when `completionMoment`
    /// arrives non-nil. Four beats:
    ///   1. wash overlay fades in + soft haptic
    ///   2. title crossfades to reward copy + pops + success haptic
    ///   3. check-circle badge scales in
    ///   4. wash recedes, card lands in its resting completed state
    ///
    /// Reduce Motion path: skip the choreography, snap the badge in,
    /// fire a single success haptic.
    private func runCompletionAnimation() {
        guard !reduceMotion else {
            withAnimation(.appReduced) { pillScale = 1 }
            Haptics.success()
            return
        }

        // Beat 1 — acknowledgment (0.00–0.25s). Lower opacity than
        // pre-redesign: the wash is now saturated `brand` over a
        // brandSoft base, so 0.30 reads as a confident flash without
        // overwhelming the title underneath.
        withAnimation(.easeOut(duration: 0.25)) {
            washOpacity = 0.30
        }
        Haptics.soft()

        Task { @MainActor in
            // Beat 2 — transformation (0.25–0.55s)
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                titleScale = 1.06
            }
            Haptics.success()
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                titleScale = 1.0
            }

            // Beat 3 — badge settles in (0.55–0.85s)
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.appStamp) {
                pillScale = 1
            }

            // Beat 4 — wash recedes, leaving the card clean
            // (0.85–1.15s). The persistent completion signal is the
            // badge + brand-tinted gradient; the wash is a moment,
            // not a state.
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                washOpacity = 0
            }
        }
    }

    // MARK: - Background composition

    /// Card background. Always `brandSoft` so the quest reads as a
    /// distinct, branded slot vs. the white surface cards stacked
    /// below it on Home. The completion morph layers a more saturated
    /// `brand` wash on top for Beat 1 → Beat 4 of the choreography,
    /// then recedes back to flat brandSoft as the resting completed
    /// state. The web design system fills brand surfaces with single
    /// solid colors (brandCream / brandIvory / brandSoft); the flat
    /// lime block is the moment.
    private var questCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft)

            // Brand wash overlay — appears during Beat 1 of the
            // morph, fades back out at Beat 4. Resting is 0, so
            // the card looks identical whenever no animation runs.
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brand)
                .opacity(washOpacity)
        }
    }
}

/// Press-scale style for the quest card. Mirrors `MealCardButtonStyle`
/// — using a ButtonStyle (rather than a `.simultaneousGesture` on a
/// `.plain` button) lets the parent ScrollView win gesture
/// arbitration: SwiftUI flips `isPressed` back to `false` the instant
/// a pan is detected, so the tap action never fires on a scroll.
private struct QuestCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

// MARK: - Quest celebration modal (Phase 21.11)

/// Center-screen celebration that fires when the user completes
/// today's daily quest. The modal makes the moment unmissable; the
/// underlying Phase 21.10 in-place card morph handles the persistent
/// state. Two complementary layers.
///
/// Design intent:
///   - Brief: enters fast, auto-dismisses ~2.5s after entry
///   - Center-emotionally: hero is the reward emoji, not the brand
///   - Respects context: backdrop dims to ~40%, user still sees Home
///   - Tap-to-dismiss for impatient users
///
/// Reduce Motion is honored — bouncy entry becomes a calm fade,
/// the success haptic stays so the completion still registers.
struct QuestCelebrationModal: View {
    let moment: CaptureViewModel.DailyQuestCompletionMoment
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var backdropOpacity: Double = 0
    @State private var cardScale: CGFloat = 0.6
    @State private var cardOpacity: Double = 0
    @State private var heroScale: CGFloat = 0.4
    @State private var heroRotation: Double = -15
    @State private var sparkleOpacity: Double = 0
    @State private var sparkleScale: CGFloat = 0.5
    @State private var rewardOpacity: Double = 0
    @State private var rewardOffset: CGFloat = 8
    @State private var didDismiss: Bool = false

    var body: some View {
        ZStack {
            // Backdrop dim — clear-color is no good for hit-testing
            // taps reliably; black at low opacity gives a real tap
            // target so tapping anywhere outside the card dismisses.
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            // Celebration card
            VStack(spacing: AppSpacing.lg) {
                // Hero: large emoji from the reward copy, with
                // sparkle accents fanning out behind it on beat 3.
                ZStack {
                    sparkleLayer
                        .opacity(sparkleOpacity)
                        .scaleEffect(sparkleScale)

                    Text(heroEmoji)
                        .font(.system(size: 76))
                        .scaleEffect(heroScale)
                        .rotationEffect(.degrees(heroRotation))
                        .accessibilityHidden(true)
                }
                .frame(width: 140, height: 140)

                VStack(spacing: AppSpacing.xs) {
                    Text("QUEST COMPLETE").eyebrow()
                        .foregroundStyle(Color.brandDeep)

                    Text(rewardHeadline)
                        .appFont(.display2)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(rewardOpacity)
                        .offset(y: rewardOffset)
                }
                .padding(.horizontal, AppSpacing.md)
            }
            .padding(.vertical, AppSpacing.xl)
            .padding(.horizontal, AppSpacing.lg)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(Color.bgSurface)
            )
            .overlay(
                // Subtle brand-tinted top edge — premium detail that
                // gives the card a small lift without color-flooding.
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.brand.opacity(0.35),
                                Color.brandSoft.opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .appShadow(.shadowElevated)
            .scaleEffect(cardScale)
            .opacity(cardOpacity)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl))
            .onTapGesture { dismiss() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quest complete. \(rewardHeadline). Tap to dismiss.")
            .accessibilityAddTraits(.isButton)
        }
        .onAppear { play() }
    }

    // MARK: - Reward-copy parsing
    //
    // Phase 21 reward copies all start with an emoji (e.g.
    // "🍎 Fruit logged — small win"). We render the emoji at hero
    // size separately, and the rest as the headline. The `> 0x238C`
    // floor skips ASCII digits that `isEmoji` reports as true when
    // followed by the keycap sequence — none of our reward copies
    // use those, so the filter is purely defensive.

    private var heroEmoji: String {
        guard let first = moment.rewardCopy.first,
              first.unicodeScalars.contains(where: { scalar in
                  scalar.properties.isEmoji && scalar.value > 0x238C
              }) else {
            return "✨"
        }
        return String(first)
    }

    private var rewardHeadline: String {
        var copy = moment.rewardCopy
        if let first = copy.first,
           first.unicodeScalars.contains(where: { scalar in
               scalar.properties.isEmoji && scalar.value > 0x238C
           }) {
            copy.removeFirst()
        }
        return copy.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sparkle accents
    //
    // Six SF Symbol sparkles arranged on a circle around the hero.
    // Alternating sizes give visual rhythm; brand color keeps them
    // on-palette. They fade and scale in together at beat 3 so the
    // user reads them as "a celebration moment" rather than six
    // separate elements.
    @ViewBuilder
    private var sparkleLayer: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: i.isMultiple(of: 2) ? 14 : 10,
                                  weight: .heavy))
                    .foregroundStyle(Color.brand)
                    .offset(
                        x: cos(Double(i) * .pi / 3) * 62,
                        y: sin(Double(i) * .pi / 3) * 62
                    )
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Animation

    private func play() {
        if reduceMotion {
            // Calm fade-in. No spring, no rotation, no staggered
            // beats. Sparkles still appear (they're structural to
            // the layout) but without independent motion.
            withAnimation(.appReduced) {
                backdropOpacity = 0.4
                cardScale = 1
                cardOpacity = 1
                heroScale = 1
                heroRotation = 0
                rewardOpacity = 1
                rewardOffset = 0
                sparkleOpacity = 1
                sparkleScale = 1
            }
            Haptics.success()
            scheduleAutoDismiss()
            return
        }

        // Beat 1 (0.00–0.20s) — backdrop dims, card enters with spring
        withAnimation(.easeOut(duration: 0.20)) {
            backdropOpacity = 0.4
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
            cardScale = 1
            cardOpacity = 1
        }
        Haptics.soft()

        Task { @MainActor in
            // Beat 2 (0.20–0.45s) — hero springs in, rotation corrects
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) {
                heroScale = 1.1
                heroRotation = 0
            }

            // Beat 3 (0.45–0.70s) — hero settles, sparkles fan,
            // success haptic lands with the visual peak.
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                heroScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.4)) {
                sparkleOpacity = 1
                sparkleScale = 1
            }
            Haptics.success()

            // Beat 4 (0.70–1.05s) — reward copy rises into place
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                rewardOpacity = 1
                rewardOffset = 0
            }

            scheduleAutoDismiss()
        }
    }

    private func scheduleAutoDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !didDismiss { dismiss() }
        }
    }

    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        withAnimation(.easeIn(duration: 0.22)) {
            backdropOpacity = 0
            cardScale = 0.94
            cardOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            onDismiss()
        }
    }
}

// MARK: - Manual log toast (Phase 21)

/// Lightweight banner shown after a successful manual save. Carries
/// two slots:
///   1. an optional quest-complete reward line (only when the save
///      just completed today's quest), and
///   2. a free-tier nudge ("Try a photo scan?" or "Upgrade for 5
///      photo scans/day", depending on `scansRemaining`).
///
/// The host owns dismissal so the action buttons can route tab
/// switches / scan starts cleanly — this modifier is just the
/// presentation envelope.
private struct ManualLogToastModifier: ViewModifier {
    @Binding var toast: CaptureView.ManualLogToast?
    let onScanAction: () -> Void
    let onTrackerAction: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ManualLogToastView(
                        toast: toast,
                        onScanAction: onScanAction,
                        onTrackerAction: onTrackerAction
                    )
                    .padding(.bottom, 96)
                    .padding(.horizontal, AppSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        do {
                            try await Task.sleep(nanoseconds: 4_000_000_000)
                        } catch {
                            return
                        }
                        withAnimation(.appReveal) {
                            self.toast = nil
                        }
                    }
                }
            }
            .animation(.motionBase, value: toast?.id)
    }
}

private struct ManualLogToastView: View {
    let toast: CaptureView.ManualLogToast
    let onScanAction: () -> Void
    let onTrackerAction: () -> Void

    /// Scan-nudge line under the manual-log toast. Pro reads as
    /// unlimited (no remaining-count number, ever); free users see the
    /// count and, when out, an "unlimited" upsell — never a cap number.
    private var scanNudgeCopy: String {
        if toast.isUnlimited {
            return "Try a photo scan?"
        }
        if toast.scansRemaining > 0 {
            return "Try a photo scan? \(toast.scansRemaining) left today"
        }
        return "Upgrade for unlimited photo scans"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Manual log saved")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.ink)
                    Text(toast.foodName)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    onTrackerAction()
                } label: {
                    Text("View today")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                }
                .buttonStyle(.plain)
            }

            if let reward = toast.questRewardCopy {
                Text(reward)
                    .appFont(.caption)
                    .foregroundStyle(Color.brandDeep)
            }

            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.inkMute)
                Button {
                    Haptics.tap()
                    onScanAction()
                } label: {
                    Text(scanNudgeCopy)
                        .appFont(.caption)
                        .foregroundStyle(Color.brandDeep)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.brandDeep)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }
}

// MARK: - Scan counter chip

/// The cutesy/premium pill that lives in the top bar showing scans
/// left today. Lives in its own struct so the animation state — pulse,
/// halo breathe, one-shot wiggle on the "ran out" moment — survives
/// CaptureView re-renders without re-starting on every tick.
///
/// Three visual states keyed off `remaining` and `isPro`:
///   • Plenty (remaining > 1 free, or pro any-N): brand-soft pill, a
///     mini camera (free) or a depleting progress ring (pro), and a
///     count that contentTransitions between values.
///   • Low (remaining == 1, free only): pill stays brand-soft but the
///     count shifts to a warm honey tone — a soft cue without nagging.
///   • Out (remaining == 0): pill morphs to a warm peach with an
///     orangeBadge halo gently breathing behind it. Icon swaps to a
///     crown via SF Symbols' `.replace` effect, the label fades in
///     "Out · Go Pro" (free) or "Maxed today" (pro), and the badge
///     does a one-shot wiggle the first frame it enters this state so
///     the user actually notices they ran out. Tappable → paywall.
///
/// `accessibilityReduceMotion` kills the wiggle and the halo breathe;
/// state-transition crossfades stay since they're geometry-stable.
private struct ScanCounterChip: View {
    let remaining: Int
    let limit: Int
    let isPro: Bool
    /// When true (Pro), the chip drops the counter entirely and just
    /// reads "Unlimited" — no number, no depletion ring, and it never
    /// enters the out/warning state (the silent safety cap is invisible).
    var isUnlimited: Bool = false
    /// Fires on every tap regardless of state. The parent decides
    /// what to present — historically out-state went straight to
    /// the paywall, but the chip now always opens the explainer
    /// sheet so users can learn the scan budget before being
    /// upsold.
    let onTap: () -> Void
    /// Whether the Home tab is the active tab. The heartbeat loop only runs
    /// when true, so the chip stops animating on inactive tabs (TabView keeps
    /// the view alive otherwise).
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haloBreathe = false
    @State private var wiggle: Double = 0
    /// Heartbeat scale — driven by `runHeartbeatLoop` while scans
    /// remain so users actually notice the chip exists. Skipped when
    /// out of scans (the warning halo + wiggle already own the
    /// attention budget there) and under Reduce Motion.
    @State private var heartbeatScale: CGFloat = 1.0

    // Unlimited Pro never reads as "out" — the silent safety cap stays
    // invisible, so even if `remaining` hits 0 the chip keeps saying
    // "Unlimited" rather than flipping to the warning state.
    private var isOut: Bool { !isUnlimited && remaining == 0 }
    private var isLow: Bool { !isPro && remaining == 1 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                iconView
                labelView
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fillBackground)
            .overlay(rimStroke)
            .background(outerHalo)
            .rotationEffect(.degrees(wiggle))
            // Heartbeat scale sits outside the rotation so the lub-dub
            // doesn't stretch the wiggle into a jelly wobble. Layout
            // size is unaffected — scaleEffect is purely visual.
            .scaleEffect(heartbeatScale)
            // The geometry-stable animation: state→state recolor and
            // crossfade of the inner content. Spring keeps it bouncy
            // without overshoot.
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isOut)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isLow)
            .animation(.snappy, value: remaining)
        }
        .buttonStyle(.plain)
        .onAppear(perform: startBreathing)
        // .task auto-cancels on view disappear, so the heartbeat loop
        // exits cleanly when the user navigates away — no leaked
        // timers, no zombie animations against a defunct chip. Keyed on
        // `isActive` so it also stops on inactive tabs (where the chip stays
        // alive in the TabView) and restarts when Home is reselected.
        .task(id: isActive) {
            guard isActive else { return }
            await runHeartbeatLoop()
        }
        .onChange(of: isOut) { _, nowOut in
            if nowOut { runOutWiggle() }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isOut ? "Opens the Pro upgrade screen" : "")
    }

    // MARK: - Inner pieces

    // Icon morphs between three glyphs via SF Symbols' replace effect
    // (iOS 17+): camera → progress ring (pro) → crown (out). Bounce on
    // out so the swap reads as a tiny celebration of "go pro" rather
    // than a dead-end.
    @ViewBuilder
    private var iconView: some View {
        if isUnlimited {
            // Crown, not a depletion ring — a ring would encode a
            // proportion of the hidden cap. The crown reads as "Pro".
            Image(systemName: "crown.fill")
                .font(.system(size: 11, weight: .heavy))
                .transition(.scale.combined(with: .opacity))
        } else if isPro && !isOut {
            ProgressRingMini(
                progress: Double(limit - remaining) / Double(max(limit, 1))
            )
            .frame(width: 14, height: 14)
            .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: isOut ? "crown.fill" : "camera.fill")
                .font(.system(size: 11, weight: .heavy))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: isOut)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // Label is two states behind one Group so the whole chunk
    // crossfades cleanly when the chip flips to out. Inside each
    // state the number uses .contentTransition(.numericText) so the
    // digit rolls when a scan is consumed.
    @ViewBuilder
    private var labelView: some View {
        Group {
            if isUnlimited {
                Text("Unlimited")
                    .appFont(.captionStrong)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if isOut {
                Text(isPro ? "Maxed today" : "Out · Go Pro")
                    .appFont(.captionStrong)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if isPro {
                HStack(spacing: 3) {
                    Text("\(remaining)")
                        .appFont(.captionStrong)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("/ \(limit) today")
                        .appFont(.captionStrong)
                        .lineLimit(1)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 3) {
                    Text("\(remaining)")
                        .appFont(.captionStrong)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(remaining == 1 ? "left!" : "left today")
                        .appFont(.captionStrong)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Style tokens

    private var foreground: Color {
        if isOut { return .orangeCancel }
        if isLow { return .orangeBadge }
        return .brandDeep
    }

    private var fillBackground: some View {
        Capsule().fill(
            isOut
                ? Color.catDrawbacks                // soft peach
                : (isLow ? Color.brandCream : Color.brandSoft)
        )
    }

    private var rimStroke: some View {
        Capsule().strokeBorder(
            isOut
                ? Color.orangeCancel.opacity(0.35)
                : (isLow
                    ? Color.orangeBadge.opacity(0.40)
                    : Color.brand.opacity(0.25)),
            lineWidth: 1
        )
    }

    // Soft warm halo that only appears in the out state. Slowly
    // breathes scale + opacity so the chip feels alive — the same
    // trick the pro badge uses, tuned warmer so it reads as
    // "attention, friendly" instead of "alarm".
    @ViewBuilder
    private var outerHalo: some View {
        if isOut {
            Capsule()
                .fill(Color.orangeBadge.opacity(0.45))
                .blur(radius: 9)
                .scaleEffect(haloBreathe ? 1.22 : 1.05)
                .opacity(haloBreathe ? 0.95 : 0.55)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Animations

    private func startBreathing() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloBreathe = true
        }
    }

    /// Lub-dub-rest heartbeat that draws the eye to the chip without
    /// being constant. Three-phase scale: quick lub (1.22), quick dub
    /// (0.94 — undershoot reads as the recoil after a heartbeat),
    /// then a settle back to 1.0 followed by a long rest.
    ///
    /// Runs in every state — including out — so the chip stays
    /// noticeable when the user has nothing left and needs to tap to
    /// upgrade. The out-state halo breathes behind the chip; the
    /// heartbeat scales the chip itself; the two layers reinforce
    /// "tap me" rather than compete.
    ///
    /// Killed only under Reduce Motion. `.task` cancels the loop when
    /// the chip leaves the view tree.
    private func runHeartbeatLoop() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            // Lub — fast contraction outward.
            await MainActor.run {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                    heartbeatScale = 1.22
                }
            }
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Dub — quick rebound below 1.0 so it reads as a real
            // double-beat instead of a single pop.
            await MainActor.run {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                    heartbeatScale = 0.94
                }
            }
            try? await Task.sleep(nanoseconds: 160_000_000)

            // Settle back to rest.
            await MainActor.run {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                    heartbeatScale = 1.0
                }
            }

            // Long pause between beats — keeps the motion noticeable
            // when it lands rather than blending into ambient noise.
            try? await Task.sleep(nanoseconds: 1_900_000_000)
        }
    }

    // One-shot wobble: -7° → 7° → -3° → 0. Fires only the moment the
    // chip flips into the out state so the user notices; subsequent
    // re-renders of the out chip don't wiggle again.
    private func runOutWiggle() {
        guard !reduceMotion else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
            wiggle = -7
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
                wiggle = 7
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) {
                wiggle = -3
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                wiggle = 0
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        if isUnlimited { return "Unlimited photo scans with Pro" }
        if isOut {
            return isPro
                ? "You've reached today's scan limit"
                : "Out of scans today. Tap to upgrade to Pro."
        }
        if isPro { return "\(remaining) of \(limit) scans today" }
        return remaining == 1
            ? "1 free scan left today"
            : "\(remaining) free scans left today"
    }
}

/// Minimal depletion ring used inside the Pro-state chip. Trims from
/// a full circle as scans are consumed (progress 0 → full ring,
/// progress 1 → just the track). A tiny embedded camera sells what
/// the ring is counting without needing a separate label.
private struct ProgressRingMini: View {
    let progress: Double  // 0.0 (full) → 1.0 (depleted)

    var body: some View {
        let p = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.brand.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(1.0 - p, 0.01))
                .stroke(
                    Color.brandDeep,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: p)
            Image(systemName: "camera.fill")
                .font(.system(size: 6, weight: .heavy))
                .foregroundStyle(Color.brandDeep)
        }
    }
}

// MARK: - Scan limits explainer

/// Modal that explains the scan budget in one screen so users
/// understand "why N today" without leaving Home. Surfaces:
///   • Today's usage (X of Y, with the remaining count up top so
///     the user's actual state is the first thing they read).
///   • Free policy spelled out — 4/day for the first week, then 2/day
///     forever. Bonus framing rather than "your cap will drop".
///   • Pro policy — unlimited photo scans, every day, cancel anytime.
///   • Action row: free users get a gold "Try Pro" pill that opens
///     the existing `PaywallView`; pro users get a quiet "You're on
///     Pro" confirmation + Close.
///
/// Entrance choreography (the "alive" feel): inner content stays
/// invisible until the sheet finishes its native slide-up, then
/// each block reveals in turn with a small offset + spring. Total
/// reveal ~0.55s; total perceived presentation ~1s including the
/// sheet itself.
///
/// Lives inline in CaptureView.swift to avoid manual pbxproj file
/// adds (project doesn't use synchronized folders).
private struct ScanLimitsExplainerSheet: View {
    let used: Int
    let limit: Int
    let isPro: Bool
    /// Pro is presented as unlimited — the today strip and the Pro card
    /// render "Unlimited" with no number when this is set.
    var isUnlimited: Bool = false
    let onTryPro: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Master reveal flag. Flipped via `.task` after a short delay so
    /// inner content lands *after* the system sheet slide; staggered
    /// per-block delays do the rest.
    @State private var revealed = false

    private var remaining: Int { max(0, limit - used) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    heroBlock                      // delay 0.00
                        .reveal(revealed, delay: 0.00)
                    todayCard                      // delay 0.08
                        .reveal(revealed, delay: 0.08)
                    freeCard                       // delay 0.16
                        .reveal(revealed, delay: 0.16)
                    proCard                        // delay 0.24
                        .reveal(revealed, delay: 0.24)
                    Spacer(minLength: AppSpacing.md)
                    actionRow                      // delay 0.34
                        .reveal(revealed, delay: 0.34)
                    footerNote
                        .reveal(revealed, delay: 0.40)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.xl)
            }

            // Close X. Sits above the drag indicator so the chrome
            // doesn't fight the eye for the same corner.
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.bgSurface))
                    .appShadow(.shadowCard)
            }
            .padding(AppSpacing.md)
            .accessibilityLabel("Close")
        }
        .background(Color.bgCanvas)
        .task {
            // Wait a beat so the inner reveal doesn't race the
            // sheet's slide-up. ~0.18s lands the first item just as
            // the sheet settles, which reads as a continuous motion
            // chain rather than two separate animations.
            if reduceMotion {
                revealed = true
            } else {
                try? await Task.sleep(nanoseconds: 180_000_000)
                revealed = true
            }
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // Stacked camera + sparkle glyph — reads as "scan magic"
            // without needing illustration. Gold tint nods to Pro
            // even on free, since both tiers are explained inside.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                ProGold.cream.opacity(0.7),
                                ProGold.rose.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.brandDeep)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("Your scan budget")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Simple, no surprises.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Today

    /// Today's usage strip. Keeps the user's actual state visible
    /// throughout the explanation so the abstract policy below maps
    /// to something concrete ("I have N left right now").
    private var todayCard: some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TODAY")
                    .appFont(.labelEyebrow)
                    .foregroundStyle(Color.inkMute)
                Text(todayLine)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
            }
            Spacer()
            // Mini pip strip — one circle per scan in today's limit,
            // filled = used, empty = remaining. Capped at 10 so pro
            // doesn't get an unreadable row. Hidden for unlimited Pro:
            // a finite pip count would imply a cap.
            if !isUnlimited {
                HStack(spacing: 4) {
                    ForEach(0..<min(limit, 10), id: \.self) { i in
                        Circle()
                            .fill(i < used ? Color.brandDeep : Color.brand.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.brandDeep)
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft.opacity(0.65))
        )
    }

    private var todayLine: String {
        if isUnlimited { return "Unlimited scans" }
        if remaining == 0 { return "Out for today" }
        if remaining == 1 { return "1 scan left" }
        return "\(remaining) scans left"
    }

    // MARK: - Free card

    private var freeCard: some View {
        tierCard(
            label: "FREE",
            labelColor: Color.inkMute,
            accent: Color.brand,
            border: Color.borderHairline,
            bigNumber: "4 → 2",
            bigSuffix: "per day",
            lines: [
                "First week: 4 scans/day to help you get the hang of it.",
                "After: 2 scans/day, every day.",
            ],
            crown: false
        )
    }

    // MARK: - Pro card

    private var proCard: some View {
        tierCard(
            label: "PRO",
            labelColor: ProGold.deep,
            accent: ProGold.warm,
            border: ProGold.warm.opacity(0.45),
            bigNumber: "∞",
            bigSuffix: "per day",
            lines: [
                "Unlimited photo scans, every single day.",
                "Cancel anytime in Settings.",
            ],
            crown: true
        )
    }

    /// Shared card shape so the two tiers read as a pair. The Pro
    /// variant gets a warm gold border + crown badge to feel earned
    /// rather than just "the other option".
    private func tierCard(
        label: String,
        labelColor: Color,
        accent: Color,
        border: Color,
        bigNumber: String,
        bigSuffix: String,
        lines: [String],
        crown: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if crown {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    Text(label)
                        .appFont(.labelEyebrow)
                }
                .foregroundStyle(labelColor)

                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(bigNumber)
                    .font(.custom(AppFont.PS.mplusBlack, size: 30))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(bigSuffix)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(border, lineWidth: crown ? 1.5 : 1)
        )
        // Pro card gets a soft gold shadow so it visually lifts off
        // the page — the cue is geometric, not just colored.
        .shadow(
            color: crown ? ProGold.warm.opacity(0.25) : .black.opacity(0.04),
            radius: crown ? 12 : 4,
            x: 0,
            y: crown ? 6 : 2
        )
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        if isPro {
            // Already paying. Don't ask again — just confirm the
            // status and let them dismiss.
            VStack(spacing: AppSpacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .heavy))
                    Text("You're on Pro")
                        .appFont(.title2)
                }
                .foregroundStyle(ProGold.deep)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(
                    Capsule().fill(ProGold.cream.opacity(0.45))
                )
                .overlay(
                    Capsule().strokeBorder(ProGold.warm.opacity(0.45), lineWidth: 1)
                )

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(spacing: AppSpacing.sm) {
                Button {
                    Haptics.tap()
                    onTryPro()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 16, weight: .heavy))
                        Text("Try Pro")
                            .appFont(.title2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [ProGold.warm, ProGold.edgeDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(ProGold.cream.opacity(0.6), lineWidth: 0.8)
                    )
                    .shadow(color: ProGold.warm.opacity(0.45), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Maybe later")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerNote: some View {
        Text("Manual logging is unlimited on both tiers.")
            .appFont(.caption)
            .foregroundStyle(Color.inkLight)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Reveal modifier for the explainer sheet — opacity + small upward
/// offset + tiny scale, driven by a single boolean flipped after the
/// sheet's slide-up so the inner content reads as continuous motion.
private struct RevealModifier: ViewModifier {
    let revealed: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1.0 : 0.96)
            .offset(y: revealed ? 0 : 14)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.78).delay(delay),
                value: revealed
            )
    }
}

private extension View {
    func reveal(_ revealed: Bool, delay: Double) -> some View {
        modifier(RevealModifier(revealed: revealed, delay: delay))
    }
}

#if DEBUG
#Preview("CaptureView — idle") {
    CaptureView()
}

#Preview("Scan counter — states") {
    VStack(spacing: 16) {
        ScanCounterChip(remaining: 3, limit: 4, isPro: false, onTap: {})
        ScanCounterChip(remaining: 1, limit: 4, isPro: false, onTap: {})
        ScanCounterChip(remaining: 0, limit: 4, isPro: false, onTap: {})
        ScanCounterChip(remaining: 100, limit: 100, isPro: true, isUnlimited: true, onTap: {})
    }
    .padding(40)
    .background(Color.bgCanvas)
}

#Preview("Scan limits explainer — free") {
    ScanLimitsExplainerSheet(
        used: 1, limit: 4, isPro: false, onTryPro: {}
    )
}

#Preview("Scan limits explainer — pro") {
    ScanLimitsExplainerSheet(
        used: 7, limit: 100, isPro: true, isUnlimited: true, onTryPro: {}
    )
}
#endif
