import Foundation

struct OpenSubtitlesAPIClient: Sendable {
    enum RequestContext {
        case validation
        case search
        case login
        case logout
        case download
        case subtitleFile
    }

    private struct LoginBody: Encodable {
        let username: String
        let password: String
    }

    private struct DownloadBody: Encodable {
        let fileID: Int
        let subFormat = "srt"

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case subFormat = "sub_format"
        }
    }

    private struct LoginResponse: Decodable {
        let token: String?
        let baseURL: String?

        enum CodingKeys: String, CodingKey {
            case token
            case baseURL = "base_url"
        }
    }

    struct DownloadDescriptor: Sendable {
        let url: URL
        let fileName: String?
    }

    private struct DownloadResponse: Decodable {
        let link: String?
        let fileName: String?

        enum CodingKeys: String, CodingKey {
            case link
            case fileName = "file_name"
        }
    }

    private struct ErrorResponse: Decodable {
        let message: String?
        let resetTimeUTC: String?

        enum CodingKeys: String, CodingKey {
            case message
            case resetTimeUTC = "reset_time_utc"
        }
    }

    struct SearchRecord: Sendable {
        let subtitleID: String?
        let language: String
        let releaseName: String?
        let featureTitle: String?
        let featureYear: Int?
        let framesPerSecond: Double?
        let hearingImpaired: Bool
        let forced: Bool
        let rating: Double?
        let downloadCount: Int?
        let movieHashMatch: Bool
        let files: [SearchFile]
    }

    struct SearchFile: Sendable {
        let fileID: Int
        let fileName: String?
    }

    private let transport: any OpenSubtitlesHTTPTransport
    private let credentials: any OpenSubtitlesCredentialStoring
    private let userAgent: String

    static let publicBaseURL = URL(string: "https://api.opensubtitles.com/api/v1")!

    init(
        transport: any OpenSubtitlesHTTPTransport,
        credentials: any OpenSubtitlesCredentialStoring,
        userAgent: String
    ) {
        self.transport = transport
        self.credentials = credentials
        let trimmedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = trimmedAgent.isEmpty ? "KinoXPlayer v1.0" : trimmedAgent
    }

    func validateAPIKey(_ key: String) async throws {
        let response = try await apiRequest(
            baseURL: Self.publicBaseURL,
            path: "subtitles",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "languages", value: "en"),
                URLQueryItem(name: "query", value: "kinoxplayer-api-key-check")
            ],
            body: nil,
            apiKey: key,
            bearerToken: nil,
            context: .validation
        )
        guard let object = try? JSONSerialization.jsonObject(with: response.data),
              let dictionary = object as? [String: Any],
              dictionary["data"] is [Any] else {
            throw OpenSubtitlesError.invalidPayload
        }
    }

    func login(username: String, password: String) async throws -> OpenSubtitlesStoredSession {
        let apiKey = try requiredAPIKey()
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            throw OpenSubtitlesError.unauthorized
        }

        let body = try JSONEncoder().encode(LoginBody(username: username, password: password))
        let response = try await apiRequest(
            baseURL: Self.publicBaseURL,
            path: "login",
            method: "POST",
            queryItems: [],
            body: body,
            apiKey: apiKey,
            bearerToken: nil,
            context: .login
        )

        let decoded: LoginResponse
        do {
            decoded = try JSONDecoder().decode(LoginResponse.self, from: response.data)
        } catch {
            throw OpenSubtitlesError.invalidPayload
        }

        guard let token = decoded.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw OpenSubtitlesError.invalidPayload
        }
        let baseURL: URL
        if let returnedBase = decoded.baseURL, !returnedBase.isEmpty {
            guard let normalized = Self.normalizedAPIBaseURL(returnedBase) else {
                throw OpenSubtitlesError.unsafeURL
            }
            baseURL = normalized
        } else {
            baseURL = Self.publicBaseURL
        }
        return OpenSubtitlesStoredSession(token: token, baseURL: baseURL)
    }

    func search(
        movieHash: String? = nil,
        query: String? = nil,
        languages: [String]
    ) async throws -> [SearchRecord] {
        let apiKey = try requiredAPIKey()
        let session = try credentials.session()
        let baseURL = session?.baseURL ?? Self.publicBaseURL

        var items: [URLQueryItem] = []
        if let movieHash, !movieHash.isEmpty {
            items.append(URLQueryItem(name: "moviehash", value: movieHash))
        }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
        }

        let response = try await apiRequest(
            baseURL: baseURL,
            path: "subtitles",
            method: "GET",
            queryItems: items,
            body: nil,
            apiKey: apiKey,
            bearerToken: session?.token,
            context: .search
        )

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: response.data)
        } catch {
            throw OpenSubtitlesError.invalidPayload
        }
        return decoded.data.elements.map(\.record)
    }

    func downloadDescriptor(fileID: Int) async throws -> DownloadDescriptor {
        guard fileID > 0 else { throw OpenSubtitlesError.invalidPayload }
        let apiKey = try requiredAPIKey()
        let session = try credentials.session()
        let body = try JSONEncoder().encode(DownloadBody(fileID: fileID))
        let response = try await apiRequest(
            baseURL: session?.baseURL ?? Self.publicBaseURL,
            path: "download",
            method: "POST",
            queryItems: [],
            body: body,
            apiKey: apiKey,
            bearerToken: session?.token,
            context: .download
        )

        let decoded: DownloadResponse
        do {
            decoded = try JSONDecoder().decode(DownloadResponse.self, from: response.data)
        } catch {
            throw OpenSubtitlesError.invalidPayload
        }
        guard let link = decoded.link, let url = URL(string: link),
              OpenSubtitlesURLSessionTransport.isAllowed(url) else {
            throw OpenSubtitlesError.unsafeURL
        }
        return DownloadDescriptor(url: url, fileName: decoded.fileName)
    }

    func logout() async throws {
        let apiKey = try requiredAPIKey()
        guard let session = try credentials.session() else { return }
        _ = try await apiRequest(
            baseURL: session.baseURL,
            path: "logout",
            method: "DELETE",
            queryItems: [],
            body: nil,
            apiKey: apiKey,
            bearerToken: session.token,
            context: .logout
        )
    }

    func downloadSubtitle(from descriptor: DownloadDescriptor) async throws -> Data {
        var request = URLRequest(url: descriptor.url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let response = try await transport.send(
                request,
                maximumBytes: OpenSubtitlesURLSessionTransport.maximumSubtitleBytes,
                hostPolicy: .subtitleDownload
            )
            try validateStatus(response, context: .subtitleFile, hasBearerToken: false)
            return response.data
        } catch {
            throw mapTransportError(error)
        }
    }

    static func normalizedAPIBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              host == "api.opensubtitles.com" || host == "vip-api.opensubtitles.com" else {
            return nil
        }

        components.scheme = "https"
        components.host = host
        components.port = nil
        components.query = nil
        components.fragment = nil
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/api/v1"
        } else if path == "api/v1" {
            components.path = "/api/v1"
        } else {
            return nil
        }
        return components.url
    }

    private func requiredAPIKey() throws -> String {
        guard let key = try credentials.apiKey(), !key.isEmpty else {
            throw OpenSubtitlesError.missingAPIKey
        }
        return key
    }

    private func apiRequest(
        baseURL: URL,
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        apiKey: String,
        bearerToken: String?,
        context: RequestContext
    ) async throws -> OpenSubtitlesHTTPResponse {
        guard let safeBaseURL = Self.normalizedAPIBaseURL(baseURL.absoluteString),
              var components = URLComponents(
            url: safeBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw OpenSubtitlesError.unsafeURL
        }
        components.queryItems = queryItems.isEmpty
            ? nil
            : queryItems.sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return (lhs.value ?? "") < (rhs.value ?? "")
            }
        guard let url = components.url, OpenSubtitlesURLSessionTransport.isAllowed(url) else {
            throw OpenSubtitlesError.unsafeURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let response = try await transport.send(
                request,
                maximumBytes: OpenSubtitlesURLSessionTransport.maximumAPIPayloadBytes,
                hostPolicy: .api
            )
            try validateStatus(
                response,
                context: context,
                hasBearerToken: !(bearerToken?.isEmpty ?? true)
            )
            return response
        } catch {
            throw mapTransportError(error)
        }
    }

    private func validateStatus(
        _ response: OpenSubtitlesHTTPResponse,
        context: RequestContext,
        hasBearerToken: Bool
    ) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let message = Self.providerMessage(from: response.data)

        switch response.statusCode {
        case 401:
            if context == .validation { throw OpenSubtitlesError.invalidAPIKey }
            if context == .download { throw OpenSubtitlesError.loginRequired }
            throw OpenSubtitlesError.unauthorized
        case 403:
            if context == .validation { throw OpenSubtitlesError.invalidAPIKey }
            throw OpenSubtitlesError.forbidden
        case 406 where context == .download:
            if Self.indicatesDownloadLimit(message) {
                throw OpenSubtitlesError.downloadLimitExceeded(
                    resetTime: Self.providerResetTime(from: response.data)
                )
            }
            if !hasBearerToken || Self.indicatesAuthenticationProblem(message) {
                throw OpenSubtitlesError.loginRequired
            }
            throw OpenSubtitlesError.provider(statusCode: 406, message: message)
        case 429:
            throw OpenSubtitlesError.rateLimited(
                retryAfter: Self.retryAfter(from: response.headers["retry-after"])
            )
        default:
            throw OpenSubtitlesError.provider(statusCode: response.statusCode, message: message)
        }
    }

    private func mapTransportError(_ error: Error) -> OpenSubtitlesError {
        if let error = error as? OpenSubtitlesError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed, .timedOut:
                return .offline
            default:
                return .provider(statusCode: nil, message: nil)
            }
        }
        return .provider(statusCode: nil, message: nil)
    }

    private static func providerMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        if let message = dictionary["message"] as? String {
            return String(message.prefix(300))
        }
        if let error = dictionary["error"] as? String {
            return String(error.prefix(300))
        }
        return nil
    }

    private static func providerResetTime(from data: Data) -> String? {
        try? JSONDecoder().decode(ErrorResponse.self, from: data).resetTimeUTC
    }

    private static func indicatesDownloadLimit(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        if message.contains("quota") { return true }
        let mentionsDownload = message.contains("download")
        let mentionsLimit = message.contains("limit")
            || message.contains("remaining")
            || message.contains("exceeded")
            || message.contains("reached")
        return mentionsDownload && mentionsLimit
    }

    private static func indicatesAuthenticationProblem(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("token")
            || message.contains("login")
            || message.contains("auth")
            || message.contains("credential")
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

private struct SearchResponse: Decodable {
    let data: LossyArray<SearchItem>

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decode(LossyArray<SearchItem>.self, forKey: .data)) ?? LossyArray([])
    }
}

