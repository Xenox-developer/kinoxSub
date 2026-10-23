import Foundation

public enum OpenSubtitlesMatchKind: Int, Codable, Sendable {
    case query = 0
    case hash = 1
    case exactHash = 2
}

public struct OpenSubtitlesCandidate: Identifiable, Hashable, Sendable {
    public var id: Int { fileID }

    public let fileID: Int
    public let subtitleID: String?
    public let language: String
    public let fileName: String?
    public let releaseName: String?
    public let featureTitle: String?
    public let featureYear: Int?
    public let framesPerSecond: Double?
    public let hearingImpaired: Bool
    public let forced: Bool
    public let rating: Double?
    public let downloadCount: Int?
    public let matchKind: OpenSubtitlesMatchKind

    public init(
        fileID: Int,
        subtitleID: String? = nil,
        language: String,
        fileName: String? = nil,
        releaseName: String? = nil,
        featureTitle: String? = nil,
        featureYear: Int? = nil,
        framesPerSecond: Double? = nil,
        hearingImpaired: Bool = false,
        forced: Bool = false,
        rating: Double? = nil,
        downloadCount: Int? = nil,
        matchKind: OpenSubtitlesMatchKind
    ) {
        self.fileID = fileID
        self.subtitleID = subtitleID
        self.language = language
        self.fileName = fileName
        self.releaseName = releaseName
        self.featureTitle = featureTitle
        self.featureYear = featureYear
        self.framesPerSecond = framesPerSecond
        self.hearingImpaired = hearingImpaired
        self.forced = forced
        self.rating = rating
        self.downloadCount = downloadCount
        self.matchKind = matchKind
    }
}

public struct MaterializedOpenSubtitle: Equatable, Sendable {
    public let fileID: Int
    public let fileURL: URL
    public let cueCount: Int
    public let encodingName: String

    public init(fileID: Int, fileURL: URL, cueCount: Int, encodingName: String) {
        self.fileID = fileID
        self.fileURL = fileURL
        self.cueCount = cueCount
        self.encodingName = encodingName
    }
}

public struct OpenSubtitlesMovieFingerprint: Equatable, Sendable {
    public let movieHash: String
    public let fileSize: UInt64

    public init(movieHash: String, fileSize: UInt64) {
        self.movieHash = movieHash
        self.fileSize = fileSize
    }
}

public enum OpenSubtitlesError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case loginRequired
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case downloadLimitExceeded(resetTime: String?)
    case offline
    case provider(statusCode: Int?, message: String?)
    case invalidPayload
    case invalidVideo
    case unsafeURL
    case payloadTooLarge(maximumBytes: Int)
    case keychain(status: Int32)
    case cache(message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Добавьте API-ключ OpenSubtitles в настройках."
        case .invalidAPIKey:
            return "OpenSubtitles отклонил API-ключ. Проверьте ключ и попробуйте снова."
        case .loginRequired:
            return "Для скачивания войдите в учётную запись OpenSubtitles."
        case .unauthorized:
            return "OpenSubtitles не удалось подтвердить авторизацию."
        case .forbidden:
            return "OpenSubtitles запретил этот запрос. Проверьте API-ключ и User-Agent приложения."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Лимит запросов OpenSubtitles исчерпан. Повторите через \(Int(retryAfter.rounded(.up))) сек."
            }
            return "Лимит запросов OpenSubtitles исчерпан. Попробуйте позже."
        case .downloadLimitExceeded(let resetTime):
            if let resetTime, !resetTime.isEmpty {
                return "Дневной лимит скачиваний OpenSubtitles исчерпан. Лимит обновится: \(resetTime)."
            }
            return "Дневной лимит скачиваний OpenSubtitles исчерпан. Попробуйте позже."
        case .offline:
            return "Нет соединения с интернетом."
        case .provider(_, let message):
            if let message, !message.isEmpty {
                return "Ошибка OpenSubtitles: \(message)"
            }
            return "OpenSubtitles временно недоступен."
        case .invalidPayload:
            return "OpenSubtitles вернул повреждённые или неподдерживаемые данные."
        case .invalidVideo:
            return "Не удалось вычислить идентификатор видео для поиска субтитров."
        case .unsafeURL:
            return "OpenSubtitles вернул небезопасный адрес скачивания."
        case .payloadTooLarge(let maximumBytes):
            let mebibytes = maximumBytes / 1_048_576
            return "Файл субтитров превышает допустимый размер \(mebibytes) МБ."
        case .keychain:
            return "Не удалось прочитать или сохранить данные OpenSubtitles в Связке ключей."
        case .cache(let message):
            return "Не удалось сохранить субтитры: \(message)"
        case .cancelled:
            return "Операция отменена."
        }
    }
}

struct OpenSubtitlesStoredSession: Codable, Equatable, Sendable {
    let token: String
    let baseURL: URL
}
