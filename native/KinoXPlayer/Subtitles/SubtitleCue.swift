import Foundation

struct SubtitleCue: Equatable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
