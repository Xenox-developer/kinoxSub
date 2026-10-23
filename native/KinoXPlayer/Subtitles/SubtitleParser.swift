import Foundation

struct ParsedSubtitle: Equatable, Sendable {
    let cues: [SubtitleCue]
    let encodingName: String
}

enum SubtitleParserError: LocalizedError, Equatable {
    case unableToDecode(String)
    case noCues

    var errorDescription: String? {
        switch self {
        case .unableToDecode(let encoding):
            return "Не удалось прочитать файл субтитров в кодировке \(encoding)."
        case .noCues:
            return "В файле не найдено ни одной корректной реплики SRT или WebVTT."
        }
    }
}

struct SubtitleParser {
    static func parse(data: Data) throws -> ParsedSubtitle {
        let decoded = try decode(data)
        return ParsedSubtitle(cues: parse(text: decoded.text), encodingName: decoded.encodingName)
    }

    static func activeText(
        in cues: [SubtitleCue],
        at currentTime: TimeInterval,
        offset: TimeInterval = 0
    ) -> String {
        let subtitleTime = currentTime - offset
        guard subtitleTime.isFinite else { return "" }

        return cues
            .filter { $0.start <= subtitleTime && $0.end >= subtitleTime }
            .map(\.text)
            .joined(separator: "\n")
    }

    static func parse(text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let timingPattern = #"((?:\d{1,3}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d{1,3}:)?\d{1,2}:\d{2}[.,]\d{1,3})"#
        guard let timingExpression = try? NSRegularExpression(pattern: timingPattern) else {
            return []
        }

        var blocks: [[String]] = []
        var currentBlock: [String] = []

        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock.removeAll(keepingCapacity: true)
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        var indexedCues: [(index: Int, cue: SubtitleCue)] = []

        for (blockIndex, block) in blocks.enumerated() {
            let blockKind = block.first?
                .trimmingCharacters(in: .whitespaces)
                .uppercased() ?? ""
            if blockKind == "WEBVTT"
                || blockKind.hasPrefix("NOTE")
                || blockKind == "STYLE"
                || blockKind == "REGION" {
                continue
            }

            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingLine = block[timingIndex]
            let fullRange = NSRange(timingLine.startIndex..<timingLine.endIndex, in: timingLine)
            guard let match = timingExpression.firstMatch(
                in: timingLine,
                range: fullRange
            ),
            let startRange = Range(match.range(at: 1), in: timingLine),
            let endRange = Range(match.range(at: 2), in: timingLine),
            let start = parseTimestamp(String(timingLine[startRange])),
            let end = parseTimestamp(String(timingLine[endRange])),
            end > start else {
                continue
            }

            let textLines = Array(block.dropFirst(timingIndex + 1))
            let cueText = cleanCueText(textLines)
            guard !cueText.isEmpty else { continue }

            indexedCues.append((
                index: blockIndex,
                cue: SubtitleCue(start: start, end: end, text: cueText)
            ))
        }

        return indexedCues
            .sorted {
                if $0.cue.start != $1.cue.start { return $0.cue.start < $1.cue.start }
                if $0.cue.end != $1.cue.end { return $0.cue.end < $1.cue.end }
                return $0.index < $1.index
            }
            .map(\.cue)
    }

    private static func decode(_ data: Data) throws -> (text: String, encodingName: String) {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decode(
                Data(bytes.dropFirst(3)),
                as: .utf8,
                named: "UTF-8"
            )
        }

        if bytes.starts(with: [0xFF, 0xFE]) {
            return try decode(
                Data(bytes.dropFirst(2)),
                as: .utf16LittleEndian,
                named: "UTF-16LE"
            )
        }

        if bytes.starts(with: [0xFE, 0xFF]) {
            return try decode(
                Data(bytes.dropFirst(2)),
                as: .utf16BigEndian,
                named: "UTF-16BE"
            )
        }

        if let utf16Encoding = likelyUTF16Encoding(for: bytes),
           let text = String(data: data, encoding: utf16Encoding.encoding) {
            return (text, utf16Encoding.name)
        }

        if let text = String(data: data, encoding: .utf8) {
            return (text, "UTF-8")
        }

