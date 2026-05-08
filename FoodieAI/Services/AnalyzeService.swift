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

    init(baseURL: URL = AppConfig.analyzeBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func analyze(jpegData: Data) async throws -> AnalyzeResponse {
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
        request.httpBody = Self.multipartBody(
            boundary: boundary, fieldName: "image",
            fileName: "meal.jpg", mimeType: "image/jpeg",
            payload: jpegData
        )

        #if DEBUG
        NSLog("[Analyze] POST %@ bytes=%d", url.absoluteString, jpegData.count)
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

    private static func multipartBody(boundary: String,
                                      fieldName: String,
                                      fileName: String,
                                      mimeType: String,
                                      payload: Data) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\(crlf)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(payload)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
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
