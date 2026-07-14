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
    /// Phase 23 — Vault browser presentation flag. Distinct from the
    /// recent/favorites pickers: the Vault is the durable saved-foods
    /// library, sourced from `vault_items` rather than recent logs.
    @State private var showingVault = false
    /// Set when the user taps "Add → Scan a new meal" in the Vault; the
    /// scan is kicked off in the sheet's `onDismiss` (can't present the
    /// picker while the vault sheet is still dismissing).
    @State private var pendingScanAfterVault = false
    /// Vault size the user has already seen. When the live count exceeds it,
    /// the top-bar Vault pill surfaces an "unseen" badge + glow to draw the
    /// eye; opening the vault marks the current count as seen.
    @AppStorage("vault.lastSeenCount") private var lastSeenVaultCount = 0
    /// Observed so the favorite-shortcut affordance hides itself the
    /// moment the user un-hearts every meal — no stale "Quick log
    /// favorite" link sitting on Home with no targets.
    @StateObject private var favoritesStore = FavoritesStore.shared
    /// Phase 23 — observed so the "Vault" quick-log chip appears/hides
    /// with vault contents and the result-screen button reflects live
    /// membership.
    @StateObject private var vaultStore = VaultStore.shared
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
            enabled: orbJourneyActive
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
        // Phase 23 — Vault browser. Re-logs a durable saved food into
        // today via the same insert engine as Quick Re-log.
        .onChange(of: showingVault) { _, showing in
            // Opening (or closing) the vault marks the current count as seen,
            // so the pill's "unseen" badge + glow rest.
            if showing { lastSeenVaultCount = vaultStore.totalCount }
        }
        .sheet(isPresented: $showingVault, onDismiss: {
            // Re-mark seen on close so anything added while browsing (e.g.
            // pick-from-logs) doesn't re-trigger the badge.
            lastSeenVaultCount = vaultStore.totalCount
            // If the user chose "Scan a new meal", start the scan now that
            // the sheet is gone.
            if pendingScanAfterVault {
                pendingScanAfterVault = false
                requestScan()
            }
        }) {
            VaultSheet(
                onPicked: { picked in
                    Task { await viewModel.relogFromVault(picked) }
                },
                onScanNew: { pendingScanAfterVault = true }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Phase 16 — one-time coach picker after the first save. Fires
        // on the .saved transition; the gate is the local UserDefaults
        // flag inside `CoachPickerOnboardingSheet`. We don't fire on
        // re-logs (which also flip into `.saved` cousins) because
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
                ? "Quest done, want to log more?"
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

    /// Kick off the save-to-vault celebration (app-level, so the same flight
    /// + modal fire from the Tracker too) and perform the save. Idempotent —
    /// the save no-ops if already vaulted; the celebration debounces itself.
    private func beginVaultSave(image: UIImage?, name: String) {
        VaultCelebration.shared.celebrate(image: image, foodName: name, from: nil)
        Task { await viewModel.saveCurrentToVault() }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Text("foodie.")
                .appFont(.title1)
                .foregroundStyle(Color.ink)

            // Phase 23 — permanent Vault entry, next to the wordmark.
            // A pantry-cabinet tile: the Vault is the shelf of go-to
            // meals you keep on hand. Always visible so the library is
            // discoverable even when empty (the sheet's empty state
            // explains how to fill it; its setup state flags a missing
            // migration).
            VaultNavButton(
                count: vaultStore.totalCount,
                hasUnseen: vaultStore.totalCount > lastSeenVaultCount
            ) {
                showingVault = true
            }
            .vaultPillTarget()

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
            Text("Snap a meal, we'll break it down.")
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
                // Vault has a permanent entry in the top bar (see topBar),
                // so it isn't duplicated here among the re-log chips.
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
        .accessibilityLabel("\(title), re-log a meal without a photo")
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
                    onCancel: { handleCancelTapped() },
                    // Phase 23 — Save to Vault sits alongside "Save to
                    // today." Independent of logging; membership is read
                    // live off VaultStore so the button flips to "Saved
                    // to Vault" the moment it lands.
                    onSaveToVault: vaultStore.isUnavailable
                        ? nil
                        : {
                            beginVaultSave(
                                image: payload.image,
                                name: viewModel.editedFoodName
                                    ?? payload.response.analysis.food ?? "Meal"
                            )
                        },
                    isInVault: vaultStore.isInVault(
                        foodName: viewModel.editedFoodName
                            ?? payload.response.analysis.food ?? ""
                    )
                )
                if let err = saveFailedError {
                    Text(CaptureViewModel.friendlySaveMessage(for: err))
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
    static func scanWarningTitle(_ kind: ScanWarningKind) -> String {
        switch kind {
        case .reached:     return "You've reached today's goal."
        case .approaching: return "You're close to today's goal."
        }
    }

    static func scanWarningMessage(_ kind: ScanWarningKind) -> String {
        switch kind {
        case .reached:
            return "Log gently from here, this one will tip you over."
        case .approaching:
            return "Still room for this one, just a friendly heads up."
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
                message: "Nice, your first day is started.",
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





/// Phase 23 — the Vault entry in the Home top bar.
///
/// A labeled pill (two-tone archive-box glyph + "Vault") in the brand's
/// chip family — same Capsule + hairline as `quickLogChip` / the scan
/// chip — so it reads as its own control sitting beside the wordmark, not
/// as part of it. Lifted a touch above the flat chips (warm gradient fill,
/// catch-light top edge, small floating shadow) since it's the permanent
/// doorway into the saved-foods library.
///
/// Delight: `MorphingPressStyle` gives the press a felt scale + soft
/// haptic, and the box plays a discrete `.bounce` whenever `count`
/// changes, so returning to Home after saving a food lands a small "it
/// dropped into the vault" reward. Reduce Motion drops the bounce; the
/// press style already self-adjusts.
private struct VaultNavButton: View {
    /// Current vault size. A change drives the "a food just landed" bounce.
    let count: Int
    /// True when foods were added since the vault was last opened. Surfaces
    /// the count badge in a solid brand fill and a gentle breathing glow so
    /// the pill quietly invites a look — then rests the moment it's opened.
    let hasUnseen: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath: CGFloat = 0

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                glyph
                Text("Vault")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)
                if count > 0 { countBadge }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [Color.brandCream, Color.brandSoft],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    Color.brand.opacity(hasUnseen ? 0.6 : 0.32),
                    lineWidth: hasUnseen ? 1.4 : 1
                )
            )
            // Catch-light along the top edge so the pill reads as a lit
            // surface, a hair richer than the flat sibling chips.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.6), Color.clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
            )
            .appShadow(.shadowFloating)
            // Attention glow — brand-tinted, softly breathing, ONLY while
            // there are unseen foods. Quiet, purposeful, self-resolving.
            .shadow(color: Color.brand.opacity(glowOpacity), radius: glowRadius)
            .scaleEffect(1 + breathScale)
            .contentShape(shape)
        }
        .buttonStyle(MorphingPressStyle(scale: 0.94))
        .onAppear(perform: startBreath)
        .onChange(of: hasUnseen) { _, _ in startBreath() }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens your saved foods")
    }

    /// Number of saved foods. A quiet outlined chip normally; a solid brand
    /// chip (like an unread badge) when there's something new to see.
    private var countBadge: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(hasUnseen ? Color.brandCream : Color.brandDeep)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                Capsule().fill(hasUnseen ? Color.brand : Color.brand.opacity(0.16))
            )
            .overlay {
                if !hasUnseen {
                    Capsule().strokeBorder(Color.brand.opacity(0.35), lineWidth: 0.8)
                }
            }
    }

    private var glowOpacity: Double {
        hasUnseen ? 0.3 + Double(breath) * 0.3 : 0
    }
    private var glowRadius: CGFloat {
        hasUnseen ? 7 + breath * 5 : 0
    }
    private var breathScale: CGFloat {
        (hasUnseen && !reduceMotion) ? breath * 0.02 : 0
    }

    private func startBreath() {
        guard hasUnseen, !reduceMotion else { return }
        breath = 0
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            breath = 1
        }
    }

    private var accessibilityText: String {
        if count == 0 { return "Vault" }
        return hasUnseen
            ? "Vault, \(count) saved foods, new items"
            : "Vault, \(count) saved foods"
    }

    @ViewBuilder
    private var glyph: some View {
        // Two-tone: dark-olive box body + brand-lime lid, so the box has
        // depth against the pale pill and the lid pops.
        let base = Image(systemName: "archivebox.fill")
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.brandDeep, Color.brand)
        if reduceMotion {
            base
        } else {
            base.symbolEffect(.bounce, value: count)
        }
    }
}

