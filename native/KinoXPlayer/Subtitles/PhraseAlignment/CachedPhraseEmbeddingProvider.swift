import CryptoKit
import Foundation

actor CachedPhraseEmbeddingProvider: PhraseEmbeddingProviding {
    nonisolated let modelVersion: String

    private static let magic = Data([0x4B, 0x58, 0x45, 0x56]) // KXEV
    private static let formatVersion: UInt16 = 1
    private let base: any PhraseEmbeddingProviding
    private let rootURL: URL
    private let budgetRootURL: URL
    private let derivedCacheBudget: PhraseAlignmentDerivedCacheBudget
    private let fileManager: FileManager

    init(
        base: any PhraseEmbeddingProviding,
        rootURL: URL? = nil,
        derivedCacheBudget: PhraseAlignmentDerivedCacheBudget = .shared
    ) {
        let fileManager = FileManager.default
        self.base = base
        self.modelVersion = base.modelVersion
        self.fileManager = fileManager
        self.derivedCacheBudget = derivedCacheBudget
        if let rootURL {
            self.rootURL = rootURL
            self.budgetRootURL = rootURL
        } else {
            let budgetRootURL = Self.defaultBudgetRootURL(fileManager: fileManager)
            self.rootURL = Self.defaultRootURL(
                modelVersion: base.modelVersion,
                budgetRootURL: budgetRootURL
            )
            self.budgetRootURL = budgetRootURL
        }
    }

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        await derivedCacheBudget.pruneOnFirstAccess(rootURL: budgetRootURL)

        var values = Array<[Float]?>(repeating: nil, count: texts.count)
        var missingByKey: [String: (text: String, indices: [Int])] = [:]

        for (index, text) in texts.enumerated() {
            let key = Self.key(modelVersion: modelVersion, text: text)
            if let cached = readVector(forKey: key) {
                values[index] = cached
            } else if missingByKey[key] == nil {
                missingByKey[key] = (text, [index])
            } else {
                missingByKey[key]?.indices.append(index)
            }
        }

        if !missingByKey.isEmpty {
            let orderedKeys = missingByKey.keys.sorted()
            let missingTexts = orderedKeys.compactMap { missingByKey[$0]?.text }
            let generated = try await base.embeddings(for: missingTexts)
            guard generated.count == missingTexts.count else {
                throw PhraseEmbeddingError.countMismatch(
                    expected: missingTexts.count,
                    actual: generated.count
                )
            }

            var expectedDimension: Int?
            for (position, key) in orderedKeys.enumerated() {
                let vector = generated[position]
                try Self.validate(vector, expectedDimension: &expectedDimension)
                if let indices = missingByKey[key]?.indices {
                    for index in indices { values[index] = vector }
                }
                try? storeVector(vector, forKey: key)
            }
            await derivedCacheBudget.prune(
                rootURL: budgetRootURL
            )
        }

        let resolved = values.compactMap { $0 }
        guard resolved.count == texts.count else {
            throw PhraseEmbeddingError.countMismatch(
                expected: texts.count,
                actual: resolved.count
            )
        }
        return resolved
    }

    private static func validate(
        _ vector: [Float],
        expectedDimension: inout Int?
    ) throws {
        guard !vector.isEmpty, vector.count <= Int(UInt16.max) else {
            throw PhraseEmbeddingError.emptyVector
        }
        if let expectedDimension, expectedDimension != vector.count {
            throw PhraseEmbeddingError.inconsistentDimensions
        }
        expectedDimension = vector.count
        guard vector.allSatisfy(\.isFinite) else {
            throw PhraseEmbeddingError.nonFiniteValue
        }
    }

    private func readVector(forKey key: String) -> [Float]? {
        let url = fileURL(forKey: key)
        guard isSafeRegularFile(url),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 8,
              data.prefix(4) == Self.magic else {
            return nil
        }

        let version = UInt16(data[4]) | UInt16(data[5]) << 8
        let dimension = Int(UInt16(data[6]) | UInt16(data[7]) << 8)
        guard version == Self.formatVersion,
              dimension > 0,
              data.count == 8 + dimension * 2 else {
            removeSafeRegularFile(at: url)
            return nil
        }

        var vector: [Float] = []
        vector.reserveCapacity(dimension)
        for index in 0..<dimension {
            let offset = 8 + index * 2
            let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            let value = Self.float(fromHalfBits: bits)
            guard value.isFinite else {
                removeSafeRegularFile(at: url)
                return nil
            }
            vector.append(value)
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return vector
    }

    private func storeVector(_ vector: [Float], forKey key: String) throws {
        try prepareRoot()
        let directory = directoryURL(forKey: key)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        var data = Self.magic
        Self.append(Self.formatVersion, to: &data)
        Self.append(UInt16(vector.count), to: &data)
        for value in vector {
            Self.append(Self.halfBits(from: value), to: &data)
        }

        let url = fileURL(forKey: key)
        if fileManager.fileExists(atPath: url.path), !isSafeRegularFile(url) {
            throw CocoaError(.fileWriteFileExists)
        }
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    /// Portable IEEE-754 binary16 conversion. Swift's `Float16` is unavailable
    /// for the x86_64 slice in the Xcode 15.1 toolchain used by this project.
    private static func halfBits(from value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7F_FFFF

        if exponent <= 0 {
            guard exponent >= -10 else { return sign }
            let significand = mantissa | 0x80_0000
            let shift = UInt32(14 - exponent)
            var rounded = UInt16(significand >> shift)
            let remainderMask = (UInt32(1) << shift) - 1
            let remainder = significand & remainderMask
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && rounded & 1 == 1) {
                rounded &+= 1
            }
            return sign | rounded
        }

        if exponent >= 31 {
            return sign | 0x7C00
        }

        var encoded = UInt16(exponent << 10) | UInt16(mantissa >> 13)
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && encoded & 1 == 1) {
            encoded &+= 1
        }
        return sign | encoded
    }

    private static func float(fromHalfBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        var mantissa = UInt32(bits & 0x03FF)
        let floatBits: UInt32

        switch exponent {
        case 0 where mantissa == 0:
            floatBits = sign
        case 0:
            var unbiasedExponent = -14
            while mantissa & 0x0400 == 0 {
                mantissa <<= 1
                unbiasedExponent -= 1
            }
            mantissa &= 0x03FF
            floatBits = sign
                | UInt32(unbiasedExponent + 127) << 23
                | mantissa << 13
        case 31:
            floatBits = sign | 0x7F80_0000 | mantissa << 13
        default:
            floatBits = sign
                | UInt32(exponent - 15 + 127) << 23
                | mantissa << 13
        }
        return Float(bitPattern: floatBits)
    }

    private func prepareRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
            var mutableURL = rootURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(resourceValues)
        }
    }

    private func directoryURL(forKey key: String) -> URL {
        rootURL.appendingPathComponent(String(key.prefix(2)), isDirectory: true)
    }

    private func fileURL(forKey key: String) -> URL {
        directoryURL(forKey: key)
            .appendingPathComponent("\(key).f16", isDirectory: false)
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard url.pathExtension == "f16",
              url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == rootURL.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
              ]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func removeSafeRegularFile(at url: URL) {
        guard isSafeRegularFile(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func key(modelVersion: String, text: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(modelVersion.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(text.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultBudgetRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("KinoXPlayer", isDirectory: true)
            .appendingPathComponent("Phrase Alignment Cache", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func defaultRootURL(
        modelVersion: String,
        budgetRootURL: URL
    ) -> URL {
        let versionDigest = SHA256.hash(data: Data(modelVersion.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return budgetRootURL
            .appendingPathComponent("Embeddings", isDirectory: true)
            .appendingPathComponent(versionDigest, isDirectory: true)
    }
}

/// Serializes eviction for alignment JSON and Float16 embeddings under one
/// 128 MiB budget. The cache remains disposable and never contains source SRT.
actor PhraseAlignmentDerivedCacheBudget {
    static let shared = PhraseAlignmentDerivedCacheBudget()

    private static let defaultMaximumAlignmentCount = 80
    private static let defaultMaximumAllocatedByteCount: Int64 = 128 * 1_024 * 1_024

    private let maximumAlignmentCount: Int
    private let maximumAllocatedByteCount: Int64
    private var rootsPrunedOnAccess: Set<String> = []

    private struct Entry {
        let url: URL
        let date: Date
        let byteCount: Int64
        let isAlignment: Bool
    }

    init(
        maximumAlignmentCount: Int = defaultMaximumAlignmentCount,
        maximumAllocatedByteCount: Int64 = defaultMaximumAllocatedByteCount
    ) {
        precondition(maximumAlignmentCount >= 0)
        precondition(maximumAllocatedByteCount >= 0)
        self.maximumAlignmentCount = maximumAlignmentCount
        self.maximumAllocatedByteCount = maximumAllocatedByteCount
    }

    /// Existing installations can start above the combined budget because JSON
    /// and embeddings previously had separate limits. Scan a root once per
    /// process even when every lookup is a cache hit.
    func pruneOnFirstAccess(rootURL: URL) {
        let identity = Self.rootIdentity(rootURL)
        guard rootsPrunedOnAccess.insert(identity).inserted else { return }
        pruneContents(rootURL: rootURL)
    }

    func prune(rootURL: URL) {
        rootsPrunedOnAccess.insert(Self.rootIdentity(rootURL))
        pruneContents(rootURL: rootURL)
    }

    private func pruneContents(rootURL: URL) {
        let fileManager = FileManager.default
        guard Self.isSafeDirectory(rootURL) else { return }

        var entries = Self.alignmentEntries(in: rootURL, fileManager: fileManager)
        let alignments = entries
            .filter(\.isAlignment)
            .sorted { $0.date > $1.date }
        if alignments.count > maximumAlignmentCount {
            var remainingCount = alignments.count
            var removed: Set<URL> = []
            for entry in alignments.reversed() where remainingCount > maximumAlignmentCount {
                guard Self.remove(entry, fileManager: fileManager) else { continue }
                removed.insert(entry.url)
                remainingCount -= 1
            }
            entries.removeAll { removed.contains($0.url) }
        }

        entries.append(contentsOf: Self.embeddingEntries(
            in: rootURL,
            fileManager: fileManager
        ))
        var total = entries.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
        guard total > maximumAllocatedByteCount else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maximumAllocatedByteCount else { break }
            guard Self.remove(entry, fileManager: fileManager) else { continue }
            total -= max(entry.byteCount, 0)
        }
    }

    private static func alignmentEntries(
        in rootURL: URL,
        fileManager: FileManager
    ) -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: resourceKeyList,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  isDigest(String(url.deletingPathExtension().lastPathComponent), count: 64)
            else { return nil }
            return entry(for: url, alignment: true)
        }
    }

    private static func embeddingEntries(
        in rootURL: URL,
        fileManager: FileManager
    ) -> [Entry] {
        var entries = versionEmbeddingEntries(in: rootURL, fileManager: fileManager)
        let embeddingsRoot = rootURL.appendingPathComponent("Embeddings", isDirectory: true)
        if isSafeDirectory(embeddingsRoot) {
            entries.append(contentsOf: nestedEmbeddingEntries(
                in: embeddingsRoot,
                fileManager: fileManager
            ))
        }
        // Custom roots contain prefix folders directly, while the default root
        // nests them below Embeddings/<model>. A migration can contain both.
        return entries
    }

    private static func nestedEmbeddingEntries(
        in embeddingsRoot: URL,
        fileManager: FileManager
    ) -> [Entry] {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: embeddingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return versions.flatMap { versionURL -> [Entry] in
            guard isDigest(versionURL.lastPathComponent, count: 16),
                  isSafeDirectory(versionURL) else { return [] }
            return versionEmbeddingEntries(in: versionURL, fileManager: fileManager)
        }
    }

    private static func versionEmbeddingEntries(
        in versionURL: URL,
        fileManager: FileManager
    ) -> [Entry] {
        guard let prefixes = try? fileManager.contentsOfDirectory(
            at: versionURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return prefixes.flatMap { prefixURL -> [Entry] in
            guard isDigest(prefixURL.lastPathComponent, count: 2),
                  isSafeDirectory(prefixURL),
                  let files = try? fileManager.contentsOfDirectory(
                    at: prefixURL,
                    includingPropertiesForKeys: resourceKeyList,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                  ) else { return [] }
            return files.compactMap { url in
                guard url.pathExtension.lowercased() == "f16",
                      isDigest(String(url.deletingPathExtension().lastPathComponent), count: 64)
                else { return nil }
                return entry(for: url, alignment: false)
            }
        }
    }

    private static let resourceKeyList: [URLResourceKey] = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
    ]

    private static let resourceKeySet = Set(resourceKeyList)

    private static func entry(for url: URL, alignment: Bool) -> Entry? {
        guard let values = try? url.resourceValues(forKeys: resourceKeySet),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return Entry(
            url: url,
            date: values.contentModificationDate ?? .distantPast,
            byteCount: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
            isAlignment: alignment
        )
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isDigest(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy(\.isHexDigit)
    }

    private static func remove(_ entry: Entry, fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: entry.url)
            return true
        } catch {
            // A concurrent pruner may already have removed it. Only treat that
            // as success when the path has actually disappeared.
            return !fileManager.fileExists(atPath: entry.url.path)
        }
    }

    private static func rootIdentity(_ rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }
}
