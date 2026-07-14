import SwiftUI

/// Drives the capture → analyze → save flow on the Home tab.
///
/// State graph:
///   .idle → setPhoto → .picked
///   .picked → analyze() → .analyzing → .confirmingName | .noFood | .failed
///   .confirmingName → confirmDetectedName() → .clarifying | .ready
///   .confirmingName → correctNameAndContinue() → .analyzing → .clarifying | .ready
///   .clarifying → refineAnalysis() / acceptOriginalAnalysis() → .ready
///   .ready → save() → .saving → .saved | .saveFailed
///   .saved → discardSaved() → .idle
///   any non-idle → resetToPick / discardCurrent → .idle
///
/// Mandatory name confirmation: every successful first-pass analyze
/// lands in `.confirmingName` (never straight to `.clarifying`/`.ready`).
/// Gemini's self-reported `nameConfidence` is unreliable, so the user
/// confirms the detected food name before we trust the macros. The
/// portion-clarification / ready branching runs *after* the name is
/// confirmed, in `proceedAfterNameConfirmed`.
///
/// While `.analyzing` or `.saving`, a duplicate call is a no-op.
@MainActor
final class CaptureViewModel: ObservableObject {
    enum State {
        case idle
        case picked(UIImage)
        case analyzing(UIImage)
        case noFood(UIImage)
        /// Mandatory name confirmation — first-pass analyze succeeded
        /// and detected food. We pause here on *every* scan so the user
        /// can confirm (or correct) the detected dish name before we
        /// trust Gemini's macros. Carries the first-pass response so
        /// "Looks right" can proceed with no second network call, and so
        /// a failed correction re-pass can fall back to it.
        case confirmingName(UIImage, AnalyzeResponse)
        /// Quantity Clarification — analyze returned a non-empty
        /// `portionAmbiguousItems`. Reached only *after* the name is
        /// confirmed. Carries the (name-confirmed) response so we can
        /// fall back to it if the user dismisses or the refine call fails.
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
            case .confirmingName(let i, _):
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

        /// Mandatory name confirmation.
        var isConfirmingName: Bool {
            if case .confirmingName = self { return true } else { return false }
        }