// MARK: - Phase 23: Save-to-Vault celebration

/// App-level coordinator for the "Saved to Vault" celebration. Any surface
/// (the analyze result screen, a Tracker meal card) calls `celebrate(...)`;
/// a single overlay hosted at the tab-view root via `.vaultCelebrationHost()`
/// renders the flying chip + confirmation modal above whatever tab is
/// showing, so the animation works everywhere. Visual only — the caller
/// still performs the actual save into `VaultStore`.
@MainActor
final class VaultCelebration: ObservableObject {
    static let shared = VaultCelebration()

    @Published fileprivate var flight: Flight?
    @Published fileprivate var savedName: String?

    /// The vault pill's global frame — the flight target. Published by the
    /// pill (`vaultPillTarget()`); valid across tabs because the Home tab
    /// stays mounted. `.zero` until first laid out (then a fallback is used).
    fileprivate var pillFrame: CGRect = .zero

    private init() {}

    struct Flight: Identifiable {
        let id = UUID()
        let image: UIImage?
        let foodName: String
        /// Global center of the tapped element; the chip launches from here.
        let source: CGPoint?
    }

    /// Fly a chip to the vault pill, then pop the confirmation modal.
    /// Debounced so a second trigger mid-celebration is ignored.
    func celebrate(image: UIImage?, foodName: String, from source: CGPoint?) {
        guard flight == nil, savedName == nil else { return }
        let trimmed = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Meal" : trimmed
        Haptics.tap()
        flight = Flight(image: image, foodName: name, source: source)
        // Modal after the flight, driven here so it always shows.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 720_000_000)
            flight = nil
            savedName = name
        }
    }

    fileprivate func setPillFrame(_ rect: CGRect) {
        if rect != .zero { pillFrame = rect }
    }
}

