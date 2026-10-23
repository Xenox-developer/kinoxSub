import Foundation

enum SubtitleFinderMode: String, CaseIterable, Hashable, Sendable {
    case online
    case local
}

/// A UI-facing destination that deliberately does not depend on PlayerController.
enum SubtitleFinderDestination: String, CaseIterable, Hashable, Sendable {
    case primary
    case secondary

    var shortTitle: String {
        switch self {
        case .primary: return "S1"
        case .secondary: return "S2"
        }
    }

    var title: String {
        switch self {
        case .primary: return "основные субтитры"
        case .secondary: return "вторые субтитры"
        }
    }
}

struct SubtitleFinderLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let displayName: String

    var id: String { code }

    init(code: String, displayName: String) {
        self.code = code.lowercased()
        self.displayName = displayName
    }

    static let common: [SubtitleFinderLanguage] = [
        SubtitleFinderLanguage(code: "ru", displayName: "Русский"),
        SubtitleFinderLanguage(code: "de", displayName: "Немецкий"),
        SubtitleFinderLanguage(code: "en", displayName: "Английский"),
        SubtitleFinderLanguage(code: "es", displayName: "Испанский"),
        SubtitleFinderLanguage(code: "fr", displayName: "Французский"),
        SubtitleFinderLanguage(code: "it", displayName: "Итальянский"),
        SubtitleFinderLanguage(code: "uk", displayName: "Украинский"),
        SubtitleFinderLanguage(code: "pl", displayName: "Польский"),
        SubtitleFinderLanguage(code: "pt", displayName: "Португальский")
    ]
}

struct SubtitleFinderOnlineSearchRequest: Equatable, Sendable {
    let query: String
    let languages: [String]

    init(query: String, languages: [String]) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.languages = languages.map { $0.lowercased() }
    }
}

/// A provider result that has not been downloaded yet. It intentionally has no file URL.
struct SubtitleFinderRemoteCandidate: Identifiable, Hashable, Sendable {
    let remoteIdentifier: String
    let displayName: String
    let languageCode: String
    let languageName: String
    let releaseName: String?
    let formatName: String
    let framesPerSecond: Double?
    let rating: Double?
    let downloadCount: Int?
    let isHashMatch: Bool

    var id: String { remoteIdentifier }

    init(
        remoteIdentifier: String,
        displayName: String,
        languageCode: String,
        languageName: String,
        releaseName: String? = nil,
        formatName: String = "SRT",
        framesPerSecond: Double? = nil,
        rating: Double? = nil,
        downloadCount: Int? = nil,
        isHashMatch: Bool = false
    ) {
        self.remoteIdentifier = remoteIdentifier
        self.displayName = displayName
        self.languageCode = languageCode.lowercased()
        self.languageName = languageName
        self.releaseName = releaseName
        self.formatName = formatName
        self.framesPerSecond = framesPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.rating = rating.flatMap { $0.isFinite ? min(max($0, 0), 10) : nil }
        self.downloadCount = downloadCount.map { max($0, 0) }
        self.isHashMatch = isHashMatch
    }
}

enum SubtitleFinderAPIKeyState: Equatable, Sendable {
    case unavailable
    case missing
    case validating
    case ready
    case invalid(String)
}

enum SubtitleFinderAccountState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signingOut
    case signedIn(String?)
    case expired
}

enum SubtitleFinderOnlineError: LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case loginRequired
    case rateLimited(String?)
    case offline
    case provider(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "API-ключ не подошёл. Проверьте его и сохраните снова."
        case .loginRequired:
            return "Для загрузки этих субтитров войдите в аккаунт OpenSubtitles. Поиск доступен без входа."
        case .rateLimited(let message):
            return message ?? "Сервис временно ограничил число запросов. Попробуйте немного позже."
        case .offline:
            return "Не удалось подключиться к интернету. Проверьте соединение и повторите поиск."
        case .provider(let message), .download(let message):
            return message
        }
    }
}

struct SubtitleFinderOnlineConfiguration {
    typealias ValidateAndStoreKey = (String) async throws -> Void
    typealias RemoveKey = () async throws -> Void
    typealias Search = (SubtitleFinderOnlineSearchRequest) async throws -> [SubtitleFinderRemoteCandidate]
    typealias Materialize = (SubtitleFinderRemoteCandidate) async throws -> SubtitleFinderCandidate
    typealias HasStoredSession = () -> Bool
    typealias Login = (String, String) async throws -> Void
    typealias Logout = () async throws -> Void