        /// The whole "the orb is parked at the island, thinking" window: from
        /// the moment analysis starts, through the mandatory name confirmation
        /// and the optional quantity clarification, until the result is ready.
        /// The analyzing animation (genie up → orb hold → genie back) is driven
        /// by THIS, not `isAnalyzing`, so the orb stays docked across those
        /// sub-steps instead of returning + replaying on each transition.
        var isThinking: Bool {
            switch self {
            case .analyzing, .confirmingName, .clarifying: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// On-device pattern insight for the current analysis. Pure
    /// enrichment — never overrides Gemini's macros, just describes
    /// how this meal sits inside the user's history. Populated
    /// immediately after `/analyze` returns (and after a quantity-
    /// clarification refine) so the result UI can render the "Your
    /// Pattern" card without re-running the service on every render.
    /// Reset on every transition back to `.idle` so a stale insight
    /// never leaks into a fresh capture.
    @Published private(set) var patternInsight: FoodPatternInsight? = nil

    /// User-corrected food name from the inline edit affordance on the
    /// analyze result view. When set, overrides `response.analysis.food`
    /// at save time (pre-save edits) and is persisted via
    /// `FoodLogService.updateFoodName` for post-save edits. Cleared on
    /// every transition back to `.idle` so the next capture starts clean.
    @Published private(set) var editedFoodName: String? = nil

    /// Where the current photo came from. Diagnostic-only for now —
    /// drives the `[Analyze-prep]` log line so we can tell whether the
    /// camera or photo-library path is producing oversized uploads.
    enum PhotoSource: String { case camera, library }
    private(set) var lastPhotoSource: PhotoSource = .library

    /// Phase 15 — quick-re-log confirmation toast. Independent of `state`
    /// because a user can fire several re-logs in a row without ever
    /// leaving `.idle`, and we don't want to wedge the main capture flow.
    @Published var relogToast: RelogToast? = nil

    /// Phase 22 — set when /analyze returns a structured 429
    /// scan_limit_reached. The view presents the limit sheet
    /// (Upgrade + Log Manually) keyed on this value; clear with
    /// `clearScanLimit()` after the sheet dismisses. Independent of
    /// `state` because we keep the photo on the canvas (state stays
    /// `.picked`) so the user can immediately fall through to manual
    /// logging without losing context.
    @Published var scanLimitHit: ScanLimitInfo? = nil

    func clearScanLimit() {
        scanLimitHit = nil
    }

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

    // MARK: - Phase 21.13: Scan-flow mood/quest ordering
    //
    // When a scan save completes the daily quest, two follow-ups race
    // for the screen: the quest celebration modal and the mood pulse
    // sheet. The mood sheet is driven by `state.isMoodPulse`, which
    // flips the moment the user dismisses the success confirmation —
    // before the quest evaluator's detached Task has even decided
    // whether the quest fired. Result: mood sometimes lands first,
    // sometimes the modal overlays the sheet.
    //
    // Fix: defer the `.moodPulse` transition until we're sure the
    // celebration won't show (or has dismissed). When the user closes
    // the success sheet while either (a) the celebration is already up
    // or (b) the evaluator is still running, stash the snapshot here
    // and leave state at `.idle`. The celebration's `onDismiss` —
    // or the evaluator's "no quest fired" path — calls
    // `promotePendingMoodPulse()` to enter `.moodPulse` for real.

    /// True from the moment `save()` kicks off the quest evaluator
    /// until it completes. Used by `discardSaved()` to decide whether
    /// the mood pulse can play immediately or needs to be stashed.
    @Published private(set) var questEvaluationInFlight: Bool = false

    private struct PendingMoodPulse {
        let image: UIImage
        let response: AnalyzeResponse
        let log: FoodLog
    }
    private var pendingMoodPulse: PendingMoodPulse? = nil

    /// Promote a stashed `.moodPulse` transition. Called when the quest
    /// celebration modal dismisses, or when the quest evaluator finishes
    /// without firing a celebration. Idempotent — a nil stash is a no-op.
    func promotePendingMoodPulse() {
        guard let pending = pendingMoodPulse else { return }
        pendingMoodPulse = nil
        // Only enter mood if the user is still in an idle-ish background
        // state. If they've already started a new capture flow, skip.
        switch state {
        case .idle:
            state = .moodPulse(pending.image, pending.response, pending.log)
        default:
            break
        }
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
    private let patternInsightService = FoodPatternInsightService()
    /// Phase 16. Optional dependencies that feed coach context into
    /// `/analyze`. Both can fail or no-op without breaking the flow:
    /// the multipart body just omits the corresponding fields and the
    /// server falls back to v1 behavior.
    private let history: MealHistoryService
    private let profileService: ProfileService
    /// FoodOS V2 — shared learning store. Mood notes recorded through
    /// this view-model close the loop on "I'll try this" experiments
    /// armed earlier in Mirror.
    private let feedbackStore: FoodOSMomentFeedbackStore

    init(analyzer: AnalyzeService = AnalyzeService(),
         imageService: FoodImageService = FoodImageService(),
         logService: FoodLogService = FoodLogService(),
         history: MealHistoryService = MealHistoryService(),
         profileService: ProfileService = ProfileService.shared,
         feedbackStore: FoodOSMomentFeedbackStore = .shared) {
        self.analyzer = analyzer
        self.imageService = imageService
        self.logService = logService
        self.history = history
        self.profileService = profileService
        self.feedbackStore = feedbackStore
    }

    /// Pick from the photo library or capture from the camera. Always
    /// transitions to `.picked` regardless of the previous state.
    func setPhoto(_ image: UIImage, source: PhotoSource = .library) {
        Haptics.tap()
        lastPhotoSource = source
        pendingUploadedImage = nil   // fresh photo, don't reuse a prior upload
        pendingVisualDescriptor = nil
        visualSuggestedName = nil
        visualTimesSeen = 0
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
        #if DEBUG
        let analyzeCompressionStart = Date()
        #endif
        let jpeg = await Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }.value
        #if DEBUG
        NSLog("[Perf] analyze image compression %.2fms",
              Date().timeIntervalSince(analyzeCompressionStart) * 1000)
        #endif

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
            guard case .analyzing = state, !Task.isCancelled else { return }
            // Phase 22 — server incremented its counter on success, so
            // bump the local mirror to keep the UI's "scans left" view
            // honest without a /subscription/status round-trip.
            await SubscriptionManager.shared.noteSuccessfulScanLocally()
            // Server emits empty-string `fallback` on success (Gemini fills the
            // structured-output field with ""); only a *non-empty* fallback
            // means "no food detected".
            if response.analysis.hasFood {
                // Mandatory name confirmation — Gemini's self-reported
                // `nameConfidence` is unreliable, so we confirm the
                // detected food name with the user on *every* scan
                // before trusting the macros. The portion-clarification
                // / ready branching happens only after the name is
                // confirmed, inside `proceedAfterNameConfirmed`.
                // Activation / aha — the first analyzed meal is the key
                // new-user milestone; also tracks scan frequency over time.
                AnalyticsService.shared.track(
                    AnalyticsService.Event.mealAnalyzed,
                    ["source": lastPhotoSource.rawValue])
                Haptics.prepare()
                // NOVEL_DIRECTIONS Idea 4 — embed the photo once here (reused
                // at save), log its nearest prior match for on-device threshold
                // tuning, and surface a name suggestion when the read flag is on.
                await noteVisualMemory(for: image)
                state = .confirmingName(image, response)
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
            // Phase 22 — over the daily scan cap. Keep the photo on the
            // canvas (state back to `.picked`) and surface the limit
            // info to the view so it can present the Upgrade /
            // Log Manually sheet. This is NOT a generic failure.
            if case .scanLimitReached(let info) = err {
                Haptics.warning()
                await SubscriptionManager.shared.applyServerLimitReached(
                    limit: info.limit,
                    tier: SubscriptionManager.Tier(rawValue: info.tier) ?? .free,
                    resetsAt: info.resetsAt
                )
                scanLimitHit = info
                state = .picked(image)
                return
            }
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

    // MARK: - Mandatory name confirmation

    /// Shared tail for both name-confirmation outcomes. Given a response
    /// whose *name* the user has accepted (either as-detected or after a
    /// correction re-pass), decide whether we still owe the Quantity
    /// Clarification step (non-empty `portionAmbiguousItems`) or can go
    /// straight to the result. Computes the on-device pattern insight
    /// before flipping to `.ready` so the result view's first render
    /// carries the "Your Pattern" card — mirroring the original inline
    /// logic this replaced in `analyze()`.
    private func proceedAfterNameConfirmed(image: UIImage,
                                           response: AnalyzeResponse) {
        let ambiguous = response.analysis.portionAmbiguousItems ?? []
        if !ambiguous.isEmpty {
            Haptics.prepare()
            state = .clarifying(image, response, ambiguous)
        } else {
            Haptics.prepare() // warm the engine for the upcoming save tap
            patternInsight = patternInsightService.insight(for: response)
            state = .ready(image, response)
        }
    }

    /// "Looks right" on the name-confirmation sheet. The detected name
    /// is trusted as-is, so we proceed with the first-pass response —
    /// no second network call and no scan credit consumed. No-op outside
    /// `.confirmingName`.
    func confirmDetectedName() {
        guard case .confirmingName(let image, let response) = state else { return }
        Haptics.tap()
        proceedAfterNameConfirmed(image: image, response: response)
    }

    /// "Not correct" on the name-confirmation sheet: the user typed (or
    /// quick-picked) the real dish name. Re-run `/analyze` with
    /// `corrected_food_name` so calories/macros recompute for the right
    /// dish. The server treats this as a refinement and does NOT count
    /// it against the daily scan limit — so, exactly like
    /// `reanalyzeWithCorrectedName` and the quantity-refine path, we
    /// deliberately do NOT call `noteSuccessfulScanLocally()` here.
    ///
    /// On success: stamp `editedFoodName` with the corrected name so the
    /// rest of the flow (save, display) treats it as authoritative, then
    /// route through `proceedAfterNameConfirmed` (which still honors any
    /// portion ambiguity in the refined response).
    ///
    /// On failure: fall back to the original first-pass response — don't
    /// punish the user for a network blip while correcting a name.
    func correctNameAndContinue(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let image: UIImage
        let originalResponse: AnalyzeResponse
        switch state {
        case .confirmingName(let i, let r):
            image = i
            originalResponse = r
        default:
            #if DEBUG
            NSLog("[NameConfirm] correctNameAndContinue ignored — state=%@",
                  Self.stateName(state))
            #endif
            return
        }

        editedFoodName = trimmed
        state = .analyzing(image) // re-show the analyzing UI over the photo

        let jpeg = await Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }.value
        guard case .analyzing = state, !Task.isCancelled else { return }

        guard let jpeg else {
            #if DEBUG
            NSLog("[NameConfirm] compression FAILED; falling back to original response")
            #endif
            proceedAfterNameConfirmed(image: image, response: originalResponse)
            return
        }

        let context = await fetchContextForAnalyze()

        do {
            let refined = try await analyzer.analyze(
                jpegData: jpeg,
                recentMeals: context.recentMeals,
                preferredCoaches: context.preferredCoaches,
                recentMoods: context.recentMoods,
                correctedFoodName: trimmed
            )
            guard case .analyzing = state, !Task.isCancelled else { return }
            #if DEBUG
            NSLog("[NameConfirm] succeeded — corrected='%@' refined food=%@ calories=%@ (orig calories=%@)",
                  trimmed,
                  refined.analysis.food ?? "<nil>",
                  refined.analysis.calories.map { "\($0)" } ?? "<nil>",
                  originalResponse.analysis.calories.map { "\($0)" } ?? "<nil>")
            #endif
            // Prefer the refined response only when it still detected
            // food; otherwise keep the original so the user doesn't lose
            // their result over a flaky re-pass.
            let resolved = refined.analysis.hasFood ? refined : originalResponse
            proceedAfterNameConfirmed(image: image, response: resolved)
        } catch {
            #if DEBUG
            NSLog("[NameConfirm] reanalyze FAILED, falling back to original: %@", "\(error)")
            #endif
            proceedAfterNameConfirmed(image: image, response: originalResponse)
        }
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
        case .confirmingName: return ".confirmingName"
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
            patternInsight = patternInsightService.insight(for: originalResponse)
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
            guard case .analyzing = state, !Task.isCancelled else { return }
            #if DEBUG
            NSLog("[Clarify] refineAnalysis succeeded — refined food=%@ calories=%@ (original calories=%@)",
                  refined.analysis.food ?? "<nil>",
                  refined.analysis.calories.map { "\($0)" } ?? "<nil>",
                  originalResponse.analysis.calories.map { "\($0)" } ?? "<nil>")
            #endif
            Haptics.prepare()
            // If the refine pass somehow lost food detection, prefer
            // the original — the user already saw it succeed once.
            let resolved = refined.analysis.hasFood ? refined : originalResponse
            patternInsight = patternInsightService.insight(for: resolved)
            state = .ready(image, resolved)
        } catch {
            #if DEBUG
            NSLog("[Clarify] refine FAILED, falling back to original: %@", "\(error)")
            #endif
            patternInsight = patternInsightService.insight(for: originalResponse)
            state = .ready(image, originalResponse)
        }
    }

    // MARK: - Uncertainty-aware naming

    /// User picked a name suggestion (or typed a custom one) from the
    /// uncertainty UI on the `.ready` screen. Re-run `/analyze` with
    /// `corrected_food_name` so calories/macros recompute for the
    /// corrected dish. The server treats this as a refinement and does
    /// NOT count it against the daily scan limit (mirrors the
    /// quantity-refinement path).
    ///
    /// On success: stay in `.ready` with the recomputed response. We
    /// also stamp `editedFoodName` with the corrected name so the
    /// rest of the flow (save, display) treats it as authoritative —
    /// matching what the user picked even if Gemini's `food` echoes
    /// back slightly different copy.
    ///
    /// On failure: fall back to the original response — don't punish
    /// the user for a network blip when correcting a name.
    func reanalyzeWithCorrectedName(_ correctedName: String) async {
        let trimmed = correctedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Accept from `.ready` (the typical entry point) and also from
        // a transient `.analyzing` if a rapid follow-up tap lands while
        // a previous correction is in flight — the user's intent is the
        // same: the dish is `trimmed`.
        let image: UIImage
        let originalResponse: AnalyzeResponse
        switch state {
        case .ready(let i, let r):
            image = i
            originalResponse = r
        default:
            #if DEBUG
            NSLog("[NameFix] reanalyzeWithCorrectedName ignored — state=%@",
                  Self.stateName(state))
            #endif
            return
        }

        editedFoodName = trimmed
        state = .analyzing(image)

        let jpeg = await Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }.value
        guard case .analyzing = state, !Task.isCancelled else { return }

        guard let jpeg else {
            #if DEBUG
            NSLog("[NameFix] compression FAILED; falling back to original response")
            #endif
            patternInsight = patternInsightService.insight(for: originalResponse)
            state = .ready(image, originalResponse)
            return
        }

        let context = await fetchContextForAnalyze()

        do {
            let refined = try await analyzer.analyze(
                jpegData: jpeg,
                recentMeals: context.recentMeals,
                preferredCoaches: context.preferredCoaches,
                recentMoods: context.recentMoods,
                correctedFoodName: trimmed
            )
            guard case .analyzing = state, !Task.isCancelled else { return }
            #if DEBUG
            NSLog("[NameFix] succeeded — corrected='%@' refined food=%@ calories=%@ (orig calories=%@)",
                  trimmed,
                  refined.analysis.food ?? "<nil>",
                  refined.analysis.calories.map { "\($0)" } ?? "<nil>",
                  originalResponse.analysis.calories.map { "\($0)" } ?? "<nil>")
            #endif
            Haptics.prepare()
            // Prefer the refined response only when it still detected
            // food; otherwise keep the original so the user doesn't
            // lose their result over a flaky re-pass.
            let resolved = refined.analysis.hasFood ? refined : originalResponse
            patternInsight = patternInsightService.insight(for: resolved)
            state = .ready(image, resolved)
        } catch {
            #if DEBUG
            NSLog("[NameFix] reanalyze FAILED, falling back to original: %@", "\(error)")
            #endif
            patternInsight = patternInsightService.insight(for: originalResponse)
            state = .ready(image, originalResponse)
        }
    }

    /// User dismissed the clarification sheet without adjusting —
    /// keep the first-pass analysis. Also called when the sheet is
    /// drag-dismissed.
    func acceptOriginalAnalysis() {
        guard case .clarifying(let image, let response, _) = state else { return }
        Haptics.prepare()
        patternInsight = patternInsightService.insight(for: response)
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
    /// Storage objects from a save attempt whose image upload succeeded but
    /// whose row insert failed. `retrySave()` reuses these instead of
    /// uploading fresh copies, so a flaky insert can't orphan a new image on
    /// every retry. Cleared once the row commits or the meal is abandoned.
    private var pendingUploadedImage: UploadedImage? = nil

    /// User-facing copy for a failed save. Never surfaces a raw Supabase /
    /// Postgres error string — those belong in the logs, not on screen. Maps
    /// known cases to friendly copy and everything else to a safe generic.
    static func friendlySaveMessage(for error: Error) -> String {
        if let save = error as? SaveError, let desc = save.errorDescription {
            return desc
        }
        if error is URLError {
            return "Couldn't save. Check your connection and try again."
        }
        return "Something went wrong saving your meal. Please try again."
    }

    // MARK: - Visual Food Memory (NOVEL_DIRECTIONS Idea 4)

    /// Name suggested from a confident visual match to a past meal. Only ever
    /// set when the opt-in read flag is on AND the match is within the tuned
    /// threshold; nil otherwise. The UI may offer it as a non-destructive
    /// pre-fill for the name-confirm step.
    @Published private(set) var visualSuggestedName: String? = nil

    /// How many past meals look like the analyzed photo (the "you've had this N
    /// times" signal). Only meaningful when the read flag is on and the
    /// threshold is tuned; 0 otherwise.
    @Published private(set) var visualTimesSeen: Int = 0

    /// The analyzed photo's feature-print, stashed at analyze time so `save()`
    /// records it without a second Vision pass.
    private var pendingVisualDescriptor: VisualDescriptor? = nil

    /// Embed the analyzed photo once, stash it for `save()`, and set a name
    /// suggestion when the store recognizes the dish. Recognition is
    /// self-calibrating and self-gating: `VisualFoodMemory` learns the user's
    /// own "same dish" threshold from their repeat history and stays silent
    /// until it has enough evidence, so no manual flag is needed. Fully
    /// best-effort: a nil embedding silently skips everything.
    private func noteVisualMemory(for image: UIImage) async {
        visualSuggestedName = nil
        visualTimesSeen = 0
        pendingVisualDescriptor = nil
        guard let descriptor = await VisionMealEmbedder.embed(image) else { return }
        pendingVisualDescriptor = descriptor
        if let name = await VisualFoodMemory.shared.suggestedName(for: descriptor) {
            visualSuggestedName = name
            visualTimesSeen = await VisualFoodMemory.shared.timesSeen(descriptor)
        }
        #if DEBUG
        let nearest = await VisualFoodMemory.shared.nearestMatch(to: descriptor)
        let learned = await VisualFoodMemory.shared.learnedThreshold
        NSLog("[VisualMemory] nearest=%@ dist=%.2f learnedThreshold=%@ suggested=%@",
              nearest?.entry.foodName ?? "none",
              nearest?.distance ?? -1,
              learned.map { String(format: "%.2f", $0) } ?? "nil (need more repeats)",
              visualSuggestedName ?? "nil")
        #endif
    }

    func save() async {
        guard case .ready(let image, let response) = state else { return }
        state = .saving(image, response)

        // Generate main + thumb JPEGs concurrently on a background
        // thread; the two passes are independent and CPU-heavy enough
        // (HEIC → JPEG re-encode at two sizes) that running them on the
        // MainActor visibly hitched the "Save to today" press response.
        let mainTask = Task.detached(priority: .userInitiated) {
            #if DEBUG
            let start = Date()
            defer {
                NSLog("[Perf] save main compression %.2fms",
                      Date().timeIntervalSince(start) * 1000)
            }
            #endif
            return ImagePreparation.compressMain(image)
        }
        let thumbTask = Task.detached(priority: .userInitiated) {
            #if DEBUG
            let start = Date()
            defer {
                NSLog("[Perf] save thumbnail compression %.2fms",
                      Date().timeIntervalSince(start) * 1000)
            }
            #endif
            return ImagePreparation.compressThumbnail(image)
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
            let uploaded: UploadedImage
            if let existing = pendingUploadedImage {
                // A prior attempt already uploaded these objects but the row
                // insert failed; reuse them so retrying doesn't orphan a fresh
                // upload on every attempt.
                uploaded = existing
            } else {
                uploaded = try await imageService.uploadMealImages(
                    mainData: mainData,
                    thumbnailData: thumbData
                )
                pendingUploadedImage = uploaded
            }
            guard case .saving = state, !Task.isCancelled else { return }
            #if DEBUG
            NSLog("[Save] uploaded main_path=%@ thumb_path=%@",
                  uploaded.mainPath, uploaded.thumbPath)
            #endif

            let resolvedFoodName = editedFoodName
                ?? response.analysis.food
                ?? "Unknown"
            let draft = NewFoodLog(
                foodName:        resolvedFoodName,
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
            guard case .saving = state, !Task.isCancelled else { return }
            pendingUploadedImage = nil   // row committed, nothing to reuse/orphan

            // NOVEL_DIRECTIONS Idea 4 — remember this meal by its photo,
            // on-device (Vision feature-print → local store, zero egress), so
            // future scans can recognize the dish. Reuse the descriptor embedded
            // at analyze time (no second Vision pass); embed here only as a
            // fallback if analyze didn't produce one. Best-effort + detached so
            // it never blocks or fails the save.
            let stashedDescriptor = pendingVisualDescriptor
            pendingVisualDescriptor = nil
            Task.detached(priority: .utility) { [resolvedFoodName] in
                let descriptor: VisualDescriptor?
                if let stashedDescriptor {
                    descriptor = stashedDescriptor
                } else {
                    descriptor = await VisionMealEmbedder.embed(image)
                }
                if let descriptor {
                    await VisualFoodMemory.shared.record(
                        foodName: resolvedFoodName, descriptor: descriptor, at: Date()
                    )
                }
            }
            #if DEBUG
            NSLog("[Save] inserted food_logs.id=%@ user_id=%@",
                  inserted.id.uuidString, inserted.userId.uuidString)
            NSLog("[Save] macros: cal=%.0f carbs=%.1fg sugar=%.1fg protein=%@ fat=%@ fiber=%@",
                  inserted.calories, inserted.carbsG, inserted.sugarG,
                  inserted.proteinG.map { String(format: "%.1fg", $0) } ?? "nil",
                  inserted.fatG.map     { String(format: "%.1fg", $0) } ?? "nil",
                  inserted.fiberG.map   { String(format: "%.1fg", $0) } ?? "nil")
            #endif

            // Phase 21.13 — DO NOT transition to `.saved` yet. The
            // SavedConfirmationSheet binds to `.saved`, and the quest
            // evaluator (below) needs to settle first so the
            // celebration modal can land BEFORE the success sheet,
            // not race it. We stay in `.saving` (spinner still visible)
            // for the ~few hundred ms the evaluator takes, then
            // transition with quest state in hand.

            // Retention polish — mark today as logged in the local
            // rhythm store so the Home daily check-in card reflects
            // continuity without a server round-trip. Idempotent: the
            // first save of the day writes; subsequent saves on the
            // same local calendar day are a no-op.
            LoggingRhythmStore.shared.markToday()

            // On-device belief update. Best-effort: the belief store
            // is local and synchronous, but a future failure inside
            // `update(from:)` must never propagate or back out the row
            // that already landed in Supabase. The store itself logs
            // in DEBUG on its own — we don't need a second catch here.
            // Belief data is used only for pattern insights; it never
            // mutates Gemini's response or the saved macros.
            LocalNutritionBeliefStore.shared.update(from: inserted)

            // Broadcast a "food log changed" event so the Mirror tab
            // (and any future passive listener) can refresh without
            // coupling to this call site. Posted only after a
            // successful insert.
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)

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
            // Streak is independent of the success-sheet handoff —
            // fire it detached so it doesn't add latency.
            Task {
                _ = try? await StreakService.shared.recordLog(
                    at: inserted.eatenAt
                )
            }

            // Phase 21.13 — evaluate the quest INLINE before flipping
            // to `.saved`. If the quest just fired we set
            // `justCompletedQuest` first; then the state transition
            // happens with the celebration already pending. The view
            // gates the SavedConfirmationSheet on
            // `justCompletedQuest == nil` so the celebration shows
            // FIRST, the success sheet appears only after the modal
            // dismisses, and the mood pulse follows the success sheet.
            questEvaluationInFlight = true
            let evaluation = try? await DailyQuestService.shared
                .evaluateQuestProgress(after: inserted)
            let questFired = (evaluation?.questCompleted == true)
                          && (evaluation?.rewardCopy != nil)
            if questFired, let reward = evaluation?.rewardCopy {
                recordQuestCompletion(rewardCopy: reward)
            }

            // NOW transition to `.saved`. The success-sheet binding
            // is gated on `justCompletedQuest == nil`, so when the
            // quest fired, the sheet stays hidden until the modal
            // dismisses; when it didn't, the sheet rises immediately.
            //
            // Phase 13: success haptic fires from
            // `SavedConfirmationSheet` when the checkmark hits full
            // scale, so it lands with the visual.
            state = .saved(image, response, inserted)
            AnalyticsService.shared.track(AnalyticsService.Event.mealSaved)
            questEvaluationInFlight = false

            // Refresh the local quest cache so the Home card morphs
            // in place rather than waiting for the next foreground.
            // Detached — purely a UI mirror; doesn't gate any modal.
            Task { [weak self] in
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
    ///
    /// Phase 21.13 — when the quest celebration is showing OR the
    /// evaluator is still running, stash the snapshot and drop to
    /// `.idle` instead. The stash is later promoted to `.moodPulse`
    /// either by the modal's `onDismiss` (quest fired) or, when no quest
    /// fires, by `promotePendingMoodPulse()` off the success-sheet close.
    func discardSaved() {
        guard case .saved(let image, let response, let log) = state else {
            return
        }
        let questPending = (justCompletedQuest != nil) || questEvaluationInFlight
        if questPending {
            pendingMoodPulse = PendingMoodPulse(
                image: image, response: response, log: log
            )
            state = .idle
        } else {
            state = .moodPulse(image, response, log)
        }
    }

    // MARK: - Phase 18: Mood pulse

    /// User tapped one of the three emojis. Transitions to `.idle`
    /// optimistically (the sheet has its own confirmation animation
    /// before it dismisses) and writes the mood in the background.
    /// Failures are silent — mood is enrichment, not critical — but
    /// logged in DEBUG.
    func recordMood(_ mood: FoodLog.Mood) async {
        guard case .moodPulse(_, _, let log) = state else { return }
        editedFoodName = nil
        patternInsight = nil
        // Late-bind the mood into the local belief so the next time
        // this food is scanned, the "Your Pattern" mood note can
        // reflect what the user actually felt. Idempotent within the
        // same pulse — `recordMoodIfKnown` only updates the histogram.
        LocalNutritionBeliefStore.shared.recordMoodIfKnown(
            mood, for: log.foodName
        )
        state = .idle
        do {
            _ = try await logService.setMood(mood, on: log.id)
            // Mirror's dominant-mood insights read from the same
            // row we just patched; nudge subscribers so the tab and
            // Home preview refresh without waiting for the next
            // foreground.
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
            #if DEBUG
            NSLog("[Mood] set log=%@ mood=%@",
                  log.id.uuidString, mood.rawValue)
            #endif
            // FoodOS Feedback V2: a fresh mood note resolves any
            // pending "I'll try this" experiment. We deliberately
            // do this *after* the DB patch succeeds — a network
            // failure must not advance the learning state. The
            // store call is local-only and never throws, and a nil
            // return (no active experiment) is the common case.
            _ = feedbackStore.resolveExperiment(
                for: log, mood: mood, now: Date()
            )
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
            editedFoodName = nil
            patternInsight = nil
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
            editedFoodName = nil
            patternInsight = nil
            state = .idle
        default:
            break
        }
    }

    /// User wants to start over with a new photo. Goes back to `.idle` so
    /// the dashed drop zone shows the empty state again and the picker
    /// can be re-presented from there.
    func resetToPick() {
        editedFoodName = nil
        patternInsight = nil
        pendingUploadedImage = nil
        pendingVisualDescriptor = nil
        visualSuggestedName = nil
        visualTimesSeen = 0
        state = .idle
    }

    /// Same as `resetToPick` for now; preserved as a separate entry point
    /// in case the design diverges (e.g. cancel-without-resetting).
    func discardCurrent() {
        editedFoodName = nil
        patternInsight = nil
        pendingUploadedImage = nil
        pendingVisualDescriptor = nil
        visualSuggestedName = nil
        visualTimesSeen = 0
        state = .idle
    }

    /// User corrected the food name from the analyze result view. For
    /// pre-save edits, just stash it on the view model so `save()` picks
    /// it up. For post-save edits (.saved/.moodPulse), patch the row
    /// immediately via FoodLogService. Local-first: the UI override
    /// reads instantly; a network failure is silent in DEBUG and leaves
    /// the local edit in place (the user sees their correction even
    /// though it didn't persist — acceptable for v1).
    func applyFoodNameEdit(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editedFoodName = trimmed

        let savedLogId: UUID?
        switch state {
        case .saved(_, _, let log), .moodPulse(_, _, let log):
            savedLogId = log.id
        default:
            savedLogId = nil
        }

        guard let logId = savedLogId else { return }
        Task { [logService] in
            do {
                _ = try await logService.updateFoodName(trimmed, on: logId)
                #if DEBUG
                NSLog("[FoodLog] updated food_name for log %@ to '%@'",
                      logId.uuidString, trimmed)
                #endif
            } catch {
                #if DEBUG
                NSLog("[FoodLog] updateFoodName FAILED log=%@ err=%@",
                      logId.uuidString, "\(error)")
                #endif
            }
        }
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
            // Quick-log adoption — measures the surfaced re-log path (Tier 1).
            AnalyticsService.shared.track(AnalyticsService.Event.mealRelogged)
            // Retention polish — a re-log is still "the user logged
            // today," so it counts toward the local rhythm.
            LoggingRhythmStore.shared.markToday()
            // Re-logs feed the belief store too — the user ate this
            // again, so pattern signals (frequency, mood) reinforce.
            // Macros stay exactly as the source row recorded them; no
            // estimate adjustment ever happens here.
            LocalNutritionBeliefStore.shared.update(from: inserted)

            // Same broadcast as the analyzed-save path — a re-log
            // adds a fresh `food_logs` row, so the Mirror tab should
            // refresh next time it's on screen.
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
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

    // MARK: - Phase 23: Vault

    /// Save the currently-analyzed meal to the durable Vault. Independent
    /// of the log-save path — the user can vault a food without logging it,
    /// or after logging it. Best-effort: never disturbs the main capture
    /// state.
    ///
    /// From `.saved` / `.moodPulse` (already logged) it snapshots the
    /// inserted `food_logs` row directly (photo + id already exist, zero
    /// upload). From `.ready` / `.saving` / `.saveFailed` it ensures the
    /// photo is uploaded once — reusing / seeding `pendingUploadedImage`
    /// so a later "Save to today" doesn't re-upload — and inserts a vault
    /// item with no source log yet.
    @discardableResult
    func saveCurrentToVault() async -> VaultStore.AddOutcome {
        switch state {
        case .saved(_, _, let log), .moodPulse(_, _, let log):
            return await vaultLoggedMeal(log)
        case .ready(let image, let response),
             .saving(let image, let response),
             .saveFailed(let image, let response, _):
            return await vaultUnloggedMeal(image: image, response: response)
        default:
            return .failed
        }
    }

    private func vaultLoggedMeal(_ log: FoodLog) async -> VaultStore.AddOutcome {
        if VaultStore.shared.isInVault(foodName: log.foodName) { return .alreadySaved }
        let outcome = await VaultStore.shared.add(from: log)
        emitVaultHaptic(outcome)
        return outcome
    }

    private func vaultUnloggedMeal(image: UIImage,
                                   response: AnalyzeResponse) async -> VaultStore.AddOutcome {
        let resolvedFoodName = editedFoodName ?? response.analysis.food ?? "Unknown"
        if VaultStore.shared.isInVault(foodName: resolvedFoodName) { return .alreadySaved }

        let uploaded = await ensureUploadedImage(image)

        let draft = NewVaultItem(
            foodName:       resolvedFoodName,
            imagePath:      uploaded?.mainPath,
            imageThumbPath: uploaded?.thumbPath,
            calories:       response.analysis.calories ?? 0,
            carbsG:         response.analysis.carbs ?? 0,
            sugarG:         response.analysis.sugar ?? 0,
            proteinG:       response.analysis.protein,
            fatG:           response.analysis.fat,
            fiberG:         response.analysis.fiber,
            benefits:       response.analysis.benefits ?? [],
            drawbacks:      response.analysis.drawbacks ?? [],
            nutrients:      response.analysis.nutrients ?? [],
            coachName:      response.coach,
            coachAdvice:    response.analysis.coachAdvice,
            sourceLogId:    nil
        )
        let outcome = await VaultStore.shared.add(draft)
        emitVaultHaptic(outcome)
        return outcome
    }

    /// Ensure the current photo is in Storage, reusing a prior upload when
    /// one exists and caching a fresh one in `pendingUploadedImage` so a
    /// subsequent `save()` doesn't upload it again. Returns nil if the
    /// compression or upload fails; the vault item is then saved without a
    /// photo rather than failing outright.
    private func ensureUploadedImage(_ image: UIImage) async -> UploadedImage? {
        if let existing = pendingUploadedImage { return existing }
        let mainTask = Task.detached(priority: .userInitiated) {
            ImagePreparation.compressMain(image)
        }
        let thumbTask = Task.detached(priority: .userInitiated) {
            ImagePreparation.compressThumbnail(image)
        }
        guard let mainData = await mainTask.value,
              let thumbData = await thumbTask.value else { return nil }
        do {
            let uploaded = try await imageService.uploadMealImages(
                mainData: mainData, thumbnailData: thumbData
            )
            pendingUploadedImage = uploaded
            return uploaded
        } catch {
            #if DEBUG
            NSLog("[Vault] image upload FAILED: %@", "\(error)")
            #endif
            return nil
        }
    }

    private func emitVaultHaptic(_ outcome: VaultStore.AddOutcome) {
        switch outcome {
        case .saved, .alreadySaved: Haptics.success()
        case .failed:               Haptics.error()
        }
    }

    /// Re-log a Vault item into today. Mirrors `relog(_:)` but sources the
    /// meal from a `SavedFood` snapshot instead of a `food_logs` row.
    /// Reuses the same stored photo (no re-upload) and freezes the saved
    /// macros. Drops a `RelogToast` for the view layer; the main capture
    /// state is untouched.
    func relogFromVault(_ item: SavedFood) async {
        do {
            let inserted = try await logService.insert(item.newFoodLogForRelog())
            #if DEBUG
            NSLog("[Vault] relogged food_logs.id=%@ from vault=%@",
                  inserted.id.uuidString, item.id.uuidString)
            #endif
            Haptics.success()
            relogToast = RelogToast(foodName: item.foodName, kind: .success)
            AnalyticsService.shared.track(AnalyticsService.Event.mealRelogged)
            LoggingRhythmStore.shared.markToday()
            LocalNutritionBeliefStore.shared.update(from: inserted)
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        } catch {
            #if DEBUG
            NSLog("[Vault] relog FAILED for %@: %@", item.foodName, "\(error)")
            #endif
            Haptics.error()
            relogToast = RelogToast(foodName: item.foodName, kind: .failure)
        }
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
            async let profileTask = ProfileService.shared.currentProfile()
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