        let cyrillicCandidate = String(data: data, encoding: .windowsCP1251)
        let westernCandidate = String(data: data, encoding: .windowsCP1252)
        switch (cyrillicCandidate, westernCandidate) {
        case let (cyrillic?, western?):
            if legacyEncodingScore(cyrillic, expectedScript: .cyrillic)
                > legacyEncodingScore(western, expectedScript: .latin) {
                return (cyrillic, "windows-1251")
            }
            return (western, "windows-1252")
        case let (cyrillic?, nil):
            return (cyrillic, "windows-1251")
        case let (nil, western?):
            return (western, "windows-1252")
        case (nil, nil):
            throw SubtitleParserError.unableToDecode("Windows-1251/1252")
        }
    }

    private enum ExpectedScript {
        case cyrillic
        case latin
    }

    private static func legacyEncodingScore(
        _ text: String,
        expectedScript: ExpectedScript
    ) -> Double {
        enum Script {
            case cyrillic
            case latin
            case other
        }

        var cyrillicLetters = 0
        var latinLetters = 0
        var mixedScriptTransitions = 0
        var controlCharacters = 0
        var previousScript: Script?

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let script: Script
            if (0x0400...0x052F).contains(value) {
                cyrillicLetters += 1
                script = .cyrillic
            } else if (0x0041...0x007A).contains(value)
                || (0x00C0...0x024F).contains(value) {
                if value > 0x7F { latinLetters += 1 }
                script = .latin
            } else {
                script = .other
                if scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" {
                    controlCharacters += 1
                }
            }

            if script == .other {
                previousScript = nil
            } else {
                if let previousScript, previousScript != script {
                    mixedScriptTransitions += 1
                }
                previousScript = script
            }
        }

        let baseScore: Double
        switch expectedScript {
        case .cyrillic:
            baseScore = Double(cyrillicLetters) * 2 + Double(latinLetters) * 0.15
        case .latin:
            baseScore = Double(latinLetters) * 1.4 - Double(cyrillicLetters) * 2
        }

        return baseScore
            - Double(mixedScriptTransitions) * 5
            - Double(controlCharacters) * 8
    }

    private static func decode(
        _ data: Data,
        as encoding: String.Encoding,
        named encodingName: String
    ) throws -> (text: String, encodingName: String) {
        guard let text = String(data: data, encoding: encoding) else {
            throw SubtitleParserError.unableToDecode(encodingName)
        }
        return (text, encodingName)
    }

    private static func likelyUTF16Encoding(
        for bytes: [UInt8]
    ) -> (encoding: String.Encoding, name: String)? {
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }

        var evenNulls = 0
        var oddNulls = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) {
                evenNulls += 1
            } else {
                oddNulls += 1
            }
        }

        let pairCount = max(1, bytes.count / 2)
        if oddNulls > evenNulls * 2 && Double(oddNulls) / Double(pairCount) > 0.3 {
            return (.utf16LittleEndian, "UTF-16LE")
        }
        if evenNulls > oddNulls * 2 && Double(evenNulls) / Double(pairCount) > 0.3 {
            return (.utf16BigEndian, "UTF-16BE")
        }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        var parts = value
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
            .map(String.init)

        guard (2...3).contains(parts.count),
              let seconds = Double(parts.removeLast()),
              let minutes = Double(parts.removeLast()) else {
            return nil
        }

        let hours: Double
        if let hourPart = parts.popLast() {
            guard let parsedHours = Double(hourPart) else { return nil }
            hours = parsedHours
        } else {
            hours = 0
        }

        guard hours.isFinite,
              minutes.isFinite,
              seconds.isFinite,
              hours >= 0,
              (0..<60).contains(minutes),
              (0..<60).contains(seconds) else {
            return nil
        }

        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func cleanCueText(_ lines: [String]) -> String {
        var value = lines.joined(separator: "\n")
        value = replacingMatches(of: #"\{\\[^}]+\}"#, in: value, with: "")
        value = replacingMatches(
            of: #"<br\s*/?>"#,
            in: value,
            options: [.caseInsensitive],
            with: "\n"
        )
        value = replacingMatches(of: #"<[^>]*>"#, in: value, with: "")
        value = decodeEntities(in: value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMatches(
        of pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }

    private static func decodeEntities(in value: String) -> String {
        let pattern = #"&(#x?[0-9a-f]+|[a-z]+);"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return value
        }

        let original = value as NSString
        let fullRange = NSRange(location: 0, length: original.length)
        let matches = expression.matches(in: value, range: fullRange)
        var result = value

        for match in matches.reversed() {
            let entity = original.substring(with: match.range(at: 1))
            guard let replacement = decodedEntity(entity),
                  let replacementRange = Range(match.range, in: result) else {
                continue
            }
            result.replaceSubrange(replacementRange, with: replacement)
        }

        return result
    }

    private static func decodedEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let number = entity.dropFirst()
            let isHexadecimal = number.first == "x" || number.first == "X"
            let digits = isHexadecimal ? number.dropFirst() : number[...]
            guard let codePoint = UInt32(digits, radix: isHexadecimal ? 16 : 10),
                  let scalar = UnicodeScalar(codePoint) else {
                return nil
            }
            return String(scalar)
        }

        switch entity.lowercased() {
        case "amp": return "&"
        case "apos": return "'"
        case "gt": return ">"
        case "lt": return "<"
        case "nbsp": return " "
        case "quot": return "\""
        default: return nil
        }
    }
}