extension View {
    /// Publish this view's global frame as the vault-flight target (the pill).
    func vaultPillTarget() -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { VaultCelebration.shared.setPillFrame(geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        VaultCelebration.shared.setPillFrame(f)
                    }
            }
        )
    }

    /// Host the vault celebration overlay (flight chip + confirmation modal).
    /// Apply once, at the tab-view root, so it renders above every tab.
    func vaultCelebrationHost() -> some View {
        modifier(VaultCelebrationHostModifier())
    }
}

private struct VaultCelebrationHostModifier: ViewModifier {
    @StateObject private var c = VaultCelebration.shared

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                ZStack {
                    if let flight = c.flight {
                        let target = c.pillFrame != .zero
                            ? CGPoint(x: c.pillFrame.midX, y: c.pillFrame.midY)
                            : CGPoint(x: 74, y: 68)
                        let source = flight.source
                            ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.72)
                        VaultFlyChip(start: source, end: target, image: flight.image, onComplete: {})
                            .allowsHitTesting(false)
                    }
                    if let name = c.savedName {
                        VaultSavedModal(foodName: name) { c.savedName = nil }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// A meal-photo chip that arcs from the Save button up to the vault pill,
/// shrinking as it "drops into" the vault. Driven by a per-frame
/// `TimelineView` clock (same approach as the analyzing orb) so the arc is
/// smooth. Calls `onComplete` when it lands.
private struct VaultFlyChip: View {
    let start: CGPoint
    let end: CGPoint
    let image: UIImage?
    let onComplete: () -> Void

    @State private var startDate = Date()
    @State private var done = false
    private let duration: TimeInterval = 0.72

    var body: some View {
        TimelineView(.animation) { tl in
            let elapsed = tl.date.timeIntervalSince(startDate)
            let raw = min(1, max(0, elapsed / duration))
            let p = Self.easeInOut(CGFloat(raw))
            chip(size: size(p))
                .position(position(p))
                .opacity(opacity(p))
        }
        .allowsHitTesting(false)
        .onAppear {
            startDate = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !done else { return }
                done = true
                onComplete()
            }
        }
    }

    @ViewBuilder
    private func chip(size: CGFloat) -> some View {
        let radius = max(6, size * 0.28)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.brandSoft
                    Image(systemName: "fork.knife")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Color.brand)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
    }

