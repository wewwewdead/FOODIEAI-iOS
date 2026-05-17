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
    /// Used to route the after-save "View today / tracker" suggestion
    /// to the Tracker tab via the same channel notification taps use.
    @EnvironmentObject private var notifRouter: NotificationRouter
    /// Phase 21.12 — read for the Healthy Choice toggle so the daily
    /// quest card can hide when the user has opted out in Profile.
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var pickerSheet: PickerSheet? = nil
    @State private var showingSourceDialog = false
    @State private var photosSelection: PhotosPickerItem? = nil
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
    /// Today's meal count, fetched alongside `cachedCalorieStatus` so the
    /// daily check-in card can render its primary copy without a second
    /// `todaysLogs` round-trip. `nil` while loading; the card renders
    /// an unobtrusive idle state in that case.
    @State private var cachedTodayMealCount: Int? = nil
    /// Observed so a save-success `markToday()` re-renders the check-in
    /// line ("First check-in logged.") and the personalized empty state
    /// updates when the user crosses midnight without restarting the app.
    @StateObject private var rhythmStore = LoggingRhythmStore.shared

    /// Phase 21 — manual log sheet presentation flag.
    @State private var showingManualLog: Bool = false
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

    /// Lightweight after-save banner state. The struct lives inline
    /// because no other surface reads or writes it.
    struct ManualLogToast: Identifiable, Equatable {
        let id = UUID()
        let foodName: String
        let questRewardCopy: String?
        let scansRemaining: Int
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
                            case .idle, .picked, .analyzing, .moodPulse, .clarifying:
                                // .moodPulse is rendered as the empty/idle
                                // hero with the mood sheet on top — the
                                // result rendering would be a misleading
                                // background while the user reflects.
                                // .clarifying does the same — the photo
                                // card stays the focal background while
                                // the Quantity Clarification sheet asks
                                // the user about portions.
                                emptyOrPickedFlow
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        removal: .opacity.combined(
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
            Task {
                // Load the picker's bytes, then hand them off to a
                // background task that downsamples via ImageIO without
                // ever decoding the full-resolution buffer into memory.
                // A 12 MP HEIC that would otherwise inflate to ~50 MB
                // decoded lands as a ~2048pt-edge UIImage instead, which
                // the existing compressMain/compressThumbnail passes
                // still resize to their target sizes for upload.
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let image = await Task.detached(priority: .userInitiated) {
                        ImagePreparation.downsampledImage(from: data)
                            ?? UIImage(data: data)
                    }.value
                    // `data` (potentially tens of MB for a 12 MP HEIC)
                    // is released here as the enclosing `if let` falls
                    // out of scope — only the downsampled `UIImage`
                    // survives into setPhoto.
                    if !Task.isCancelled, let image {
                        viewModel.setPhoto(image, source: .library)
                    }
                }
                // Clear the selection so the same image can be repicked
                // and so PhotosUI releases its internal reference to the
                // PHAsset.
                photosSelection = nil
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
                onNextStepAction: handleNextStepAction
            )
            .presentationDetents([.fraction(0.7), .large])
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
        // Quantity Clarification — sheet presentation extracted to a
        // ViewModifier so the type-checker doesn't have to thread the
        // whole CaptureView modifier chain through the new sheet's
        // generic context. Adding it inline pushed
        // `body` past Swift's expression type-check budget.
        .modifier(ClarificationSheetModifier(viewModel: viewModel))
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
        .onChange(of: viewModel.state.isIdle) { wasIdle, isIdle in
            // Edge: success sheet dismissed (.saved → .idle).
            // Guard against the no-op idle→idle case.
            guard !wasIdle, isIdle else { return }
            // Phase 20 — a fresh return to idle ends the current "scan
            // attempt." Re-arm the calorie-goal warning so the next
            // press evaluates honestly rather than riding the prior
            // "Scan anyway" decision.
            bypassCalorieWarningOnce = false
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
                    Task { await recordMoodForManualLog(log.id, mood: mood) }
                },
                onSkip: {}
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .modifier(ManualLogToastModifier(
            toast: $manualLogToast,
            onScanAction: {
                if FreeTierLimits.scansRemainingToday > 0 {
                    manualLogToast = nil
                    requestScan()
                } else {
                    // Future paywall hook — for now this is a no-op
                    // (placeholder until Phase 22 ships the paywall).
                    manualLogToast = nil
                }
            },
            onTrackerAction: {
                manualLogToast = nil
                notifRouter.requestTab(1)
            }
        ))
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
            Button("Take Photo") {
                requestScan()
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
            await viewModel.loadQuest()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.loadQuest() }
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
                scansRemaining: FreeTierLimits.scansRemainingToday
            )
        }
    }

    /// Writes a mood for a just-saved manual log. Mirrors the photo
    /// flow's `CaptureViewModel.recordMood` but is intentionally
    /// standalone — the manual path doesn't enter `.moodPulse` state,
    /// so there's no view-model anchor to reuse. Failures are silent;
    /// mood is enrichment, not critical.
    private func recordMoodForManualLog(_ logId: UUID, mood: FoodLog.Mood) async {
        let service = FoodLogService()
        do {
            _ = try await service.setMood(mood, on: logId)
        } catch {
            #if DEBUG
            NSLog("[Mood] manual-log setMood FAILED id=%@ err=%@",
                  logId.uuidString, "\(error)")
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .accessibilityHint("Opens your profile")
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

        // Phase 21.5 — daily quest card. Sits between hero copy and
        // the daily check-in / photo card so the user sees the
        // suggested action right after orientation. Tappable: opens
        // the action sheet that routes to Scan or Manual Log.
        //
        // Phase 21.12 — gated on `profile.healthyChoicesEnabled`.
        // When the user has disabled the Healthy Choice toggle in
        // Profile → Preferences, the card disappears entirely (not
        // just dimmed) so Home stays quiet for users who want it.
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
            .padding(.top, AppSpacing.lg)
            .transition(.opacity)
            // Phase 21.10's 1.2s self-clear timer was removed in
            // Phase 21.11 — the celebration modal (overlaid below)
            // now owns the trigger's lifecycle. It auto-dismisses
            // after ~2.5s or on tap, then nils
            // `viewModel.justCompletedQuest` itself via its
            // `onDismiss`. The in-place card morph still fires
            // because the card observes the same trigger, and its
            // own animation is short enough to finish before the
            // modal goes away.
        }

        // Daily Check-in / Today Pulse — combined card. Renders the
        // daily check-in line (count-aware, deterministic, non-shaming)
        // as the primary copy, plus an optional calorie sub-line when
        // the user has a valid daily goal, plus an end-of-day return
        // hook after 20:00 once at least one meal is logged. Reads
        // entirely from caches populated by the same `.task` that
        // feeds the scan-warning dialog — no extra polling/timers.
        if viewModel.state.isIdle, let count = cachedTodayMealCount {
            DailyCheckInCard(
                mealCount: count,
                rhythm: rhythmStore.rhythm(),
                status: cachedCalorieStatus,
                now: Date()
            )
            .padding(.top, AppSpacing.lg)
            .transition(.opacity)
        }

        // Photo card (always 354 wide-ish via maxWidth; aspect-ratio 1)
        photoCard
            .padding(.top, AppSpacing.xl2)

        // Subtle hint chip
        if viewModel.state.isIdle {
            hintChip
                .padding(.top, AppSpacing.lg)
                .frame(maxWidth: .infinity)
                .transition(.opacity)

            // First-time activation hint. Surfaces only for users whose
            // local rhythm store has never recorded a save — i.e. lifetime
            // empty. `markToday()` on first successful save flips
            // `totalLoggedDays` to 1 and this element drops out naturally
            // (no dismissal state required).
            if rhythmStore.rhythm().totalLoggedDays == 0 {
                firstScanActivationHint
                    .padding(.top, AppSpacing.sm)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            // Phase 15 — secondary affordance under the photo card so the
            // re-log path is visible without competing with the primary
            // CTA. Only shown in idle state; once a photo is picked the
            // user is committed to the analyze flow.
            quickRelogLink
                .padding(.top, AppSpacing.md)
                .frame(maxWidth: .infinity)
                .transition(.opacity)

            // Quick-log favorite shortcut. Visible only when the user
            // has at least one hearted meal — otherwise the link points
            // to an empty list. Reuses RecentMealsSheet's data path so
            // there's no new fetch.
            if !favoritesStore.favorites.isEmpty {
                quickFavoriteLink
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
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
                            DelightfulImageEntry(image: image)
                                .id(ObjectIdentifier(image))
                            // First-scan magic: brand-tinted glow ring that
                            // radiates around the photo as it lands. Lives
                            // in the same overlay frame as the image so it
                            // hugs the card edge. Owns its own fade-out
                            // (.task with try/catch), so this view doesn't
                            // retain a delayed Task — SwiftUI cancels the
                            // .task automatically when the glow's `onDone`
                            // flips visibility off and removes it.
                            if firstScanGlowVisible {
                                FirstScanGlow {
                                    firstScanGlowVisible = false
                                }
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                            }
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
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
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

    /// Companion to `quickRelogLink`. Surfaces the favorites-filtered
    /// picker so users with a small set of hearted meals can land in
    /// one tap instead of scrolling through the full recents list.
    private var quickFavoriteLink: some View {
        Button {
            Haptics.tap()
            showingFavoriteMeals = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .heavy))
                Text("Quick log a favorite")
                    .appFont(.captionStrong)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick log a favorite meal")
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
        Text("Your first scan builds today's pulse.")
            .appFont(.caption)
            .foregroundStyle(Color.brandDeep)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Tip: your first scan builds today's pulse.")
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
        case .clarifying:
            // Quantity Clarification sheet owns the user's attention.
            // No bottom CTA so the underlying photo card reads as a
            // quiet background, not a competing affordance.
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
        if let status, status.hasValidGoal, mealCount >= 1 {
            if status.warningState == .reached || status.exceededBy > 0 {
                return "goal reached"
            }
            return "about \(Int(status.remaining.rounded())) calories left"
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .rotationEffect(.degrees(reduceMotion ? 0 : (landed ? 0 : -6)))
            .opacity(landed ? 1 : 0)
            .onAppear { runEntrance() }
    }

    private var scale: CGFloat {
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
private struct AnalyzingImageAura: View {
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
                    Text(toast.scansRemaining > 0
                         ? "Try a photo scan? \(toast.scansRemaining) left today"
                         : "Upgrade for \(FreeTierLimits.scansPerDayPro) photo scans/day")
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

#if DEBUG
#Preview("CaptureView — idle") {
    CaptureView()
}
#endif
