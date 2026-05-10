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

        guard let jpeg = ImagePreparation.compressMain(image) else {
            state = .failed(image, .imageTooLarge)
            return
        }

        #if DEBUG
        let source = lastPhotoSource.rawValue
        print("[Analyze-prep] original=\(image.size.width)x\(image.size.height) compressed-bytes=\(jpeg.count) source=\(source)")
        #endif

        // Phase 16. Fetch the user's last-14-day meals and preferred
        // coaches in parallel with image compression. All queries are
        // best-effort: any failure resolves to an empty array so the
        // analyze call falls back to v1 (no context) shape.
        // Phase 18 adds the recent-moods slice for emotional context.
        async let recentTask: [FoodLog]? = try? history.recentMealsForCoachContext()
        async let prefsTask: [String]? = try? profileService.currentProfile().preferredCoaches
        async let moodsTask: [FoodLog]? = try? history.recentMoodsForCoachContext()
        let recentMeals = (await recentTask) ?? []
        let preferredCoaches = (await prefsTask) ?? []
        let recentMoods = (await moodsTask) ?? []

        do {
            let response = try await analyzer.analyze(
                jpegData: jpeg,
                recentMeals: recentMeals,
                preferredCoaches: preferredCoaches,
                recentMoods: recentMoods
            )
            // Server emits empty-string `fallback` on success (Gemini fills the
            // structured-output field with ""); only a *non-empty* fallback
            // means "no food detected".
            if response.analysis.hasFood {
                Haptics.prepare() // warm the engine for the upcoming save tap
                state = .ready(image, response)
            } else {
                Haptics.warning()
                state = .noFood(image)
            }
        } catch let err as AnalyzeError {
            Haptics.error()
            state = .failed(image, err)
        } catch {
            Haptics.error()
            state = .failed(image, .networkUnavailable)
        }
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

        guard let mainData  = ImagePreparation.compressMain(image),
              let thumbData = ImagePreparation.compressThumbnail(image) else {
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

            // Phase 17: increment the local saves counter (drives
            // permission-sheet timing) and suppress today's reminder
            // for the matching meal window so we don't nudge a user
            // who just logged.
            NotificationGate.recordSave()
            Task.detached {
                await AppForegroundOrchestrator.shared
                    .suppressWindow(for: inserted.eatenAt)
            }

            // Phase 18: auto-transition `.saved` → `.moodPulse` after
            // 1.2s. The SavedConfirmationSheet's appearance choreography
            // (checkmark stamp + haptic) lands at ~t+550ms; 1.2s gives
            // the user a moment with the success state before the
            // mood question lands. If the user closes the success
            // sheet earlier, `discardSaved()` performs the same
            // `.saved → .moodPulse` transition — both paths converge.
            scheduleMoodPulseTransition(for: inserted.id)
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
        if case .moodPulse = state { state = .idle }
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

    /// Schedule the auto-transition `.saved → .moodPulse` 1.2s after
    /// save completes. Guards against the user dismissing the success
    /// sheet themselves (state already moved to `.moodPulse` or further)
    /// or backgrounding before the timer fires (`.idle`). Idempotent.
    private func scheduleMoodPulseTransition(for logId: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 1200)
            guard let self else { return }
            // Only fire if we're still showing the saved state for the
            // same row — any other state means the user (or background
            // hook) moved us along already.
            if case .saved(let i, let r, let log) = self.state, log.id == logId {
                self.state = .moodPulse(i, r, log)
            }
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
