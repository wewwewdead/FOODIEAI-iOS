import Foundation

/// Posts a JPEG to the Express `/analyze` proxy and decodes the Gemini
/// response. The Gemini API key never leaves the server — iOS only knows
/// `ANALYZE_BASE_URL`.
///
/// Multipart body uses Apple's documented pattern for `multipart/form-data`
/// (no third-party library). Single part named `image` with filename
/// `meal.jpg` and content-type `image/jpeg`. 60-second timeout.
///
/// JSONDecoder is the default — `routes/gemini.js` emits camelCase
/// (`coachAdvice`), so `.convertFromSnakeCase` would actively break decoding.
actor AnalyzeService {
    private let baseURL: URL
    private let session: URLSession

    /// Maximum compressed JPEG size we'll send. Gemini's vision endpoint
    /// rejects payloads above ~20MB, and the Express proxy uses
    /// `multer({ limits: { fileSize: 10 * 1024 * 1024 } })` (10MB). We reject
    /// just under that to surface a clear client-side error rather than
    /// shipping bytes that we know will 413.
    static let maxJPEGBytes = 9_500_000

    /// Shared formatter for the `recent_meals` / `recent_moods` wire
    /// fields. `ISO8601DateFormatter` is thread-safe and configured
    /// once; this avoids re-initializing it (an ICU + locale bootstrap)
    /// on every analyze call.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(baseURL: URL = AppConfig.analyzeBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Phase 16. `recentMeals` and `preferredCoaches` are optional
    /// context inputs the server uses to inform the coach quote — the
    /// nutrition analysis itself is unaffected. Pre-Phase-16 callers
    /// (no extra args) get the same JSON body shape they always sent.
    ///
    /// `recentMeals` is bounded to 14 entries client-side; the server
    /// re-bounds defensively. Empty array → field omitted entirely so
    /// the multipart body is byte-identical to v1.
    ///
    /// Phase 18: `recentMoods` adds an optional, mood-labeled subset
    /// of recent meals (non-null `mood`). Bounded to 10 client-side;
    /// the server re-bounds defensively. Empty array → field omitted.
    /// Quantity Clarification — `userQuantities` carries user-resolved
    /// portions from the clarification sheet. Empty array → field omitted
    /// from the multipart body so the pre-clarification body shape is
    /// preserved byte-for-byte. When present, the server folds these
    /// amounts into the prompt and recomputes the whole plate's macros.
    func analyze(jpegData: Data,
                 recentMeals: [FoodLog] = [],
                 preferredCoaches: [String] = [],
                 recentMoods: [FoodLog] = [],
                 userQuantities: [(name: String, quantity: String)] = []) async throws -> AnalyzeResponse {
        guard jpegData.count <= Self.maxJPEGBytes else {
            throw AnalyzeError.imageTooLarge
        }

        let url = baseURL.appendingPathComponent("analyze")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // Build the multipart body. Image part is mandatory; the
        // context fields are appended only when populated.
        let boundedMeals = Array(recentMeals.prefix(14))
        let recentMealsJSON = Self.encodeRecentMeals(boundedMeals)
        let preferredCoachesJSON = preferredCoaches.isEmpty
            ? nil
            : Self.encodePreferredCoaches(preferredCoaches)
        let boundedMoods = Array(recentMoods.prefix(10))
        let recentMoodsJSON = Self.encodeRecentMoods(boundedMoods)
        let boundedQuantities = Array(userQuantities.prefix(8))
        let userQuantitiesJSON = Self.encodeUserQuantities(boundedQuantities)

        request.httpBody = Self.multipartBody(
            boundary: boundary,
            imagePayload: jpegData,
            recentMealsJSON: recentMealsJSON,
            preferredCoachesJSON: preferredCoachesJSON,
            recentMoodsJSON: recentMoodsJSON,
            userQuantitiesJSON: userQuantitiesJSON
        )

        #if DEBUG
        NSLog("[Analyze] POST %@ bytes=%d recentMeals=%d prefs=%d recentMoods=%d userQuantities=%d",
              url.absoluteString, jpegData.count,
              boundedMeals.count, preferredCoaches.count,
              boundedMoods.count, boundedQuantities.count)
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            #if DEBUG
            NSLog("[Analyze] URLError code=%d desc=%@",
                  urlError.code.rawValue, urlError.localizedDescription)
            #endif
            throw map(urlError: urlError)
        } catch {
            throw AnalyzeError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnalyzeError.serverError(status: 0, body: "")
        }

        #if DEBUG
        NSLog("[Analyze] HTTP %d body-bytes=%d", http.statusCode, data.count)
        #endif

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            #if DEBUG
            NSLog("[Analyze] HTTP %d body=%@", http.statusCode, body)
            #endif
            throw AnalyzeError.serverError(status: http.statusCode, body: body)
        }

        do {
            let decoded = try JSONDecoder().decode(AnalyzeResponse.self, from: data)
            #if DEBUG
            NSLog("[Analyze] decoded food=%@ coach=%@ calories=%@ hasFood=%@",
                  decoded.analysis.food ?? "<nil>",
                  decoded.coach ?? "<nil>",
                  decoded.analysis.calories.map { "\($0)" } ?? "<nil>",
                  decoded.analysis.hasFood ? "true" : "false")
            #endif
            return decoded
        } catch {
            #if DEBUG
            NSLog("[Analyze] decode FAILED: %@", "\(error)")
            #endif
            throw AnalyzeError.decodingFailed(underlying: error)
        }
    }

    private func map(urlError: URLError) -> AnalyzeError {
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet:
            // Phone has no connection — show the offline-specific message
            // that nudges the user to check airplane mode / wifi.
            return .offline
        case .networkConnectionLost,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable:
            // Server-side reachable in principle (we have internet) but
            // the analyze host couldn't be reached — usually means the
            // local Express proxy isn't running. Surface a generic
            // "something went wrong" rather than blaming the user's network.
            return .networkUnavailable
        default:
            return .networkUnavailable
        }
    }

    /// Multi-field multipart body builder. Always emits the `image`
    /// part. Text parts are appended only when non-nil — passing nil
    /// keeps the body byte-identical to the pre-Phase-16 single-field
    /// shape. Phase 18 added `recentMoodsJSON` with the same opt-in
    /// behavior.
    private static func multipartBody(boundary: String,
                                      imagePayload: Data,
                                      recentMealsJSON: String?,
                                      preferredCoachesJSON: String?,
                                      recentMoodsJSON: String?,
                                      userQuantitiesJSON: String?) -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Image part
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"image\"; filename=\"meal.jpg\"\(crlf)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(imagePayload)
        body.append(crlf.data(using: .utf8)!)

        // Optional text parts
        if let recentMealsJSON {
            appendTextPart(to: &body, boundary: boundary,
                           name: "recent_meals", value: recentMealsJSON)
        }
        if let preferredCoachesJSON {
            appendTextPart(to: &body, boundary: boundary,
                           name: "preferred_coaches", value: preferredCoachesJSON)
        }
        if let recentMoodsJSON {
            appendTextPart(to: &body, boundary: boundary,
                           name: "recent_moods", value: recentMoodsJSON)
        }
        if let userQuantitiesJSON {
            appendTextPart(to: &body, boundary: boundary,
                           name: "user_quantities", value: userQuantitiesJSON)
        }

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }

    private static func appendTextPart(to body: inout Data,
                                       boundary: String,
                                       name: String,
                                       value: String) {
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"\(crlf)"
                .data(using: .utf8)!
        )
        // No explicit Content-Type for plain text fields; multer handles
        // them as strings on `req.body[name]` regardless.
        body.append(crlf.data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)
    }

    /// JSON-encode `recent_meals` as `[{food_name, eaten_at}]`. Returns
    /// nil when the input is empty so the caller can skip emitting the
    /// part entirely (cleaner than sending `[]`).
    private static func encodeRecentMeals(_ logs: [FoodLog]) -> String? {
        guard !logs.isEmpty else { return nil }

        struct Wire: Encodable {
            let food_name: String
            let eaten_at: String
        }
        let f = Self.iso8601Formatter
        let wires = logs.map {
            Wire(food_name: $0.foodName, eaten_at: f.string(from: $0.eatenAt))
        }
        do {
            let data = try JSONEncoder().encode(wires)
            return String(data: data, encoding: .utf8)
        } catch {
            #if DEBUG
            NSLog("[Analyze] encodeRecentMeals FAILED: %@", "\(error)")
            #endif
            return nil
        }
    }

    private static func encodePreferredCoaches(_ coaches: [String]) -> String? {
        do {
            let data = try JSONEncoder().encode(coaches)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Quantity Clarification — JSON-encode `user_quantities` as
    /// `[{name, quantity}]`. Returns nil for an empty input so the
    /// caller can omit the multipart part entirely (the server treats
    /// a missing field identically to an empty array).
    private static func encodeUserQuantities(_ pairs: [(name: String, quantity: String)]) -> String? {
        guard !pairs.isEmpty else { return nil }
        struct Wire: Encodable {
            let name: String
            let quantity: String
        }
        let wires = pairs.map { Wire(name: $0.name, quantity: $0.quantity) }
        do {
            let data = try JSONEncoder().encode(wires)
            return String(data: data, encoding: .utf8)
        } catch {
            #if DEBUG
            NSLog("[Analyze] encodeUserQuantities FAILED: %@", "\(error)")
            #endif
            return nil
        }
    }

    /// Phase 18 — JSON-encode `recent_moods` as
    /// `[{food_name, mood, eaten_at}]`. Caller is expected to filter
    /// to non-null moods before calling, but we defensively skip
    /// rows with `mood == nil` here too. Returns nil for an empty
    /// input so the caller can omit the part.
    private static func encodeRecentMoods(_ logs: [FoodLog]) -> String? {
        let labeled = logs.compactMap { log -> (FoodLog, FoodLog.Mood)? in
            guard let mood = log.mood else { return nil }
            return (log, mood)
        }
        guard !labeled.isEmpty else { return nil }

        struct Wire: Encodable {
            let food_name: String
            let mood: String
            let eaten_at: String
        }
        let f = Self.iso8601Formatter
        let wires = labeled.map { (log, mood) in
            Wire(food_name: log.foodName,
                 mood: mood.rawValue,
                 eaten_at: f.string(from: log.eatenAt))
        }
        do {
            let data = try JSONEncoder().encode(wires)
            return String(data: data, encoding: .utf8)
        } catch {
            #if DEBUG
            NSLog("[Analyze] encodeRecentMoods FAILED: %@", "\(error)")
            #endif
            return nil
        }
    }
}

enum AnalyzeError: LocalizedError, Equatable {
    case serverError(status: Int, body: String)
    case offline
    case networkUnavailable
    case decodingFailed(underlying: Error)
    case imageTooLarge
    case timeout

    var errorDescription: String? {
        switch self {
        case .serverError:
            return "Something went wrong on our end. Try again in a moment."
        case .offline:
            return "Looks like you're offline. Check your connection and try again."
        case .networkUnavailable:
            return "We can't reach the analyzer right now. Try again in a moment."
        case .decodingFailed:
            return "We couldn't read the analysis result. Try again."
        case .imageTooLarge:
            return "That photo is too large. Try a smaller one."
        case .timeout:
            return "The analyzer took too long to respond. Try again."
        }
    }

    static func == (lhs: AnalyzeError, rhs: AnalyzeError) -> Bool {
        switch (lhs, rhs) {
        case (.offline, .offline),
             (.networkUnavailable, .networkUnavailable),
             (.imageTooLarge, .imageTooLarge),
             (.timeout, .timeout):
            return true
        case (.serverError(let ls, _), .serverError(let rs, _)):
            return ls == rs
        case (.decodingFailed, .decodingFailed):
            return true
        default:
            return false
        }
    }
}
