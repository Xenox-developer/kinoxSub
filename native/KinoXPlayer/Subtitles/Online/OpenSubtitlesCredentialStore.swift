import Foundation
import Security

protocol OpenSubtitlesCredentialStoring: Sendable {
    func apiKey() throws -> String?
    func storeAPIKey(_ key: String) throws
    func removeAPIKey() throws

    func session() throws -> OpenSubtitlesStoredSession?
    func storeSession(_ session: OpenSubtitlesStoredSession) throws
    func removeSession() throws
}

final class KeychainOpenSubtitlesCredentialStore: OpenSubtitlesCredentialStoring, @unchecked Sendable {
    private enum Account {
        static let apiKey = "api-key"
        static let session = "session"
    }

    private let service: String

    init(service: String? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "KinoXPlayer"
        self.service = service ?? "\(bundleID).OpenSubtitles"
    }

    func apiKey() throws -> String? {
        guard let data = try read(account: Account.apiKey) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw OpenSubtitlesError.invalidPayload
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func storeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw OpenSubtitlesError.invalidAPIKey
        }
        try write(data, account: Account.apiKey)
    }

    func removeAPIKey() throws {
        try delete(account: Account.apiKey)
        // A session is tied to the API key that created it.
        try delete(account: Account.session)
    }

    func session() throws -> OpenSubtitlesStoredSession? {
        guard let data = try read(account: Account.session) else { return nil }
        do {
            return try JSONDecoder().decode(OpenSubtitlesStoredSession.self, from: data)
        } catch {
            try? delete(account: Account.session)
            throw OpenSubtitlesError.invalidPayload
        }
    }

    func storeSession(_ session: OpenSubtitlesStoredSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw OpenSubtitlesError.invalidPayload
        }
        try write(data, account: Account.session)
    }

    func removeSession() throws {
        try delete(account: Account.session)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OpenSubtitlesError.invalidPayload
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw OpenSubtitlesError.keychain(status: status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updates = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OpenSubtitlesError.keychain(status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenSubtitlesError.keychain(status: addStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenSubtitlesError.keychain(status: status)
        }
    }
}