private struct SearchItem: Decodable {
    let record: OpenSubtitlesAPIClient.SearchRecord

    private enum CodingKeys: String, CodingKey { case id, attributes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.flexibleString(forKey: .id)
        let attributes = (try? container.decode(SearchAttributes.self, forKey: .attributes)) ?? .empty
        record = OpenSubtitlesAPIClient.SearchRecord(
            subtitleID: attributes.subtitleID ?? id,
            language: attributes.language ?? "und",
            releaseName: attributes.releaseName,
            featureTitle: attributes.featureDetails?.title,
            featureYear: attributes.featureDetails?.year,
            framesPerSecond: attributes.framesPerSecond,
            hearingImpaired: attributes.hearingImpaired ?? false,
            forced: attributes.forced ?? false,
            rating: attributes.rating,
            downloadCount: attributes.downloadCount,
            movieHashMatch: attributes.movieHashMatch ?? false,
            files: attributes.files.elements.compactMap { file in
                guard let fileID = file.fileID, fileID > 0 else { return nil }
                return OpenSubtitlesAPIClient.SearchFile(fileID: fileID, fileName: file.fileName)
            }
        )
    }
}

private struct SearchAttributes: Decodable {
    let subtitleID: String?
    let language: String?
    let releaseName: String?
    let framesPerSecond: Double?
    let hearingImpaired: Bool?
    let forced: Bool?
    let rating: Double?
    let downloadCount: Int?
    let movieHashMatch: Bool?
    let featureDetails: FeatureDetails?
    let files: LossyArray<SearchFileResponse>

