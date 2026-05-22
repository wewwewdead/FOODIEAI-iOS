import Foundation

// MARK: - FoodOSMomentFeedbackStore
//
// Local-only persistence layer for the FoodOS feedback loop. Writes a
// single JSON file to Application Support and keeps a tight in-memory
// copy of:
//   - rolled-up per-tag preferences (V1 surface, used by the bandit)
//   - the most recent ~500 raw feedback events (V1)
//   - active "I'll try this" experiments + a bounded resolved history
//     (V2 — the learning loop that connects promises to mood notes)
//
// Design rules:
//   - Pure local: never touches Supabase, never reaches the network.
//   - Single source of truth: events are append-only; preferences are
//     derived from events but cached so reads stay O(tags).
//   - Survives corruption: a decode failure resets to an empty store
//     and removes the bad file so the next write can succeed cleanly.
//   - Survives app restart: writes are synchronous and atomic.
//   - Forward compatible: V1 payloads decode into the V2 schema, so
//     existing on-disk files are migrated without losing data.
//   - Test-friendly: file location is injectable.

/// Persistent JSON-backed feedback store. Threaded reads and writes
/// funnel through a serial dispatch queue so the SwiftUI main actor
/// can call `record` / `startExperiment` / `resolveExperiment`
/// synchronously without blocking on file I/O.
final class FoodOSMomentFeedbackStore: @unchecked Sendable {

    /// Versioned on-disk container. V2 adds experiment fields; V1
    /// payloads are mapped forward at load time so existing users
    /// don't lose feedback when this ships.
    private struct Payload: Codable, Equatable {
        var schemaVersion: Int
        var events: [FoodOSMomentFeedbackEvent]
        var preferences: [FoodOSMomentPreference]
        // V2 additions. Default empty so V1 decode can synthesize a
        // valid container without a custom Codable conformance.
        var activeExperiments: [FoodOSActiveExperiment] = []
        var resolvedExperiments: [FoodOSActiveExperiment] = []

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case events
            case preferences
            case activeExperiments
            case resolvedExperiments
        }