    let initialAPIKeyState: SubtitleFinderAPIKeyState
    let initialAccountState: SubtitleFinderAccountState
    let keyManagementURL: URL
    let languages: [SubtitleFinderLanguage]
    let initialLanguages: [String]
    let validateAndStoreKey: ValidateAndStoreKey
    let removeKey: RemoveKey
    let search: Search
    let materialize: Materialize
    let hasStoredSession: HasStoredSession?
    let login: Login?
    let logout: Logout?

    init(
        initialAPIKeyState: SubtitleFinderAPIKeyState,
        initialAccountState: SubtitleFinderAccountState = .signedOut,
        keyManagementURL: URL,
        languages: [SubtitleFinderLanguage] = SubtitleFinderLanguage.common,
        initialLanguages: [String] = ["ru", "en"],
        validateAndStoreKey: @escaping ValidateAndStoreKey,
        removeKey: @escaping RemoveKey,
        search: @escaping Search,
        materialize: @escaping Materialize,
        hasStoredSession: HasStoredSession? = nil,
        login: Login? = nil,
        logout: Logout? = nil
    ) {
        self.initialAPIKeyState = initialAPIKeyState
        self.initialAccountState = initialAccountState
        self.keyManagementURL = keyManagementURL
        self.languages = languages
        self.initialLanguages = initialLanguages
        self.validateAndStoreKey = validateAndStoreKey
        self.removeKey = removeKey
        self.search = search
        self.materialize = materialize
        self.hasStoredSession = hasStoredSession
        self.login = login
        self.logout = logout
    }
}

/// The best single explanation of how a subtitle file matches the current video.
enum SubtitleFinderAssessment: Hashable, Sendable {
    case suitable
    case timeOffset(seconds: TimeInterval)
    case frameRate(subtitleFPS: Double, videoFPS: Double)
    case differentEdit
    case unverified

    fileprivate var sortPriority: Int {
        switch self {
        case .suitable: return 0
        case .timeOffset: return 1
        case .frameRate: return 2
        case .unverified: return 3
        case .differentEdit: return 4
        }
    }
}

/// A presentation model supplied by a subtitle matching service.
///
/// The finder does not inspect media itself. A host can map any matching engine's
/// result into this small type and keep technical details outside the SwiftUI layer.
struct SubtitleFinderCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileURL: URL
    let displayName: String
    let languageCode: String?
    let languageName: String?
    let formatName: String
    let releaseName: String?
    let assessment: SubtitleFinderAssessment
    let timingTransform: SubtitleTimingTransform?
    let confidence: Double?

    init(
        id: UUID = UUID(),
        fileURL: URL,
        displayName: String? = nil,
        languageCode: String? = nil,
        languageName: String? = nil,
        formatName: String? = nil,
        releaseName: String? = nil,
        assessment: SubtitleFinderAssessment,
        timingTransform: SubtitleTimingTransform? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.displayName = displayName ?? fileURL.deletingPathExtension().lastPathComponent
        self.languageCode = languageCode?.lowercased()
        self.languageName = languageName
        self.formatName = formatName ?? fileURL.pathExtension.uppercased()
        self.releaseName = releaseName
        self.assessment = assessment
        self.timingTransform = timingTransform
        if let confidence, confidence.isFinite {
            self.confidence = min(max(confidence, 0), 1)
        } else {
            self.confidence = nil
        }
    }

    fileprivate var stableSortName: String {
        displayName.lowercased(with: .current)
    }
}

extension Array where Element == SubtitleFinderCandidate {
    func sortedForPresentation() -> [SubtitleFinderCandidate] {
        sorted { lhs, rhs in
            if lhs.assessment.sortPriority != rhs.assessment.sortPriority {
                return lhs.assessment.sortPriority < rhs.assessment.sortPriority
            }
            if lhs.confidence != rhs.confidence {
                return (lhs.confidence ?? 0) > (rhs.confidence ?? 0)
            }
            return lhs.stableSortName < rhs.stableSortName
        }
    }
}
