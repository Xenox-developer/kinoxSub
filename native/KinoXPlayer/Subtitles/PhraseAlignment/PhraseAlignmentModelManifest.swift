import CryptoKit
import Foundation

struct PhraseAlignmentModelAsset: Codable, Equatable, Sendable {
    let remotePath: String
    let relativePath: String
    let byteCount: Int64
    let sha256: String

    var remoteURL: URL {
        PhraseAlignmentModelManifest.downloadBaseURL
            .appendingPathComponent(remotePath, isDirectory: false)
    }
}

enum PhraseAlignmentModelManifest {
    static let repository = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    static let revision = "a39062b9112d981477eb4dcdc8b2e9f1a4b5a883"
    /// Changes whenever tokenization, pooling, or vector normalization changes.
    /// It deliberately participates in every derived-cache key.
    static let embeddingRuntimeVersion = "tokenizers-0.1.24-xlmr-meanpool-l2-v1"
    static let modelVersion = "paraphrase-multilingual-MiniLM-L12-v2-coreml-fp16@\(revision)+\(embeddingRuntimeVersion)"
    static let schemaVersion = 1
    static let maximumSequenceLength = 128
    static let embeddingDimension = 384

    static let downloadBaseURL = URL(
        string: "https://huggingface.co/\(repository)/resolve/\(revision)/"
    )!

    static let assets: [PhraseAlignmentModelAsset] = [
        PhraseAlignmentModelAsset(
            remotePath: "coreml/feature-extraction/float16_model.mlpackage/Manifest.json",
            relativePath: "Model.mlpackage/Manifest.json",
            byteCount: 617,
            sha256: "e48baf0e5008504316fd59bb30bb229276f34972c726cfbd836a22ee462049b7"
        ),
        PhraseAlignmentModelAsset(
            remotePath: "coreml/feature-extraction/float16_model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            relativePath: "Model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 170_634,
            sha256: "eeea99dfac70be10562a8819d2aa2889664f43f3e4cb0d7bdc608c48d68a8ea3"
        ),
        PhraseAlignmentModelAsset(
            remotePath: "coreml/feature-extraction/float16_model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            relativePath: "Model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 235_320_320,
            sha256: "08f6d1d0a172aed2a04b12412a21efa8855e32618342062e2c196711da0c5332"
        ),
        PhraseAlignmentModelAsset(
            remotePath: "tokenizer.json",
            relativePath: "Tokenizer/tokenizer.json",
            byteCount: 9_081_518,
            sha256: "2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8"
        ),
        PhraseAlignmentModelAsset(
            remotePath: "tokenizer_config.json",
            relativePath: "Tokenizer/tokenizer_config.source.json",
            byteCount: 480,
            sha256: "cac868512d555e9ac37a33c28300d36931ae4b5ddff43f1ca9bdacfe6fcd9dc8"
        ),
        PhraseAlignmentModelAsset(
            remotePath: "config.json",
            relativePath: "Tokenizer/config.json",
            byteCount: 645,
            sha256: "6300193cb75e01cf80c96decef7187dfb33094d97cc1490b7ead6ff134476e4e"
        ),
    ]

    static let totalDownloadByteCount = assets.reduce(Int64(0)) { partial, asset in
        partial + asset.byteCount
    }

    static let modelPackageRelativePath = "Model.mlpackage"
    static let compiledModelRelativePath = "CompiledModel.mlmodelc"
    static let tokenizerRelativePath = "Tokenizer"
    static let sourceTokenizerConfigRelativePath = "Tokenizer/tokenizer_config.source.json"
    static let runtimeTokenizerConfigRelativePath = "Tokenizer/tokenizer_config.json"
    // swift-transformers 0.1.24 exposes its generic Unigram implementation
    // through this registered class name. Tokenization behavior still comes
    // entirely from the pinned XLM-R tokenizer.json.
    static let compatibleUnigramTokenizerClass = "T5Tokenizer"
    static let receiptFileName = "installation.json"
}

struct PhraseAlignmentModelInstallationReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let modelVersion: String
    let repository: String
    let revision: String
    let installedAt: Date
    let assets: [PhraseAlignmentModelAsset]

    static func current(installedAt: Date = Date()) -> Self {
        Self(
            schemaVersion: PhraseAlignmentModelManifest.schemaVersion,
            modelVersion: PhraseAlignmentModelManifest.modelVersion,
            repository: PhraseAlignmentModelManifest.repository,
            revision: PhraseAlignmentModelManifest.revision,
            installedAt: installedAt,
            assets: PhraseAlignmentModelManifest.assets
        )
    }

    var matchesCurrentManifest: Bool {
        schemaVersion == PhraseAlignmentModelManifest.schemaVersion
            && modelVersion == PhraseAlignmentModelManifest.modelVersion
            && repository == PhraseAlignmentModelManifest.repository
            && revision == PhraseAlignmentModelManifest.revision
            && assets == PhraseAlignmentModelManifest.assets
    }
}

enum PhraseAlignmentModelError: LocalizedError, Equatable {
    case storageUnavailable
    case modelNotInstalled
    case incompleteInstallation
    case invalidFileSize(path: String, expected: Int64, actual: Int64)
    case invalidFileHash(path: String)
    case invalidModelOutput
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Не удалось открыть папку моделей приложения."
        case .modelNotInstalled:
            return "Локальная модель связывания фраз не установлена."
        case .incompleteInstallation:
            return "Установка модели повреждена или не завершена."
        case let .invalidFileSize(path, expected, actual):
            return "Файл модели \(path) имеет неверный размер (\(actual) вместо \(expected) байт)."
        case let .invalidFileHash(path):
            return "Не удалось проверить целостность файла модели \(path)."
        case .invalidModelOutput:
            return "Локальная модель вернула данные неожиданного формата."
        case .invalidEmbedding:
            return "Локальная модель не смогла построить смысловой вектор фразы."
        }
    }
}

enum PhraseAlignmentModelFileVerifier {
    static func verify(asset: PhraseAlignmentModelAsset, at fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw PhraseAlignmentModelError.incompleteInstallation
        }
        let actualByteCount = Int64(values.fileSize ?? -1)
        guard actualByteCount == asset.byteCount else {
            throw PhraseAlignmentModelError.invalidFileSize(
                path: asset.relativePath,
                expected: asset.byteCount,
                actual: actualByteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            throw PhraseAlignmentModelError.invalidFileHash(path: asset.relativePath)
        }
    }
}
