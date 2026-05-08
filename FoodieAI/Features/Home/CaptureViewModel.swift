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
        case saveFailed(UIImage, AnalyzeResponse, Error)
        case failed(UIImage, AnalyzeError)

        var image: UIImage? {
            switch self {
            case .idle: return nil
            case .picked(let i), .analyzing(let i), .noFood(let i):
                return i
            case .ready(let i, _), .saving(let i, _), .failed(let i, _):
                return i
            case .saved(let i, _, _), .saveFailed(let i, _, _):
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
    }

    @Published private(set) var state: State = .idle

    private let analyzer: AnalyzeService
    private let imageService: FoodImageService
    private let logService: FoodLogService

    /// Compressed JPEG bytes captured during `analyze()`. Reused by `save()`
    /// to avoid a second compression pass. Cleared on every `setPhoto`.
    private var lastJPEG: Data?

    init(analyzer: AnalyzeService = AnalyzeService(),
         imageService: FoodImageService = FoodImageService(),
         logService: FoodLogService = FoodLogService()) {
        self.analyzer = analyzer
        self.imageService = imageService
        self.logService = logService
    }

    /// Pick from the photo library or capture from the camera. Always
    /// transitions to `.picked` regardless of the previous state.
    func setPhoto(_ image: UIImage) {
        lastJPEG = nil
        state = .picked(image)
    }

    /// Run /analyze on the current photo. No-op if there's no image, or if
    /// a request is already in flight.
    func analyze() async {
        guard let image = state.image else { return }
        if case .analyzing = state { return }

        state = .analyzing(image)

        guard let jpeg = ImagePreparation.compress(image) else {
            state = .failed(image, .imageTooLarge)
            return
        }
        self.lastJPEG = jpeg

        do {
            let response = try await analyzer.analyze(jpegData: jpeg)
            // Server emits empty-string `fallback` on success (Gemini fills the
            // structured-output field with ""); only a *non-empty* fallback
            // means "no food detected".
            if response.analysis.hasFood {
                state = .ready(image, response)
            } else {
                state = .noFood(image)
            }
        } catch let err as AnalyzeError {
            state = .failed(image, err)
        } catch {
            state = .failed(image, .networkUnavailable)
        }
    }

    /// Save the current `.ready` analysis. No-op if not in `.ready` state, or
    /// if a save is already in flight.
    ///
    /// Pipeline:
    ///   1. Upload the JPEG bytes captured during analyze() to Supabase
    ///      Storage at `{auth.uid()}/{uuid}.jpg`. Recompresses if the
    ///      bytes were dropped (e.g. cold restart).
    ///   2. Build a `NewFoodLog` from the analysis. Note: NO `user_id` —
    ///      the DB default + RLS handle that.
    ///   3. Insert into `food_logs`.
    ///   4. Transition to `.saved` (UI shows the confirmation sheet).
    func save() async {
        guard case .ready(let image, let response) = state else { return }
        state = .saving(image, response)

        let jpeg: Data
        if let cached = lastJPEG {
            jpeg = cached
        } else if let recompressed = ImagePreparation.compress(image) {
            jpeg = recompressed
        } else {
            state = .saveFailed(image, response, SaveError.imagePreparationFailed)
            return
        }

        do {
            let path = try await imageService.upload(jpegData: jpeg)
            #if DEBUG
            NSLog("[Save] uploaded image_path=%@", path)
            #endif

            let draft = NewFoodLog(
                foodName:    response.analysis.food ?? "Unknown",
                imagePath:   path,
                calories:    response.analysis.calories ?? 0,
                carbsG:      response.analysis.carbs ?? 0,
                sugarG:      response.analysis.sugar ?? 0,
                proteinG:    nil,
                fatG:        nil,
                fiberG:      nil,
                benefits:    response.analysis.benefits ?? [],
                drawbacks:   response.analysis.drawbacks ?? [],
                nutrients:   response.analysis.nutrients ?? [],
                coachName:   response.coach,
                coachAdvice: response.analysis.coachAdvice
            )

            let inserted = try await logService.insert(draft)
            #if DEBUG
            NSLog("[Save] inserted food_logs.id=%@ user_id=%@",
                  inserted.id.uuidString, inserted.userId.uuidString)
            #endif

            state = .saved(image, response, inserted)
        } catch {
            #if DEBUG
            NSLog("[Save] FAILED: %@", "\(error)")
            #endif
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

    /// Dismiss the saved-confirmation sheet and clear back to `.idle`.
    func discardSaved() {
        state = .idle
        lastJPEG = nil
    }

    /// User wants to start over with a new photo. Goes back to `.idle` so
    /// the dashed drop zone shows the empty state again and the picker
    /// can be re-presented from there.
    func resetToPick() {
        lastJPEG = nil
        state = .idle
    }

    /// Same as `resetToPick` for now; preserved as a separate entry point
    /// in case the design diverges (e.g. cancel-without-resetting).
    func discardCurrent() {
        lastJPEG = nil
        state = .idle
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
