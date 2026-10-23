import CoreML
import Foundation
import Tokenizers

actor CoreMLPhraseEmbeddingProvider: PhraseEmbeddingProviding {
    nonisolated let modelVersion: String = PhraseAlignmentModelManifest.modelVersion

    private let model: MLModel
    private let tokenizer: any Tokenizer

    private init(model: MLModel, tokenizer: any Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    static func load(
        compiledModelURL: URL,
        tokenizerDirectoryURL: URL
    ) async throws -> CoreMLPhraseEmbeddingProvider {
        async let tokenizer = AutoTokenizer.from(modelFolder: tokenizerDirectoryURL)
        async let model: MLModel = Task.detached(priority: .utility) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            return try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        }.value
        return try await CoreMLPhraseEmbeddingProvider(model: model, tokenizer: tokenizer)
    }

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)

        for text in texts {
            try Task.checkCancellation()
            result.append(try embedding(for: text))
        }
        return result
    }

    private func embedding(for text: String) throws -> [Float] {
        var tokenIDs = tokenizer.encode(text: text)
        guard !tokenIDs.isEmpty else {
            throw PhraseAlignmentModelError.invalidEmbedding
        }

        let maximumLength = PhraseAlignmentModelManifest.maximumSequenceLength
        if tokenIDs.count > maximumLength {
            let finalSpecialToken = tokenIDs[tokenIDs.count - 1]
            tokenIDs = Array(tokenIDs.prefix(maximumLength - 1))
            tokenIDs.append(finalSpecialToken)
        }

        let inputIDs = try MLMultiArray(
            shape: [1, NSNumber(value: tokenIDs.count)],
            dataType: .int32
        )
        let attentionMask = try MLMultiArray(
            shape: [1, NSNumber(value: tokenIDs.count)],
            dataType: .int32
        )
        for (index, tokenID) in tokenIDs.enumerated() {
            inputIDs[index] = NSNumber(value: Int32(tokenID))
            attentionMask[index] = 1
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIDs,
            "attention_mask": attentionMask,
        ])
        let prediction = try model.prediction(from: input)
        guard let hiddenState = prediction
            .featureValue(for: "last_hidden_state")?
            .multiArrayValue,
            hiddenState.shape.count == 3,
            hiddenState.shape[0].intValue == 1,
            hiddenState.shape[1].intValue == tokenIDs.count,
            hiddenState.shape[2].intValue == PhraseAlignmentModelManifest.embeddingDimension,
            hiddenState.strides.count == 3 else {
            throw PhraseAlignmentModelError.invalidModelOutput
        }

        let tokenStride = hiddenState.strides[1].intValue
        let embeddingStride = hiddenState.strides[2].intValue
        var pooled = Array(
            repeating: Float.zero,
            count: PhraseAlignmentModelManifest.embeddingDimension
        )

        for tokenIndex in tokenIDs.indices {
            let tokenOffset = tokenIndex * tokenStride
            for dimension in pooled.indices {
                let value = Float(
                    truncating: hiddenState[tokenOffset + dimension * embeddingStride]
                )
                pooled[dimension] += value
            }
        }

        let inverseTokenCount = 1 / Float(tokenIDs.count)
        var squaredNorm = Float.zero
        for index in pooled.indices {
            pooled[index] *= inverseTokenCount
            squaredNorm += pooled[index] * pooled[index]
        }
        guard squaredNorm.isFinite, squaredNorm > Float.leastNonzeroMagnitude else {
            throw PhraseAlignmentModelError.invalidEmbedding
        }

        let inverseNorm = 1 / sqrt(squaredNorm)
        for index in pooled.indices {
            pooled[index] *= inverseNorm
            guard pooled[index].isFinite else {
                throw PhraseAlignmentModelError.invalidEmbedding
            }
        }
        return pooled
    }
}