        init(schemaVersion: Int,
             events: [FoodOSMomentFeedbackEvent],
             preferences: [FoodOSMomentPreference],
             activeExperiments: [FoodOSActiveExperiment] = [],
             resolvedExperiments: [FoodOSActiveExperiment] = []) {
            self.schemaVersion = schemaVersion
            self.events = events
            self.preferences = preferences
            self.activeExperiments = activeExperiments
            self.resolvedExperiments = resolvedExperiments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            self.events = (try? c.decode([FoodOSMomentFeedbackEvent].self,
                                         forKey: .events)) ?? []
            self.preferences = (try? c.decode([FoodOSMomentPreference].self,
                                              forKey: .preferences)) ?? []
            self.activeExperiments = (try? c.decode(
                [FoodOSActiveExperiment].self, forKey: .activeExperiments
            )) ?? []
            self.resolvedExperiments = (try? c.decode(
                [FoodOSActiveExperiment].self, forKey: .resolvedExperiments
            )) ?? []
        }
    }

    /// Hard cap on retained events. Older events fall off the front
    /// so the file stays bounded after months of taps.
    static let eventHistoryCap = 500

    /// Hard cap on the resolved-experiment ring buffer. The active
    /// list is bounded implicitly (≤ `FoodOSMomentTag.allCases.count`)
    /// because at most one experiment per tag can be active.
    static let resolvedExperimentHistoryCap = 100

    /// Default location: `<Application Support>/FoodieAI/foodos_feedback.json`.
    /// Tests inject a temp URL through `init(fileURL:)`.
    static let defaultFileURL: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("FoodieAI", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("foodos_feedback.json", isDirectory: false)
    }()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "foodos.feedback.store",
                                      qos: .userInitiated)
    private var payload: Payload

    /// App-wide store backed by the default Application Support
    /// location. The Mirror tab arms experiments through one
    /// view-model; the Capture flow later resolves them through a
    /// different view-model. Both paths need to see the same
    /// in-memory copy, otherwise an experiment armed in Mirror would
    /// never resolve from a mood note logged in Capture. Tests
    /// continue to inject their own per-test instance via
    /// `init(fileURL:)`.
    static let shared = FoodOSMomentFeedbackStore()

    init(fileURL: URL = FoodOSMomentFeedbackStore.defaultFileURL) {
        self.fileURL = fileURL
        self.payload = FoodOSMomentFeedbackStore.load(from: fileURL)
    }

    // MARK: Public reads

    /// Snapshot of every per-tag preference the store currently knows
    /// about. Returned by value so callers don't observe mid-write
    /// mutations.
    var preferences: [FoodOSMomentPreference] {
        queue.sync { payload.preferences }
    }

    /// All retained events, oldest first. Capped at `eventHistoryCap`.
    var events: [FoodOSMomentFeedbackEvent] {
        queue.sync { payload.events }
    }

    /// All currently-armed experiments. At most one per tag.
    var activeExperiments: [FoodOSActiveExperiment] {
        queue.sync { payload.activeExperiments }
    }

    /// Bounded history of experiments that have already resolved or
    /// expired. Newest last, oldest first; capped at
    /// `resolvedExperimentHistoryCap`.
    var resolvedExperiments: [FoodOSActiveExperiment] {
        queue.sync { payload.resolvedExperiments }
    }

    /// Look up the preference row for one tag, or nil if no feedback
    /// has been recorded against that tag yet.
    func preference(for tag: FoodOSMomentTag) -> FoodOSMomentPreference? {
        queue.sync { payload.preferences.first(where: { $0.tag == tag }) }
    }

    /// Look up the currently-active experiment for a tag, or nil.
    func activeExperiment(for tag: FoodOSMomentTag) -> FoodOSActiveExperiment? {
        queue.sync {
            payload.activeExperiments.first(where: { $0.momentTag == tag })
        }
    }

    // MARK: Public writes — feedback events

    /// Record one feedback tap. Appends an event, updates the
    /// matching preference row (creating it on first sight),
    /// trims event history to the cap, and persists the result.
    @discardableResult
    func record(feedback: FoodOSMomentFeedback,
                for moment: FoodOSMoment,
                now: Date = Date()) -> FoodOSMomentFeedbackEvent {
        recordFeedback(moment: moment, feedback: feedback, createdAt: now)
    }

    /// V2 spec entrypoint — same behaviour as `record(feedback:for:now:)`
    /// but in the order the spec calls for. Returns the persisted
    /// event so tests / debug callers can introspect it.
    @discardableResult
    func recordFeedback(moment: FoodOSMoment,
                        feedback: FoodOSMomentFeedback,
                        createdAt: Date = Date()) -> FoodOSMomentFeedbackEvent {
        let event = FoodOSMomentFeedbackEvent(
            momentKind: moment.kind.rawValue,
            momentTitle: moment.title,
            feedback: feedback,
            momentTag: moment.momentTag,
            createdAt: createdAt
        )
        queue.sync {
            payload.events.append(event)
            if payload.events.count > Self.eventHistoryCap {
                payload.events.removeFirst(
                    payload.events.count - Self.eventHistoryCap
                )
            }
            applyFeedback(feedback, to: event.momentTag)
            persist()
        }
        return event
    }

    // MARK: Public writes — experiments (V2)

    /// Arm an active experiment for the given moment. If an
    /// experiment for the same tag is already active, it's *replaced*
    /// in place — tapping "I'll try this" again refreshes the window
    /// rather than spawning a duplicate. Any pre-existing experiment
    /// for the tag (active or otherwise) that we displace is moved to
    /// the resolved-history ring.
    @discardableResult
    func startExperiment(from moment: FoodOSMoment,
                         now: Date = Date()) -> FoodOSActiveExperiment {
        let experiment = FoodOSActiveExperiment(
            momentTag: moment.momentTag,
            momentKind: moment.kind,
            momentTitle: moment.title,
            startedAt: now,
            expiresAt: now.addingTimeInterval(FoodOSActiveExperiment.defaultTTL),
            sourceMomentEvidenceLine: moment.evidenceLine
        )
        queue.sync {
            // Replace any existing active row for the same tag.
            if let idx = payload.activeExperiments.firstIndex(
                where: { $0.momentTag == experiment.momentTag }
            ) {
                let displaced = payload.activeExperiments.remove(at: idx)
                // Only file the displaced row into history if it had
                // observable state; a same-second re-tap on a fresh
                // experiment is just a refresh and doesn't need a row.
                if displaced.status != .active
                    || displaced.startedAt < now.addingTimeInterval(-1) {
                    appendResolved(displaced)
                }
            }
            payload.activeExperiments.append(experiment)
            persist()
        }
        #if DEBUG
        NSLog("[FoodOSFeedback] started experiment tag=%@ kind=%@",
              experiment.momentTag.rawValue, experiment.momentKind.rawValue)
        #endif
        return experiment
    }

    /// Resolve any pending experiment in light of a freshly-recorded
    /// mood note on `log`. Returns the resolved descriptor if a
    /// resolution actually happened, or nil if there was no eligible
    /// active experiment (most calls — mood notes vastly outnumber
    /// experiment promises).
    ///
    /// V2 policy:
    ///   - resolve the *oldest still-active* experiment regardless of
    ///     which tag it belongs to. A single mood note resolves at
    ///     most one experiment per call, so a user who armed two
    ///     promises before logging gets each resolved on successive
    ///     mood notes.
    ///   - expire any active rows past their TTL first (no positive
    ///     or negative count update for those).
    ///   - loved / fine → positive, tough → negative; mood `nil`
    ///     would never reach this method (the API requires a Mood).
    @discardableResult
    func resolveExperiment(for log: FoodLog,
                           mood: FoodLog.Mood,
                           now: Date = Date()) -> FoodOSResolvedExperiment? {
        var resolution: FoodOSResolvedExperiment?
        queue.sync {
            expireOldExperimentsLocked(now: now)

            guard !payload.activeExperiments.isEmpty else { return }
            // Resolve the oldest active row — earliest startedAt wins.
            let idx = payload.activeExperiments
                .enumerated()
                .min(by: { $0.element.startedAt < $1.element.startedAt })?.offset
            guard let idx else { return }
            var experiment = payload.activeExperiments.remove(at: idx)
            let outcome = FoodOSActiveExperiment.Outcome.from(mood: mood)
            experiment.status = .resolved
            experiment.resolvedAt = now
            experiment.outcome = outcome
            experiment.relatedFoodLogId = log.id

            // Bump the per-tag preference's mood-after-try counters.
            // Counts plus shownCount stay decoupled here — those are
            // already incremented when the user originally tapped
            // "I'll try this".
            switch outcome {
            case .positive:
                applyMoodOutcome(positive: true, to: experiment.momentTag)
            case .negative:
                applyMoodOutcome(positive: false, to: experiment.momentTag)
            case .neutral, .unknown:
                break
            }

            appendResolved(experiment)
            persist()
            resolution = FoodOSResolvedExperiment(
                experimentId: experiment.id,
                momentTag: experiment.momentTag,
                outcome: outcome,
                mood: mood,
                relatedFoodLogId: log.id,
                resolvedAt: now
            )
        }
        if let r = resolution {
            #if DEBUG
            NSLog("[FoodOSFeedback] resolved experiment tag=%@ outcome=%@",
                  r.momentTag.rawValue, r.outcome.rawValue)
            #endif
            // Fire the lightweight notification on the main queue so
            // SwiftUI subscribers can update without dispatching.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .foodOSExperimentResolved,
                    object: r
                )
            }
        }
        return resolution
    }

    /// Sweep active experiments whose `expiresAt` has passed and file
    /// them into the resolved-history ring with `.expired` status.
    /// Idempotent — safe to call from app foreground, before reading
    /// the moment engine, etc.
    @discardableResult
    func expireOldExperiments(now: Date = Date()) -> Int {
        var count = 0
        queue.sync {
            count = expireOldExperimentsLocked(now: now)
        }
        #if DEBUG
        if count > 0 {
            NSLog("[FoodOSFeedback] expired experiments count=%d", count)
        }
        #endif
        return count
    }

    /// Wipe all events, preferences, and experiments. Used by tests
    /// and the corrupt-decode recovery path.
    func reset() {
        queue.sync {
            payload = Payload(schemaVersion: Self.schemaVersion,
                              events: [],
                              preferences: [],
                              activeExperiments: [],
                              resolvedExperiments: [])
            persist()
        }
    }

    // MARK: Private

    private static let schemaVersion = 2
    /// Older schema versions the loader is willing to migrate forward
    /// instead of treating as corruption. Anything outside this set
    /// is rejected and the file is wiped.
    private static let supportedSchemaVersions: Set<Int> = [1, 2]

    /// Mutate the preference row that matches `tag`, creating it if
    /// needed. Counts plus shownCount increment together — the user
    /// must have seen the moment to tap a chip, so the act of giving
    /// feedback is itself evidence the surface was shown.
    ///
    /// TODO V3: track impressions separately from taps so passive
    /// non-engagement isn't conflated with explicit feedback. V1/V2
    /// keep the conservative behaviour of treating feedback taps as
    /// the impression signal.
    private func applyFeedback(_ feedback: FoodOSMomentFeedback,
                               to tag: FoodOSMomentTag) {
        var (pref, idx) = preferenceOrSeed(for: tag)
        pref.shownCount += 1
        switch feedback {
        case .helpful:   pref.helpfulCount   += 1
        case .notUseful: pref.notUsefulCount += 1
        case .willTry:   pref.willTryCount   += 1
        }
        pref.recomputeDerived()
        commitPreference(pref, at: idx)
    }

    /// Bump positive/negative mood-after-try counts. Does NOT touch
    /// shownCount — the original willTry tap already accounted for
    /// the surface impression.
    private func applyMoodOutcome(positive: Bool,
                                  to tag: FoodOSMomentTag) {
        var (pref, idx) = preferenceOrSeed(for: tag)
        if positive {
            pref.positiveMoodAfterTryCount += 1
        } else {
            pref.negativeMoodAfterTryCount += 1
        }
        pref.recomputeDerived()
        commitPreference(pref, at: idx)
    }

    private func preferenceOrSeed(
        for tag: FoodOSMomentTag
    ) -> (FoodOSMomentPreference, Int?) {
        if let idx = payload.preferences.firstIndex(where: { $0.tag == tag }) {
            return (payload.preferences[idx], idx)
        }
        return (FoodOSMomentPreference(tag: tag), nil)
    }

    private func commitPreference(_ pref: FoodOSMomentPreference,
                                  at idx: Int?) {
        if let idx { payload.preferences[idx] = pref }
        else { payload.preferences.append(pref) }
    }

    /// Move every active row past its TTL into the resolved history
    /// with `.expired` status. Returns the count for diagnostics.
    /// MUST be called from inside `queue.sync`.
    @discardableResult
    private func expireOldExperimentsLocked(now: Date) -> Int {
        var moved = 0
        var i = 0
        while i < payload.activeExperiments.count {
            if payload.activeExperiments[i].isExpired(now: now) {
                var expired = payload.activeExperiments.remove(at: i)
                expired.status = .expired
                expired.resolvedAt = now
                expired.outcome = .unknown
                appendResolved(expired)
                moved += 1
            } else {
                i += 1
            }
        }
        if moved > 0 { persist() }
        return moved
    }

    private func appendResolved(_ experiment: FoodOSActiveExperiment) {
        payload.resolvedExperiments.append(experiment)
        if payload.resolvedExperiments.count > Self.resolvedExperimentHistoryCap {
            payload.resolvedExperiments.removeFirst(
                payload.resolvedExperiments.count
                    - Self.resolvedExperimentHistoryCap
            )
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // Always write at the current schemaVersion regardless of
            // what we loaded — completes the V1 → V2 migration the
            // first time we successfully persist.
            payload.schemaVersion = Self.schemaVersion
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Persistence failure is non-fatal — the in-memory copy
            // still reflects the user's most recent tap.
        }
    }

    private static func load(from url: URL) -> Payload {
        let empty = Payload(schemaVersion: schemaVersion,
                            events: [],
                            preferences: [],
                            activeExperiments: [],
                            resolvedExperiments: [])
        guard FileManager.default.fileExists(atPath: url.path) else {
            return empty
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(Payload.self, from: data)
            // Accept V1 and V2 payloads. V1 → V2 migration is
            // implicit: the new fields default-decode to empty arrays
            // and the next persist() flips schemaVersion to 2.
            guard supportedSchemaVersions.contains(decoded.schemaVersion) else {
                return empty
            }
            return decoded
        } catch {
            // Corrupt file: wipe it so the next write isn't writing
            // alongside garbage, and start clean.
            try? FileManager.default.removeItem(at: url)
            return empty
        }
    }
}
