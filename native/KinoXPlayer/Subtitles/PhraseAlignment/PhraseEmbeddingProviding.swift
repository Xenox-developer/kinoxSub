import Foundation

/// Supplies language-independent sentence vectors for phrase matching.
///
/// Implementations are expected to return one vector for every input string, in
/// the same order. The aligner normalizes vectors before comparing them, so the
/// provider does not need to perform L2 normalization itself.
protocol PhraseEmbeddingProviding: Sendable {
    var modelVersion: String { get }

    func embeddings(for texts: [String]) async throws -> [[Float]]
}

enum PhraseEmbeddingError: LocalizedError, Equatable, Sendable {
    case countMismatch(expected: Int, actual: Int)
    case inconsistentDimensions
    case emptyVector
    case nonFiniteValue

    var errorDescription: String? {
        switch self {
        case .countMismatch(let expected, let actual):
            return "Модель вернула \(actual) векторов вместо \(expected)."
        case .inconsistentDimensions:
            return "Модель вернула векторы разной длины."
        case .emptyVector:
            return "Модель вернула пустой смысловой вектор."
        case .nonFiniteValue:
            return "Модель вернула некорректные числовые значения."
        }
    }
}
