import Foundation

public enum OpenSubtitlesMovieHash {
    public static let chunkSize = 64 * 1_024
    public static let minimumFileSize = UInt64(chunkSize * 2)
    public static let maximumFileSize: UInt64 = 9_000_000_000

    public static func calculate(for videoURL: URL) throws -> OpenSubtitlesMovieFingerprint {
        let didStartSecurityScope = videoURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                videoURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let handle = try FileHandle(forReadingFrom: videoURL)
            defer { try? handle.close() }

            let fileSize = try handle.seekToEnd()
            guard fileSize > minimumFileSize, fileSize < maximumFileSize else {
                throw OpenSubtitlesError.invalidVideo
            }

            try handle.seek(toOffset: 0)
            guard let first = try handle.read(upToCount: chunkSize), first.count == chunkSize else {
                throw OpenSubtitlesError.invalidVideo
            }

            try handle.seek(toOffset: fileSize - UInt64(chunkSize))
            guard let last = try handle.read(upToCount: chunkSize), last.count == chunkSize else {
                throw OpenSubtitlesError.invalidVideo
            }

            var hash = fileSize
            hash = addingWords(in: first, to: hash)
            hash = addingWords(in: last, to: hash)

            return OpenSubtitlesMovieFingerprint(
                movieHash: String(format: "%016llx", hash),
                fileSize: fileSize
            )
        } catch let error as OpenSubtitlesError {
            throw error
        } catch {
            throw OpenSubtitlesError.invalidVideo
        }
    }

    static func hash(fileSize: UInt64, firstChunk: Data, lastChunk: Data) throws -> String {
        guard firstChunk.count == chunkSize, lastChunk.count == chunkSize else {
            throw OpenSubtitlesError.invalidVideo
        }
        var result = addingWords(in: firstChunk, to: fileSize)
        result = addingWords(in: lastChunk, to: result)
        return String(format: "%016llx", result)
    }

    private static func addingWords(in data: Data, to initialValue: UInt64) -> UInt64 {
        let bytes = [UInt8](data)
        var result = initialValue

        for offset in stride(from: 0, to: bytes.count, by: 8) {
            var word: UInt64 = 0
            for byteOffset in 0..<8 {
                word |= UInt64(bytes[offset + byteOffset]) << UInt64(byteOffset * 8)
            }
            result &+= word
        }

        return result
    }
}
