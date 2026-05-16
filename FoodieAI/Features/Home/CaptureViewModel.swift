import SwiftUI

/// Drives the capture → analyze → save flow on the Home tab.
///
/// State graph:
///   .idle → setPhoto → .picked
///   .picked → analyze() → .analyzing → .ready | .noFood | .failed
///   .ready → save() → .saving → .saved | .saveFailed
///   .saved → discardSaved() → .idle
///   any non-idle → resetToPick / discardCurrent → .idle
///
/// While `.analyzing` or `.saving`, a duplicate call is a no-op.
@MainActor
final class CaptureViewModel: ObservableObject {
    enum State {
        case idle
        case picked(UIImage)
        case analyzing(UIImage)
        case noFood(UIImage)
        /// Quantity Clarification — first-pass analyze returned a
        /// non-empty `portionAmbiguousItems`. Carries the original
        /// response so we can fall back to it if the user dismisses
        /// or the refine call fails.
        case clarifying(UIImage, AnalyzeResponse, [GeminiAnalysis.AmbiguousItem])
        case ready(UIImage, AnalyzeResponse)
        case saving(UIImage, AnalyzeResponse)
        case saved(UIImage, AnalyzeResponse, FoodLog)
        /// Phase 18 — between `.saved` (success-sheet choreography) and
        /// `.idle`. Carries the inserted log id so `recordMood` can
        /// patch the right row.
        case moodPulse(UIImage, AnalyzeResponse, FoodLog)
        case saveFailed(UIImage, AnalyzeResponse, Error)
        case failed(UIImage, AnalyzeError)

        var image: UIImage? {
            switch self {
            case .idle: return nil
            case .picked(let i), .analyzing(let i), .noFood(let i):
                return i
            case .ready(let i, _), .saving(let i, _), .failed(let i, _):
                return i
            case .saved(let i, _, _), .saveFailed(let i, _, _),
                 .moodPulse(let i, _, _):
                return i
            case .clarifying(let i, _, _):
                return i
            }
        }

        var isIdle: Bool {
            if case .idle = self { return true } else { return false }
        }

        var isAnalyzing: Bool {
            if case .analyzing = self { return true } else { return false }
        }

        var isSaving: Bool {
            if case .saving = self { return true } else { return false }
        }

        var isSaved: Bool {
            if case .saved = self { return true } else { return false }
        }

        /// Phase 18.
        var isMoodPulse: Bool {
            if case .moodPulse = self { return true } else { return false }
        }

        /// Quantity Clarification.
        var isClarifying: Bool {
            if case .clarifying = self { return true } else { return false }
        }
    }

    @Published private(set) var state: State = .idle

    /// Where the current photo came from. Diagnostic-only for now —
    /// drives the `[Analyze-prep]` log line so we can tell whether the
    /// camera or photo-library path is producing oversized uploads.
    enum PhotoSource: String { case camera, library }
    private(set) var lastPhotoSource: PhotoSource = .library

    /// Phase 15 — quick-re-log confirmation toast. Independent of `state`
    /// because a user can fire several re-logs in a row without ever
    /// leaving `.idle`, and we don't want to wedge the main capture flow.
    @Published var relogToast: RelogToast? = nil

    /// Phase 21.5 — today's daily quest, displayed as a tappable card
    /// on Home above the photo card. `nil` until loaded; the card
    /// hides itself in that state rather than rendering a placeholder.
    @Published var dailyQuest: DailyQuest? = nil
    /// Mirrors `Profile.lastQuestCompleted` for today. We carry it on
    /// the view model (rather than re-reading from DailyQuest.completed
    /// every render) so the quest card can flip to its done state the
    /// instant a save completes the quest, without waiting for the
    /// next `loadQuest()` round-trip.
    @Published var questCompleted: Bool = false