    private func size(_ p: CGFloat) -> CGFloat { 84 + (26 - 84) * p }
    private func opacity(_ p: CGFloat) -> Double {
        p < 0.85 ? 1 : Double(max(0, (1 - p) / 0.15))
    }
    private func position(_ p: CGFloat) -> CGPoint {
        // Quadratic bezier with a control point lifted above the path so the
        // chip arcs up and over into the vault.
        let ctrl = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 120)
        return Self.bezier(start, ctrl, end, p)
    }

    private static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
            y: u * u * a.y + 2 * u * t * c.y + t * t * b.y
        )
    }
    private static func easeInOut(_ x: CGFloat) -> CGFloat {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

/// Confirmation modal shown after the flight lands: a centered card with an
/// archive-box + checkmark pop, a radial burst, brand confetti, the food
/// name, and an auto-dismiss. Reuses `SavedConfirmationSheet`'s celebration
/// language, scaled to a compact modal.
private struct VaultSavedModal: View {
    let foodName: String
    var autoDismiss: Bool = true
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var iconScale: CGFloat = 0.3
    @State private var burstScale: CGFloat = 0.5
    @State private var burstOpacity: Double = 1
    @State private var confetti = false
    @State private var dismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            card
                .scaleEffect(appeared ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear(perform: animateIn)
    }

    private var card: some View {
        VStack(spacing: AppSpacing.sm) {
            iconBlock.frame(height: 96)
            Text("Saved to Vault")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text(foodName)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl2, style: .continuous)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl2, style: .continuous)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowElevated)
        .padding(AppSpacing.xl)
    }

    private var iconBlock: some View {
        ZStack {
            BrandConfetti(active: confetti)
            Circle()
                .strokeBorder(Color.brand, lineWidth: 4)
                .frame(width: 66, height: 66)
                .scaleEffect(burstScale)
                .opacity(burstOpacity)
            Image(systemName: "archivebox.fill")
                .font(.system(size: 46, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.brandDeep, Color.brand)
                .scaleEffect(iconScale)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .background(Circle().fill(Color.bgSurface).padding(-1))
                        .offset(x: 8, y: 8)
                        .scaleEffect(iconScale)
                }
        }
    }

    private func animateIn() {
        Haptics.success()
        guard !reduceMotion else {
            appeared = true; iconScale = 1; burstOpacity = 0
            scheduleAutoDismiss()
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.74)) { appeared = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.56).delay(0.06)) { iconScale = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.06)) {
            burstScale = 2.1; burstOpacity = 0
        }
        confetti = true
        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        guard autoDismiss else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            dismiss()
        }
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        withAnimation(.easeIn(duration: 0.2)) { appeared = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            onDismiss()
        }
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