    static let empty = SearchAttributes()

    private enum CodingKeys: String, CodingKey {
        case subtitleID = "subtitle_id"
        case language
        case releaseName = "release"
        case framesPerSecond = "fps"
        case hearingImpaired = "hearing_impaired"
        case forced = "foreign_parts_only"
        case rating = "ratings"
        case downloadCount = "download_count"
        case movieHashMatch = "moviehash_match"
        case featureDetails = "feature_details"
        case files
    }

    init() {
        subtitleID = nil
        language = nil
        releaseName = nil
        framesPerSecond = nil
        hearingImpaired = nil
        forced = nil
        rating = nil
        downloadCount = nil
        movieHashMatch = nil
        featureDetails = nil
        files = LossyArray([])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitleID = container.flexibleString(forKey: .subtitleID)
        language = container.flexibleString(forKey: .language)
        releaseName = container.flexibleString(forKey: .releaseName)
        framesPerSecond = container.flexibleDouble(forKey: .framesPerSecond)
        hearingImpaired = container.flexibleBool(forKey: .hearingImpaired)
        forced = container.flexibleBool(forKey: .forced)
        rating = container.flexibleDouble(forKey: .rating)
        downloadCount = container.flexibleInt(forKey: .downloadCount)
        movieHashMatch = container.flexibleBool(forKey: .movieHashMatch)
        featureDetails = try? container.decodeIfPresent(FeatureDetails.self, forKey: .featureDetails)
        files = (try? container.decode(LossyArray<SearchFileResponse>.self, forKey: .files)) ?? LossyArray([])
    }
}

private struct FeatureDetails: Decodable {
    let title: String?
    let year: Int?

    private enum CodingKeys: String, CodingKey { case movieName = "movie_name", title, year }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.flexibleString(forKey: .movieName)
            ?? container.flexibleString(forKey: .title)
        year = container.flexibleInt(forKey: .year)
    }
}

private struct SearchFileResponse: Decodable {
    let fileID: Int?
    let fileName: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileID = container.flexibleInt(forKey: .fileID)
        fileName = container.flexibleString(forKey: .fileName)
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            guard let elementDecoder = try? container.superDecoder() else { continue }
            if let value = try? Element(from: elementDecoder) {
                values.append(value)
            }
        }
        elements = values
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        return nil
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(exactly: value)
        }
        return nil
    }

    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return value }
        if let value = try? decode(String.self, forKey: key) {
            guard let number = Double(value), number.isFinite else { return nil }
            return number
        }
        return nil
    }

    func flexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = flexibleInt(forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