    /// Phase 21.10 — fires the *one-shot* live-completion animation on
    /// the Home quest card. `questCompleted` is the persistent state
    /// (sticks for the rest of the day); this is the trigger that
    /// plays the morph in the moment the save lands. The card view
    /// nils it back out once the animation completes so subsequent
    /// re-renders don't replay.
    @Published var justCompletedQuest: DailyQuestCompletionMoment? = nil

    struct DailyQuestCompletionMoment: Equatable {
        let rewardCopy: String
        let timestamp: Date
    }

    /// Called from the save paths (analyzed + manual-log) after the
    /// quest evaluator reports the quest was just satisfied. Flips
    /// `questCompleted` so the card stays in the completed state, and
    /// fires `justCompletedQuest` so a visible card animates the morph
    /// in the moment instead of waiting for the next foreground.
    func recordQuestCompletion(rewardCopy: String) {
        self.questCompleted = true
        self.justCompletedQuest = DailyQuestCompletionMoment(
            rewardCopy: rewardCopy,
            timestamp: Date()
        )
    }

    /// Cleared by the card view ~1.2s after the animation kicks off so
    /// subsequent re-renders within the same session don't replay.
    func clearJustCompletedQuest() {
        self.justCompletedQuest = nil
    }

    /// Phase 15.
    struct RelogToast: Identifiable, Equatable {
        let id = UUID()
        let foodName: String
        let kind: Kind

        enum Kind: Equatable {
            case success
            case failure
        }
    }

    private let analyzer: AnalyzeService
    private let imageService: FoodImageService
    private let logService: FoodLogService
    /// Phase 16. Optional dependencies that feed coach context into
    /// `/analyze`. Both can fail or no-op without breaking the flow:
    /// the multipart body just omits the corresponding fields and the
    /// server falls back to v1 behavior.
    private let history: MealHistoryService
    private let profileService: ProfileService

    init(analyzer: AnalyzeService = AnalyzeService(),
         imageService: FoodImageService = FoodImageService(),
         logService: FoodLogService = FoodLogService(),
         history: MealHistoryService = MealHistoryService(),
         profileService: ProfileService = ProfileService()) {
        self.analyzer = analyzer
        self.imageService = imageService
        self.logService = logService
        self.history = history
        self.profileService = profileService
    }

    /// Pick from the photo library or capture from the camera. Always
    /// transitions to `.picked` regardless of the previous state.
    func setPhoto(_ image: UIImage, source: PhotoSource = .library) {
        Haptics.tap()
        lastPhotoSource = source
        state = .picked(image)
    }

    /// Run /analyze on the current photo. No-op if there's no image, or if
    /// a request is already in flight.
    ///
    /// Phase 12: the multipart body now uses `compressMain` (1024px / 0.70).
    /// We *don't* cache these bytes anymore — `save()` regenerates main +
    /// thumbnail from the original `UIImage` so it can produce the smaller
    /// thumbnail at the same time. The two paths (analyze upload vs. save
    /// upload) don't need to be byte-identical.
    func analyze() async {
        guard let image = state.image else { return }
        if case .analyzing = state { return }

        state = .analyzing(image)

        // Image resize + JPEG encode is CPU-bound. Running it on the
        // MainActor (this view model's default) janks the analyzing-aura
        // animation that's appearing at the same moment. UIGraphicsImage-
        // Renderer + UIImage.draw(in:) are documented as thread-safe on
        // modern iOS; hop to a userInitiated detached task so the main
        // thread stays free for the Siri-aura animation kick-off.
        let jpeg = await Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }.value

        // If the user discarded / reset while compression was running,
        // we're no longer in `.analyzing`. Don't overwrite the fresh
        // state (`.idle` / `.picked`) with a stale `.failed` / `.ready`.
        guard case .analyzing = state, !Task.isCancelled else { return }

        guard let jpeg else {
            state = .failed(image, .imageTooLarge)
            return
        }

        #if DEBUG
        let source = lastPhotoSource.rawValue
        print("[Analyze-prep] original=\(image.size.width)x\(image.size.height) compressed-bytes=\(jpeg.count) source=\(source)")
        #endif

