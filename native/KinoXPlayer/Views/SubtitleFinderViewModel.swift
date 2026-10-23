import AppKit
import Combine
import Foundation

@MainActor
final class SubtitleFinderViewModel: ObservableObject {
    typealias SearchHandler = (URL) async throws -> [SubtitleFinderCandidate]
    typealias FolderPicker = @MainActor (URL?) async -> URL?

    enum Phase: Equatable {
        case needsFolder
        case readyToSearch
        case searching
        case results
        case empty
        case failed(String)
    }

    enum OnlinePhase: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
        case downloading(SubtitleFinderRemoteCandidate.ID, SubtitleFinderDestination)
    }

    @Published var mode: SubtitleFinderMode
    @Published private(set) var phase: Phase
    @Published private(set) var folderURL: URL?
    @Published private(set) var candidates: [SubtitleFinderCandidate] = []
    @Published var selectedCandidateID: SubtitleFinderCandidate.ID?
    @Published private(set) var assignments: [SubtitleFinderDestination: SubtitleFinderCandidate.ID] = [:]
    @Published private(set) var isChoosingFolder = false

    @Published var onlineQuery: String
    @Published private(set) var availableLanguages: [SubtitleFinderLanguage]
    @Published private(set) var selectedLanguageCodes: Set<String>
    @Published var apiKeyDraft = ""
    @Published private(set) var apiKeyState: SubtitleFinderAPIKeyState
    @Published private(set) var isEditingAPIKey = false
    @Published var accountUsername = ""
    @Published var accountPassword = ""
    @Published private(set) var accountState: SubtitleFinderAccountState
    @Published private(set) var isEditingAccount = false
    @Published private(set) var onlinePhase: OnlinePhase = .idle
    @Published private(set) var remoteCandidates: [SubtitleFinderRemoteCandidate] = []
    @Published var selectedRemoteCandidateID: SubtitleFinderRemoteCandidate.ID?
    @Published private(set) var onlineAssignments: [SubtitleFinderDestination: SubtitleFinderRemoteCandidate.ID] = [:]

    private let searchHandler: SearchHandler
    private let folderPicker: FolderPicker
    private let onlineConfiguration: SubtitleFinderOnlineConfiguration?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var onlineSearchTask: Task<Void, Never>?
    private var onlineSearchGeneration = UUID()
    private var apiKeyTask: Task<Void, Never>?
    private var apiKeyGeneration = UUID()
    private var accountTask: Task<Void, Never>?
    private var accountGeneration = UUID()
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = UUID()
    private var materializedCandidates: [SubtitleFinderRemoteCandidate.ID: SubtitleFinderCandidate] = [:]
    private var scopedFolderURL: URL?
    private var hasScopedFolderAccess = false

    init(
        initialFolderURL: URL? = nil,
        initialOnlineQuery: String = "",
        search: @escaping SearchHandler,
        folderPicker: @escaping FolderPicker = SubtitleFinderViewModel.pickFolderUsingSystemPanel,
        online: SubtitleFinderOnlineConfiguration? = nil
    ) {
        mode = online == nil ? .local : .online
        folderURL = initialFolderURL
        phase = initialFolderURL == nil ? .needsFolder : .readyToSearch
        searchHandler = search
        self.folderPicker = folderPicker
        onlineConfiguration = online
        onlineQuery = initialOnlineQuery
        let mergedLanguages = Self.mergedLanguages(online?.languages ?? [])
        availableLanguages = mergedLanguages

        let availableCodes = Set(mergedLanguages.map(\.code))
        let requestedCodes = Set((online?.initialLanguages ?? ["ru", "en"]).map { $0.lowercased() })
        let validRequestedCodes = requestedCodes.intersection(availableCodes)
        selectedLanguageCodes = validRequestedCodes.isEmpty
            ? Set(mergedLanguages.prefix(1).map(\.code))
            : validRequestedCodes
        let initialAPIKeyState = online?.initialAPIKeyState ?? .unavailable
        apiKeyState = initialAPIKeyState
        isEditingAPIKey = initialAPIKeyState != .ready
        let initialAccountState = online?.initialAccountState ?? .signedOut
        accountState = initialAccountState
        if case .expired = initialAccountState {
            isEditingAccount = true
        }

        if let initialFolderURL {
            scopedFolderURL = initialFolderURL
            hasScopedFolderAccess = initialFolderURL.startAccessingSecurityScopedResource()
        }
    }

    deinit {
        searchTask?.cancel()
        onlineSearchTask?.cancel()
        apiKeyTask?.cancel()
        accountTask?.cancel()
        downloadTask?.cancel()
        if hasScopedFolderAccess {
            scopedFolderURL?.stopAccessingSecurityScopedResource()
        }
    }

    var selectedCandidate: SubtitleFinderCandidate? {
        guard let selectedCandidateID else { return nil }
        return candidates.first { $0.id == selectedCandidateID }
    }

    var selectedRemoteCandidate: SubtitleFinderRemoteCandidate? {
        guard let selectedRemoteCandidateID else { return nil }
        return remoteCandidates.first { $0.id == selectedRemoteCandidateID }
    }

    var selectedMaterializedCandidate: SubtitleFinderCandidate? {
        guard let selectedRemoteCandidateID else { return nil }
        return materializedCandidates[selectedRemoteCandidateID]
    }

    var keyManagementURL: URL? {
        onlineConfiguration?.keyManagementURL
    }

    var isOnlineConfigured: Bool {
        onlineConfiguration != nil
    }

    var supportsAccountAuthentication: Bool {
        onlineConfiguration?.login != nil && onlineConfiguration?.logout != nil
    }

    var isDownloadingOnlineCandidate: Bool {
        if case .downloading = onlinePhase { return true }
        return false
    }

    func setLanguage(_ code: String, selected: Bool) {
        let normalizedCode = code.lowercased()
        guard availableLanguages.contains(where: { $0.code == normalizedCode }) else { return }

        if selected {
            selectedLanguageCodes.insert(normalizedCode)
        } else if selectedLanguageCodes.count > 1 {
            selectedLanguageCodes.remove(normalizedCode)
        }
    }

    func beginEditingAPIKey() {
        apiKeyDraft = ""
        isEditingAPIKey = true
    }

    func cancelEditingAPIKey() {
        apiKeyDraft = ""
        if apiKeyState == .ready {
            isEditingAPIKey = false
        }
    }

    func validateAndStoreAPIKey() {
        guard let onlineConfiguration else {
            apiKeyState = .unavailable
            return
        }

        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiKeyState = .invalid("Введите API-ключ.")
            isEditingAPIKey = true
            return
        }

        apiKeyTask?.cancel()
        let generation = UUID()
        apiKeyGeneration = generation
        apiKeyState = .validating

        apiKeyTask = Task { [weak self] in
            do {
                try await onlineConfiguration.validateAndStoreKey(key)
                try Task.checkCancellation()
                guard let self, apiKeyGeneration == generation else { return }
                apiKeyDraft = ""
                apiKeyState = .ready
                isEditingAPIKey = false
                if case .failed = onlinePhase {
                    onlinePhase = .idle
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, apiKeyGeneration == generation else { return }
                apiKeyState = .invalid(Self.userFacingMessage(for: error))
                isEditingAPIKey = true
            }
        }
    }

    func removeAPIKey() {
        guard let onlineConfiguration else {
            apiKeyState = .unavailable
            return
        }

        apiKeyTask?.cancel()
        onlineSearchTask?.cancel()
        downloadTask?.cancel()
        accountTask?.cancel()
        onlineSearchGeneration = UUID()
        downloadGeneration = UUID()
        accountGeneration = UUID()
        let generation = UUID()
        apiKeyGeneration = generation
        apiKeyState = .validating

        apiKeyTask = Task { [weak self] in
            do {
                try await onlineConfiguration.removeKey()
                try Task.checkCancellation()
                guard let self, apiKeyGeneration == generation else { return }
                apiKeyDraft = ""
                apiKeyState = .missing
                isEditingAPIKey = true
                remoteCandidates = []
                selectedRemoteCandidateID = nil
                onlineAssignments = [:]
                materializedCandidates = [:]
                accountPassword = ""
                accountState = .signedOut
                isEditingAccount = false
                onlinePhase = .idle
            } catch is CancellationError {
                return
            } catch {
                guard let self, apiKeyGeneration == generation else { return }
                apiKeyState = .invalid(Self.userFacingMessage(for: error))
                isEditingAPIKey = true
            }
        }
    }

    func beginEditingAccount() {
        accountPassword = ""
        isEditingAccount = true
    }

    func cancelEditingAccount() {
        accountPassword = ""
        switch accountState {
        case .signedOut, .signedIn:
            isEditingAccount = false
        case .signingIn, .signingOut, .expired:
            break
        }
    }

    func login() {
        guard let login = onlineConfiguration?.login else { return }

        let username = accountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = accountPassword
        guard !username.isEmpty, !password.isEmpty else {
            accountPassword = ""
            accountState = .expired
            isEditingAccount = true
            onlinePhase = .failed("Введите имя пользователя и пароль OpenSubtitles.")
            return
        }

        accountTask?.cancel()
        let generation = UUID()
        accountGeneration = generation
        accountState = .signingIn

        accountTask = Task { [weak self] in
            do {
                try await login(username, password)
                guard let self else { return }
                accountPassword = ""
                try Task.checkCancellation()
                guard accountGeneration == generation else { return }
                accountState = .signedIn(username)
                isEditingAccount = false
                if case .failed = onlinePhase {
                    onlinePhase = remoteCandidates.isEmpty ? .idle : .results
                }
            } catch is CancellationError {
                self?.accountPassword = ""
            } catch {
                guard let self, accountGeneration == generation else { return }
                accountPassword = ""
                accountState = .expired
                isEditingAccount = true
                onlinePhase = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    func logout() {
        guard let logout = onlineConfiguration?.logout else { return }

        accountTask?.cancel()
        let generation = UUID()
        accountGeneration = generation
        accountState = .signingOut

        accountTask = Task { [weak self] in
            do {
                try await logout()
                try Task.checkCancellation()
                guard let self, accountGeneration == generation else { return }
                accountPassword = ""
                accountState = .signedOut
                isEditingAccount = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, accountGeneration == generation else { return }
                accountPassword = ""
                accountState = .expired
                isEditingAccount = true
                onlinePhase = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    func startOnlineSearch() {
        guard let onlineConfiguration else {
            apiKeyState = .unavailable
            return
        }
        guard apiKeyState == .ready else {
            if apiKeyState != .validating {
                apiKeyState = .missing
                isEditingAPIKey = true
            }
            return
        }

        let query = onlineQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            onlinePhase = .failed("Введите название фильма или сериала.")
            return
        }

        onlineSearchTask?.cancel()
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        let generation = UUID()
        onlineSearchGeneration = generation
        remoteCandidates = []
        selectedRemoteCandidateID = nil
        onlinePhase = .searching

        let languages = availableLanguages
            .map(\.code)
            .filter { selectedLanguageCodes.contains($0) }
        let request = SubtitleFinderOnlineSearchRequest(query: query, languages: languages)

        onlineSearchTask = Task { [weak self] in
            do {
                let results = try await onlineConfiguration.search(request)
                try Task.checkCancellation()
                guard let self, onlineSearchGeneration == generation else { return }

                let sortedResults = Self.sortedRemoteCandidates(results)
                remoteCandidates = sortedResults
                selectedRemoteCandidateID = sortedResults.first?.id
                onlinePhase = sortedResults.isEmpty ? .empty : .results
                refreshAccountStateAfterNetworkOperation()
            } catch is CancellationError {
                guard let self, onlineSearchGeneration == generation else { return }
                onlinePhase = remoteCandidates.isEmpty ? .idle : .results
            } catch {
                guard let self, onlineSearchGeneration == generation else { return }
                refreshAccountStateAfterNetworkOperation()
                if case SubtitleFinderOnlineError.invalidAPIKey = error {
                    apiKeyState = .invalid(SubtitleFinderOnlineError.invalidAPIKey.localizedDescription)
                    isEditingAPIKey = true
                    onlinePhase = .idle
                } else if case SubtitleFinderOnlineError.loginRequired = error {
                    accountState = .expired
                    isEditingAccount = true
                    onlinePhase = .failed(SubtitleFinderOnlineError.loginRequired.localizedDescription)
                } else {
                    onlinePhase = .failed(Self.userFacingMessage(for: error))
                }
            }
        }
    }

    func cancelOnlineSearch() {
        onlineSearchGeneration = UUID()
        onlineSearchTask?.cancel()
        onlineSearchTask = nil
        onlinePhase = remoteCandidates.isEmpty ? .idle : .results
    }

    func dismissOnlineError() {
        onlinePhase = remoteCandidates.isEmpty ? .idle : .results
    }

    func assignSelectedOnline(
        to destination: SubtitleFinderDestination,
        onReady: @escaping @MainActor (SubtitleFinderCandidate, SubtitleFinderDestination) -> Void
    ) {
        guard let onlineConfiguration, let remoteCandidate = selectedRemoteCandidate else { return }

        if let cachedCandidate = materializedCandidates[remoteCandidate.id] {
            onlineAssignments[destination] = remoteCandidate.id
            onlinePhase = .results
            onReady(cachedCandidate, destination)
            return
        }

        downloadTask?.cancel()
        let generation = UUID()
        downloadGeneration = generation
        onlinePhase = .downloading(remoteCandidate.id, destination)

        downloadTask = Task { [weak self] in
            do {
                let localCandidate = try await onlineConfiguration.materialize(remoteCandidate)
                try Task.checkCancellation()
                guard let self, downloadGeneration == generation else { return }

                materializedCandidates[remoteCandidate.id] = localCandidate
                onlineAssignments[destination] = remoteCandidate.id
                onlinePhase = .results
                onReady(localCandidate, destination)
            } catch is CancellationError {
                guard let self, downloadGeneration == generation else { return }
                onlinePhase = .results
            } catch {
                guard let self, downloadGeneration == generation else { return }
                if case SubtitleFinderOnlineError.invalidAPIKey = error {
                    apiKeyState = .invalid(SubtitleFinderOnlineError.invalidAPIKey.localizedDescription)
                    isEditingAPIKey = true
                    onlinePhase = .idle
                } else if case SubtitleFinderOnlineError.loginRequired = error {
                    accountState = .expired
                    isEditingAccount = true
                    onlinePhase = .failed(SubtitleFinderOnlineError.loginRequired.localizedDescription)
                } else {
                    onlinePhase = .failed(Self.userFacingMessage(for: error))
                }
            }
        }
    }

    func cancelOnlineDownload() {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        onlinePhase = remoteCandidates.isEmpty ? .idle : .results
    }

    func assignedDestinations(for remoteCandidate: SubtitleFinderRemoteCandidate) -> [SubtitleFinderDestination] {
        SubtitleFinderDestination.allCases.filter { onlineAssignments[$0] == remoteCandidate.id }
    }

    func isSelectedRemoteCandidateAssigned(to destination: SubtitleFinderDestination) -> Bool {
        guard let selectedRemoteCandidateID else { return false }
        return onlineAssignments[destination] == selectedRemoteCandidateID
    }

    func isMaterialized(_ remoteCandidate: SubtitleFinderRemoteCandidate) -> Bool {
        materializedCandidates[remoteCandidate.id] != nil
    }

    private func refreshAccountStateAfterNetworkOperation() {
        guard case .signedIn = accountState,
              let hasStoredSession = onlineConfiguration?.hasStoredSession,
              !hasStoredSession() else { return }
        accountPassword = ""
        accountState = .signedOut
        isEditingAccount = false
    }

    func chooseFolder() {
        guard !isChoosingFolder else { return }
        isChoosingFolder = true

        Task { [weak self] in
            guard let self else { return }
            let selectedURL = await folderPicker(folderURL)
            isChoosingFolder = false
            guard let selectedURL else { return }
            setFolder(selectedURL)
            startSearch()
        }
    }

    func startSearch() {
        guard let folderURL else {
            phase = .needsFolder
            return
        }

        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        candidates = []
        selectedCandidateID = nil
        assignments = [:]
        phase = .searching

        let searchHandler = self.searchHandler
        searchTask = Task { [weak self] in
            do {
                let results = try await searchHandler(folderURL)
                try Task.checkCancellation()

                guard let self, searchGeneration == generation else { return }
                let sortedResults = results.sortedForPresentation()
                candidates = sortedResults
                selectedCandidateID = sortedResults.first?.id
                phase = sortedResults.isEmpty ? .empty : .results
            } catch is CancellationError {
                guard let self, searchGeneration == generation else { return }
                phase = .readyToSearch
            } catch {
                guard let self, searchGeneration == generation else { return }
                candidates = []
                selectedCandidateID = nil
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSearch() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        phase = folderURL == nil ? .needsFolder : .readyToSearch
    }

    func assignSelected(to destination: SubtitleFinderDestination) -> SubtitleFinderCandidate? {
        guard let candidate = selectedCandidate else { return nil }
        assignments[destination] = candidate.id
        return candidate
    }

    func assignedDestinations(for candidate: SubtitleFinderCandidate) -> [SubtitleFinderDestination] {
        SubtitleFinderDestination.allCases.filter { assignments[$0] == candidate.id }
    }

    func isSelectedCandidateAssigned(to destination: SubtitleFinderDestination) -> Bool {
        guard let selectedCandidateID else { return false }
        return assignments[destination] == selectedCandidateID
    }

    private func setFolder(_ url: URL) {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil

        if hasScopedFolderAccess {
            scopedFolderURL?.stopAccessingSecurityScopedResource()
        }

        folderURL = url
        scopedFolderURL = url
        hasScopedFolderAccess = url.startAccessingSecurityScopedResource()
        candidates = []
        selectedCandidateID = nil
        assignments = [:]
        phase = .readyToSearch
    }

    private static func mergedLanguages(_ configuredLanguages: [SubtitleFinderLanguage]) -> [SubtitleFinderLanguage] {
        var languageByCode: [String: SubtitleFinderLanguage] = [:]
        for language in SubtitleFinderLanguage.common + configuredLanguages {
            languageByCode[language.code] = language
        }

        let commonCodes = Set(SubtitleFinderLanguage.common.map(\.code))
        let common = SubtitleFinderLanguage.common.compactMap { languageByCode[$0.code] }
        let additional = languageByCode.values
            .filter { !commonCodes.contains($0.code) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return common + additional
    }

    private static func sortedRemoteCandidates(
        _ candidates: [SubtitleFinderRemoteCandidate]
    ) -> [SubtitleFinderRemoteCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isHashMatch != rhs.isHashMatch {
                return lhs.isHashMatch && !rhs.isHashMatch
            }
            if lhs.rating != rhs.rating {
                return (lhs.rating ?? -1) > (rhs.rating ?? -1)
            }
            if lhs.downloadCount != rhs.downloadCount {
                return (lhs.downloadCount ?? -1) > (rhs.downloadCount ?? -1)
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    static func pickFolderUsingSystemPanel(initialDirectoryURL: URL?) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Выберите папку с субтитрами"
            panel.message = "KinoX проверит файлы в этой папке и покажет наиболее подходящие."
            panel.prompt = "Выбрать папку"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = initialDirectoryURL

            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