        let context = await fetchContextForAnalyze()

        do {
            let response = try await analyzer.analyze(
                jpegData: jpeg,
                recentMeals: context.recentMeals,
                preferredCoaches: context.preferredCoaches,
                recentMoods: context.recentMoods
            )
            // Server emits empty-string `fallback` on success (Gemini fills the
            // structured-output field with ""); only a *non-empty* fallback
            // means "no food detected".
            if response.analysis.hasFood {
                // Quantity Clarification — if Gemini flagged any
                // portion-ambiguous items, pause for the user to confirm
                // or adjust quantities before showing the result.
                let ambiguous = response.analysis.portionAmbiguousItems ?? []
                if !ambiguous.isEmpty {
                    Haptics.prepare()
                    state = .clarifying(image, response, ambiguous)
                } else {
                    Haptics.prepare() // warm the engine for the upcoming save tap
                    state = .ready(image, response)
                }
            } else {
                Haptics.warning()
                state = .noFood(image)
            }
        } catch is CancellationError {
            // The fire-and-forget analyze Task got cancelled (e.g., the
            // user discarded mid-flight). Restore the previous `.picked`
            // affordance instead of painting a fake "Something went
            // wrong" — the user didn't fail anything.
            state = .picked(image)
        } catch let err as AnalyzeError {
            Haptics.error()
            state = .failed(image, err)
        } catch {
            Haptics.error()
            state = .failed(image, .networkUnavailable)
        }
    }

    /// Phase 16/18 context bundle for the analyze call. All queries are
    /// best-effort: any failure resolves to an empty array so the
    /// analyze call falls back to v1 (no context) shape. Extracted so
    /// the Quantity Clarification refine call can reuse the same
    /// current-state lookup rather than threading values through the
    /// view model's stored state.
    private struct AnalyzeContext {
        let recentMeals: [FoodLog]
        let preferredCoaches: [String]
        let recentMoods: [FoodLog]
    }

    private func fetchContextForAnalyze() async -> AnalyzeContext {
        async let recentTask: [FoodLog]? = try? history.recentMealsForCoachContext()
        async let prefsTask: [String]? = try? profileService.currentProfile().preferredCoaches
        async let moodsTask: [FoodLog]? = try? history.recentMoodsForCoachContext()
        let recentMeals = (await recentTask) ?? []
        let preferredCoaches = (await prefsTask) ?? []
        let recentMoods = (await moodsTask) ?? []
        return AnalyzeContext(
            recentMeals: recentMeals,
            preferredCoaches: preferredCoaches,
            recentMoods: recentMoods
        )
    }

    // MARK: - Quantity Clarification

    /// Diagnostic-only — short case label for logs so we can tell
    /// which branch swallowed a refine call without dumping the
    /// associated values.
    private static func stateName(_ s: State) -> String {
        switch s {
        case .idle:        return ".idle"
        case .picked:      return ".picked"
        case .analyzing:   return ".analyzing"
        case .noFood:      return ".noFood"
        case .clarifying:  return ".clarifying"
        case .ready:       return ".ready"
        case .saving:      return ".saving"
        case .saved:       return ".saved"
        case .moodPulse:   return ".moodPulse"
        case .saveFailed:  return ".saveFailed"
        case .failed:      return ".failed"
        }
    }

    /// User confirmed quantities. Re-run `/analyze` with the
    /// `user_quantities` context. On success transition to `.ready`
    /// with the refined response; on any failure fall back to the
    /// original first-pass response — don't punish the user for a
    /// network hiccup on the second pass.
    func refineAnalysis(with quantities: [String: String]) async {
        #if DEBUG
        NSLog("[Clarify] refineAnalysis called with quantities=%@ currentState=%@",
              "\(quantities)", Self.stateName(state))
        #endif

        // Fix A — Accept both `.clarifying` and `.ready` here. The
        // sheet's dismiss handler can flip us to `.ready` (via
        // acceptOriginalAnalysis) synchronously after `dismiss()`
        // before the refine Task body runs — that's a race, not a
        // change of intent. The user already tapped Update Analysis;
        // honor it regardless of which state we're in by the time we
        // get to inspect it.
        let image: UIImage
        let originalResponse: AnalyzeResponse
        switch state {
        case .clarifying(let i, let r, let items):
            #if DEBUG
            NSLog("[Clarify] guard passed, state was .clarifying with %d items",
                  items.count)
            #endif
            image = i
            originalResponse = r
        case .ready(let i, let r):
            #if DEBUG
            NSLog("[Clarify] state raced to .ready before refine started; honoring refine intent anyway")
            #endif
            image = i
            originalResponse = r
        default:
            #if DEBUG
            NSLog("[Clarify] refineAnalysis: state was %@, bailing",
                  Self.stateName(state))
            #endif
            return
        }

        state = .analyzing(image) // re-show the analyzing UI

        let jpeg = await Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }.value

        // Same guard as `analyze()`: if state has moved away from the
        // re-analyzing window while compression was running, do not
        // stomp it.
        guard case .analyzing = state, !Task.isCancelled else { return }

        guard let jpeg else {
            #if DEBUG
            NSLog("[Clarify] compression FAILED; falling back to original response")
            #endif
            state = .ready(image, originalResponse)
            return
        }

        let pairs = quantities.map { (name: $0.key, quantity: $0.value) }
        #if DEBUG
        NSLog("[Clarify] compressed jpeg bytes=%d; about to call analyzer.analyze(userQuantities=%d)",
              jpeg.count, pairs.count)
        #endif
        let context = await fetchContextForAnalyze()

        do {
            let refined = try await analyzer.analyze(
                jpegData: jpeg,
                recentMeals: context.recentMeals,
                preferredCoaches: context.preferredCoaches,
                recentMoods: context.recentMoods,
                userQuantities: pairs
            )
            #if DEBUG
            NSLog("[Clarify] refineAnalysis succeeded — refined food=%@ calories=%@ (original calories=%@)",
                  refined.analysis.food ?? "<nil>",
                  refined.analysis.calories.map { "\($0)" } ?? "<nil>",
                  originalResponse.analysis.calories.map { "\($0)" } ?? "<nil>")
            #endif
            Haptics.prepare()
            // If the refine pass somehow lost food detection, prefer
            // the original — the user already saw it succeed once.
            state = .ready(image, refined.analysis.hasFood ? refined : originalResponse)
        } catch {
            #if DEBUG
            NSLog("[Clarify] refine FAILED, falling back to original: %@", "\(error)")
            #endif
            state = .ready(image, originalResponse)
        }
    }

    /// User dismissed the clarification sheet without adjusting —
    /// keep the first-pass analysis. Also called when the sheet is
    /// drag-dismissed.
    func acceptOriginalAnalysis() {
        guard case .clarifying(let image, let response, _) = state else { return }
        Haptics.prepare()
        state = .ready(image, response)
    }

    /// Save the current `.ready` analysis. No-op if not in `.ready` state, or
    /// if a save is already in flight.
    ///
    /// Phase 12 pipeline (paired-image dual-write):
    ///   1. Generate a fresh main JPEG (1024px / 0.70) AND a thumbnail JPEG
    ///      (256px / 0.60) from the original captured `UIImage`. The bytes
    ///      sent to /analyze were already discarded — we recompress here
    ///      because the thumbnail must be derived from the same source
    ///      image and we don't want a second main compression to differ
    ///      from the thumbnail's reference.
    ///   2. Upload both objects to Supabase Storage in parallel via
    ///      `uploadMealImages(...)`. They share an `imageId`; the thumb is
    ///      `{imageId}_thumb.jpg`.
    ///   3. Build a `NewFoodLog` carrying both paths. NO `user_id` — DB
    ///      default + RLS handle that.
    ///   4. Insert; transition to `.saved`.
    func save() async {
        guard case .ready(let image, let response) = state else { return }
        state = .saving(image, response)

        // Generate main + thumb JPEGs concurrently on a background
        // thread; the two passes are independent and CPU-heavy enough
        // (HEIC → JPEG re-encode at two sizes) that running them on the
        // MainActor visibly hitched the "Save to today" press response.
        let mainTask = Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }
        let thumbTask = Task.detached(priority: .userInitiated) {
            ImagePreparation.compressThumbnail(image)
        }
        let mainData  = await mainTask.value
        let thumbData = await thumbTask.value

        // User discarded mid-save; don't paint `.saveFailed` over the
        // already-cleared state.
        guard case .saving = state, !Task.isCancelled else { return }

        guard let mainData, let thumbData else {
            state = .saveFailed(image, response, SaveError.imagePreparationFailed)
            return
        }

        #if DEBUG
        NSLog("[Save] mainBytes=%d thumbBytes=%d", mainData.count, thumbData.count)
        #endif

        do {
            let uploaded = try await imageService.uploadMealImages(
                mainData: mainData,
                thumbnailData: thumbData
            )
            #if DEBUG
            NSLog("[Save] uploaded main_path=%@ thumb_path=%@",
                  uploaded.mainPath, uploaded.thumbPath)
            #endif

            let draft = NewFoodLog(
                foodName:        response.analysis.food ?? "Unknown",
                imagePath:       uploaded.mainPath,
                imageThumbPath:  uploaded.thumbPath,
                calories:        response.analysis.calories ?? 0,
                carbsG:          response.analysis.carbs ?? 0,
                sugarG:          response.analysis.sugar ?? 0,
                proteinG:        response.analysis.protein,
                fatG:            response.analysis.fat,
                fiberG:          response.analysis.fiber,
                benefits:        response.analysis.benefits ?? [],
                drawbacks:       response.analysis.drawbacks ?? [],
                nutrients:       response.analysis.nutrients ?? [],
                coachName:       response.coach,
                coachAdvice:     response.analysis.coachAdvice
            )

            let inserted = try await logService.insert(draft)
            #if DEBUG
            NSLog("[Save] inserted food_logs.id=%@ user_id=%@",
                  inserted.id.uuidString, inserted.userId.uuidString)
            NSLog("[Save] macros: cal=%.0f carbs=%.1fg sugar=%.1fg protein=%@ fat=%@ fiber=%@",
                  inserted.calories, inserted.carbsG, inserted.sugarG,
                  inserted.proteinG.map { String(format: "%.1fg", $0) } ?? "nil",
                  inserted.fatG.map     { String(format: "%.1fg", $0) } ?? "nil",
                  inserted.fiberG.map   { String(format: "%.1fg", $0) } ?? "nil")
            #endif

            // Phase 13: success haptic fires from `SavedConfirmationSheet`
            // when the checkmark hits full scale, so it lands with the
            // visual — not here on row insert.
            state = .saved(image, response, inserted)

            // Retention polish — mark today as logged in the local
            // rhythm store so the Home daily check-in card reflects
            // continuity without a server round-trip. Idempotent: the
            // first save of the day writes; subsequent saves on the
            // same local calendar day are a no-op.
            LoggingRhythmStore.shared.markToday()

            // Phase 17: increment the local saves counter (drives
            // permission-sheet timing) and suppress today's reminder
            // for the matching meal window so we don't nudge a user
            // who just logged.
            NotificationGate.recordSave()
            Task.detached {
                await AppForegroundOrchestrator.shared
                    .suppressWindow(for: inserted.eatenAt)
            }

            // Phase 20: a fresh meal moves the under/over calorie line.
            // Re-evaluate the end-of-day under-calorie reminder so the
            // pending notification reflects the new total (or gets
            // cancelled if this save pushed us over the goal).
            Task {
                await CalorieReminderService.shared.recompute()
            }

            // Phase 21: streak + daily-quest updates. Both are
            // best-effort — the meal is already saved, and a failure
            // here must not back out the user's row. They fire in a
            // detached Task so the saved-state UI doesn't wait on
            // them.
            //
            // Phase 21.5: after the evaluator runs, re-read the quest
            // state so the Home quest card transitions to its done
            // state without waiting for the next foreground.
            Task { [weak self] in
                _ = try? await StreakService.shared.recordLog(
                    at: inserted.eatenAt
                )
                let evaluation = try? await DailyQuestService.shared
                    .evaluateQuestProgress(after: inserted)
                // Phase 21.10 — if the just-saved meal completed
                // today's quest, fire the live-completion animation
                // before refreshing from DB so the card morphs in
                // place rather than snap-flipping on the next
                // `loadQuest()` round-trip.
                if let evaluation,
                   evaluation.questCompleted,
                   let reward = evaluation.rewardCopy {
                    await self?.recordQuestCompletion(rewardCopy: reward)
                }
                await self?.loadQuest()
            }

            // Phase 18: the `.saved → .moodPulse` transition is driven
            // entirely by `discardSaved()` — i.e., when the user closes
            // the success sheet themselves. We don't auto-advance on a
            // timer because the SavedConfirmationSheet is bound to
            // `state.isSaved`; flipping state out from under it would
            // dismiss the sheet before the user can read it.
        } catch {
            #if DEBUG
            NSLog("[Save] FAILED: %@", "\(error)")
            #endif
            Haptics.error()
            state = .saveFailed(image, response, error)
        }
    }

    /// Retry from a `.saveFailed` state — re-enters `.saving` and tries
    /// the upload + insert again. No-op outside `.saveFailed`.
    func retrySave() async {
        guard case .saveFailed(let image, let response, _) = state else { return }
        state = .ready(image, response)
        await save()
    }

    /// Dismiss the saved-confirmation sheet and advance into the Phase
    /// 18 mood pulse. Idempotent — also called by SwiftUI when the
    /// success sheet is auto-dismissed by the `.saved → .moodPulse`
    /// transition timer. In that case `state` is already `.moodPulse`
    /// (or beyond) and we leave it alone.
    func discardSaved() {
        if case .saved(let image, let response, let log) = state {
            state = .moodPulse(image, response, log)
        }
        // Any other state (including .moodPulse / .idle) means the
        // transition either already ran or the flow has moved past
        // mood — do not reset.
    }

    // MARK: - Phase 18: Mood pulse

    /// User tapped one of the three emojis. Transitions to `.idle`
    /// optimistically (the sheet has its own confirmation animation
    /// before it dismisses) and writes the mood in the background.
    /// Failures are silent — mood is enrichment, not critical — but
    /// logged in DEBUG.
    func recordMood(_ mood: FoodLog.Mood) async {
        guard case .moodPulse(_, _, let log) = state else { return }
        state = .idle
        do {
            _ = try await logService.setMood(mood, on: log.id)
            #if DEBUG
            NSLog("[Mood] set log=%@ mood=%@",
                  log.id.uuidString, mood.rawValue)
            #endif
        } catch {
            #if DEBUG
            NSLog("[Mood] set FAILED log=%@ mood=%@ err=%@",
                  log.id.uuidString, mood.rawValue, "\(error)")
            #endif
        }
    }

    /// User tapped Skip or drag-dismissed the pulse — no DB write.
    func skipMoodPulse() {
        if case .moodPulse = state {
            state = .idle
        }
    }

    /// Phase 18 — the user backgrounded the app while the mood pulse
    /// (or the success sheet just before it) was on screen. We choose
    /// to drop the pulse rather than ambush them on next foreground;
    /// the meal stays unrecorded for mood, which is the intended
    /// trade-off.
    func cancelMoodPulseIfPresent() {
        switch state {
        case .moodPulse, .saved:
            #if DEBUG
            NSLog("[Mood] pulse cancelled by background")
            #endif
            state = .idle
        default:
            break
        }
    }

    /// User wants to start over with a new photo. Goes back to `.idle` so
    /// the dashed drop zone shows the empty state again and the picker
    /// can be re-presented from there.
    func resetToPick() {
        state = .idle
    }

    /// Same as `resetToPick` for now; preserved as a separate entry point
    /// in case the design diverges (e.g. cancel-without-resetting).
    func discardCurrent() {
        state = .idle
    }

    // MARK: - Phase 15: Quick re-log

    /// Insert a `.relogged` row that copies every field from `source`
    /// except identity (id), timestamps (eatenAt/createdAt), and origin
    /// markers. The image objects in Storage are NOT re-uploaded — both
    /// rows reference the same `image_path` / `image_thumb_path`. Both
    /// rows belong to the same user (RLS guaranteed by the source row's
    /// presence in this client), so the shared object reference is safe.
    ///
    /// On success: drops a `RelogToast(.success)` for the view layer.
    /// On failure: drops a `RelogToast(.failure)` and logs in DEBUG.
    /// Either way the main capture state is untouched — re-log is a
    /// side flow.
    func relog(_ source: FoodLog) async {
        let draft = NewFoodLog(
            foodName:        source.foodName,
            imagePath:       source.imagePath,
            imageThumbPath:  source.imageThumbPath,
            calories:        source.calories,
            carbsG:          source.carbsG,
            sugarG:          source.sugarG,
            proteinG:        source.proteinG,
            fatG:            source.fatG,
            fiberG:          source.fiberG,
            benefits:        source.benefits,
            drawbacks:       source.drawbacks,
            nutrients:       source.nutrients,
            coachName:       source.coachName,
            coachAdvice:     source.coachAdvice,
            origin:          .relogged,
            sourceLogId:     source.id
        )
        do {
            let inserted = try await logService.insert(draft)
            #if DEBUG
            NSLog("[Relog] inserted food_logs.id=%@ source=%@",
                  inserted.id.uuidString, source.id.uuidString)
            #endif
            Haptics.success()
            relogToast = RelogToast(foodName: source.foodName, kind: .success)
            // Retention polish — a re-log is still "the user logged
            // today," so it counts toward the local rhythm.
            LoggingRhythmStore.shared.markToday()
        } catch {
            #if DEBUG
            NSLog("[Relog] FAILED for %@: %@",
                  source.foodName, "\(error)")
            #endif
            Haptics.error()
            relogToast = RelogToast(foodName: source.foodName, kind: .failure)
        }
    }

    /// Dismiss the re-log toast — invoked on the auto-fade timer or
    /// when the user starts a new flow.
    func clearRelogToast() {
        relogToast = nil
    }

    // MARK: - Phase 21.5: Daily quest

    /// Fetch today's quest and the completion flag in parallel.
    /// Silent on failure — the quest card hides itself when
    /// `dailyQuest` is nil, which is the safer default than blocking
    /// the rest of Home on a quest-only RPC.
    ///
    /// Called from `CaptureView` on appear, on scenePhase → .active,
    /// and after every successful save (so the card transitions to
    /// its completed state once the post-save evaluator flips the
    /// flag server-side).
    func loadQuest() async {
        do {
            async let questTask = DailyQuestService.shared.todaysQuest(
                timeZone: .current
            )
            async let profileTask = ProfileService().currentProfile()
            let quest = try await questTask
            let profile = try await profileTask
            self.dailyQuest = quest
            self.questCompleted = profile.lastQuestCompleted
        } catch {
            #if DEBUG
            NSLog("[Quest] load FAILED: %@", "\(error)")
            #endif
        }
    }
}

enum SaveError: LocalizedError {
    case imagePreparationFailed

    var errorDescription: String? {
        switch self {
        case .imagePreparationFailed:
            return "Couldn't prepare that photo for saving."
        }
    }
}
