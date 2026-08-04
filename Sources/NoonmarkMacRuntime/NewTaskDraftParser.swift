import Foundation

public enum NewTaskClassificationTokenKind: Equatable, Sendable {
    case label
    case category

    public var marker: Character {
        switch self {
        case .label:
            "#"
        case .category:
            "@"
        }
    }
}

public struct NewTaskClassificationToken: Equatable, Sendable {
    public let kind: NewTaskClassificationTokenKind
    public let query: String

    public init(kind: NewTaskClassificationTokenKind, query: String) {
        self.kind = kind
        self.query = query
    }
}

public enum NewTaskDraftIssue: Equatable, Sendable {
    case multipleCategories([String])
}

public enum NewTaskCreationCommand: Equatable, Sendable {
    case recurring
}

public struct NewTaskDraft: Equatable, Sendable {
    public let title: String
    public let categoryName: String?
    public let labelNames: [String]
    public let command: NewTaskCreationCommand?
    public let issue: NewTaskDraftIssue?

    public init(
        title: String,
        categoryName: String?,
        labelNames: [String],
        command: NewTaskCreationCommand? = nil,
        issue: NewTaskDraftIssue?
    ) {
        self.title = title
        self.categoryName = categoryName
        self.labelNames = labelNames
        self.command = command
        self.issue = issue
    }
}

public enum IdeaDraftIssue: Equatable, Sendable {
    case multipleCategories([String])
}

/// Parsed idea input keeps authored line breaks while separating the optional
/// classification tokens from the Flylight body. Task titles deliberately use a
/// different, single-line normalization policy.
public struct IdeaDraft: Equatable, Sendable {
    public let body: String
    public let categoryName: String?
    public let labelNames: [String]
    public let issue: IdeaDraftIssue?

    public init(
        body: String,
        categoryName: String?,
        labelNames: [String],
        issue: IdeaDraftIssue?
    ) {
        self.body = body
        self.categoryName = categoryName
        self.labelNames = labelNames
        self.issue = issue
    }
}

public enum IdeaDraftParser {
    public static func parse(_ rawText: String) -> IdeaDraft {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else {
            return IdeaDraft(
                body: "",
                categoryName: nil,
                labelNames: [],
                issue: nil
            )
        }

        let protectedRanges = markdownProtectedRanges(in: raw)
        let occurrences = NewTaskDraftParser.classificationTokenOccurrences(
            in: raw
        ).filter { occurrence in
            protectedRanges.contains { range in
                range.contains(occurrence.range.lowerBound)
            } == false
        }
        let categoryNames = occurrences
            .filter { $0.kind == .category }
            .map(\.name)
        let issue: IdeaDraftIssue? = categoryNames.count > 1
            ? .multipleCategories(categoryNames)
            : nil

        return IdeaDraft(
            body: body(removing: occurrences, from: raw),
            categoryName: categoryNames.count == 1 ? categoryNames[0] : nil,
            labelNames: occurrences
                .filter { $0.kind == .label }
                .map(\.name),
            issue: issue
        )
    }

    public static func activeToken(
        in rawText: String
    ) -> NewTaskClassificationToken? {
        guard let token = NewTaskDraftParser.activeToken(in: rawText),
              let markerIndex = NewTaskDraftParser.lastBoundaryMarkerIndex(
                  in: rawText
              ),
              markdownProtectedRanges(in: rawText).contains(where: {
                  $0.contains(markerIndex)
              }) == false
        else {
            return nil
        }
        return token
    }

    public static func completingActiveToken(
        in rawText: String,
        with name: String
    ) -> String {
        guard activeToken(in: rawText) != nil else { return rawText }
        return NewTaskDraftParser.completingActiveToken(
            in: rawText,
            with: name
        )
    }

    /// Reconstructs the single editable Flylight draft without losing the
    /// stable classification identities supplied by the caller. Classification
    /// names use the same reversible quoting rules as token completion.
    public static func editableText(
        body: String,
        categoryName: String?,
        labelNames: [String]
    ) -> String {
        var tokens: [String] = []
        if let categoryName {
            tokens.append(
                "@\(NewTaskDraftParser.encodedClassificationName(categoryName))"
            )
        }
        tokens.append(contentsOf: labelNames.map {
            "#\(NewTaskDraftParser.encodedClassificationName($0))"
        })
        guard tokens.isEmpty == false else { return body }
        return "\(body)\n\(tokens.joined(separator: " "))"
    }

    private static func body(
        removing occurrences: [TokenOccurrence],
        from raw: String
    ) -> String {
        var result = ""
        var cursor = raw.startIndex
        for occurrence in occurrences {
            var lowerBound = occurrence.range.lowerBound
            if lowerBound > cursor {
                let preceding = raw.index(before: lowerBound)
                if raw[preceding] == " " || raw[preceding] == "\t" {
                    lowerBound = preceding
                }
            }
            result.append(contentsOf: raw[cursor ..< lowerBound])
            cursor = occurrence.range.upperBound
        }
        result.append(contentsOf: raw[cursor...])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownProtectedRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges = backtickCodeRanges(in: source)
        ranges.append(contentsOf: headingMarkerRanges(in: source))
        ranges.append(contentsOf: escapedClassificationMarkerRanges(in: source))
        ranges.append(contentsOf: URLLikeRanges(in: source))
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let linkStart = source.range(
                of: "](",
                range: cursor ..< source.endIndex
            ) else {
                break
            }
            var index = linkStart.upperBound
            var depth = 1
            var escaped = false
            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                index = source.index(after: index)
            }
            let upperBound = depth == 0 ? index : source.endIndex
            ranges.append(linkStart.lowerBound ..< upperBound)
            cursor = upperBound
        }
        return ranges
    }

    private static func escapedClassificationMarkerRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = source.startIndex
        while index < source.endIndex {
            defer { index = source.index(after: index) }
            guard source[index] == "#" || source[index] == "@" else {
                continue
            }
            var slashCount = 0
            var cursor = index
            while cursor > source.startIndex {
                let preceding = source.index(before: cursor)
                guard source[preceding] == "\\" else { break }
                slashCount += 1
                cursor = preceding
            }
            guard slashCount.isMultiple(of: 2) == false else { continue }
            ranges.append(index ..< source.index(after: index))
        }
        return ranges
    }

    /// Bare URLs are not CommonMark link destinations, but users reasonably
    /// expect their path, fragment, and user-info markers to remain literal.
    private static func URLLikeRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let separator = source.range(
                  of: "://",
                  range: searchStart ..< source.endIndex
              )
        {
            var schemeStart = separator.lowerBound
            while schemeStart > source.startIndex {
                let preceding = source.index(before: schemeStart)
                let character = source[preceding]
                guard character.isLetter || character.isNumber
                    || character == "+" || character == "-" || character == "."
                else {
                    break
                }
                schemeStart = preceding
            }
            let scheme = source[schemeStart ..< separator.lowerBound]
            guard scheme.first?.isLetter == true,
                  scheme.dropFirst().allSatisfy({ character in
                      character.isLetter || character.isNumber
                          || character == "+" || character == "-"
                          || character == "."
                  })
            else {
                searchStart = separator.upperBound
                continue
            }
            var upperBound = separator.upperBound
            while upperBound < source.endIndex,
                  source[upperBound].isWhitespace == false
            {
                upperBound = source.index(after: upperBound)
            }
            ranges.append(schemeStart ..< upperBound)
            searchStart = upperBound
        }
        return ranges
    }

    private static func headingMarkerRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            var markerEnd = lineStart
            var count = 0
            while markerEnd < source.endIndex,
                  source[markerEnd] == "#",
                  count < 6
            {
                markerEnd = source.index(after: markerEnd)
                count += 1
            }
            if count > 0,
               markerEnd < source.endIndex,
               source[markerEnd].isWhitespace
            {
                ranges.append(lineStart ..< markerEnd)
            }
            guard let newline = source[lineStart...].firstIndex(of: "\n")
            else {
                break
            }
            lineStart = source.index(after: newline)
        }
        return ranges
    }

    private static func backtickCodeRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard source[cursor] == "`" else {
                cursor = source.index(after: cursor)
                continue
            }
            let opener = cursor
            while cursor < source.endIndex, source[cursor] == "`" {
                cursor = source.index(after: cursor)
            }
            let delimiter = String(source[opener ..< cursor])
            guard let closer = source.range(
                of: delimiter,
                range: cursor ..< source.endIndex
            ) else {
                ranges.append(opener ..< source.endIndex)
                break
            }
            ranges.append(opener ..< closer.upperBound)
            cursor = closer.upperBound
        }
        return ranges
    }
}

public enum NewTaskDraftParser {
    public static func parse(_ rawText: String) -> NewTaskDraft {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else {
            return NewTaskDraft(
                title: "",
                categoryName: nil,
                labelNames: [],
                command: nil,
                issue: nil
            )
        }

        let commandPrefix = recurringCommandPrefix(in: raw)
        let taskContent = commandPrefix.map {
            String(raw[$0.upperBound...]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } ?? raw
        let occurrences = classificationTokenOccurrences(in: taskContent)
        let categoryNames = occurrences
            .filter { $0.kind == .category }
            .map(\.name)
        let issue: NewTaskDraftIssue? = categoryNames.count > 1
            ? .multipleCategories(categoryNames)
            : nil

        var title = taskContent
        for occurrence in occurrences.reversed() {
            title.replaceSubrange(occurrence.range, with: " ")
        }

        return NewTaskDraft(
            title: title.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            categoryName: categoryNames.count == 1 ? categoryNames[0] : nil,
            labelNames: occurrences
                .filter { $0.kind == .label }
                .map(\.name),
            command: commandPrefix == nil ? nil : .recurring,
            issue: issue
        )
    }

    public static func activeCommandQuery(
        in rawText: String
    ) -> String? {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.first == "/",
              raw.dropFirst().allSatisfy({
                  $0.isWhitespace == false
              })
        else {
            return nil
        }
        return String(raw.dropFirst())
    }

    public static func activeToken(in rawText: String) -> NewTaskClassificationToken? {
        guard rawText.isEmpty == false,
              rawText.last?.isWhitespace == false,
              let markerIndex = lastBoundaryMarkerIndex(in: rawText),
              let kind = tokenKind(for: rawText[markerIndex])
        else {
            return nil
        }

        let contentStart = rawText.index(after: markerIndex)
        let tail = rawText[contentStart...]
        if tail.first == "\"" {
            let queryStart = tail.index(after: tail.startIndex)
            let query = tail[queryStart...]
            guard containsUnescapedQuote(query) == false else { return nil }
            return NewTaskClassificationToken(
                kind: kind,
                query: unescaped(String(query))
            )
        }
        guard tail.allSatisfy({ $0.isWhitespace == false }) else { return nil }
        return NewTaskClassificationToken(kind: kind, query: String(tail))
    }

    public static func completingActiveToken(
        in rawText: String,
        with name: String
    ) -> String {
        guard activeToken(in: rawText) != nil,
              let markerIndex = lastBoundaryMarkerIndex(in: rawText)
        else {
            return rawText
        }
        let prefix = rawText[..<markerIndex]
        let marker = rawText[markerIndex]
        return "\(prefix)\(marker)\(encodedClassificationName(name)) "
    }

    fileprivate static func classificationTokenOccurrences(
        in raw: String
    ) -> [TokenOccurrence] {
        var occurrences: [TokenOccurrence] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            guard let kind = tokenKind(for: raw[index]),
                  isTokenBoundary(index, in: raw),
                  let occurrence = tokenOccurrence(
                      kind: kind,
                      markerIndex: index,
                      in: raw
                  )
            else {
                index = raw.index(after: index)
                continue
            }
            occurrences.append(occurrence)
            index = occurrence.range.upperBound
        }
        return occurrences
    }

    private static func recurringCommandPrefix(
        in raw: String
    ) -> Range<String.Index>? {
        for command in ["/重复", "/repeat"] {
            guard raw.lowercased().hasPrefix(command.lowercased())
            else {
                continue
            }
            let upperBound = raw.index(
                raw.startIndex,
                offsetBy: command.count
            )
            guard upperBound == raw.endIndex
                || raw[upperBound].isWhitespace
            else {
                continue
            }
            return raw.startIndex ..< upperBound
        }
        return nil
    }

    private static func tokenOccurrence(
        kind: NewTaskClassificationTokenKind,
        markerIndex: String.Index,
        in raw: String
    ) -> TokenOccurrence? {
        let contentStart = raw.index(after: markerIndex)
        guard contentStart < raw.endIndex else { return nil }

        if raw[contentStart] == "\"" {
            var index = raw.index(after: contentStart)
            var name = ""
            var escaped = false
            while index < raw.endIndex {
                let character = raw[index]
                if escaped {
                    name.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    let upperBound = raw.index(after: index)
                    guard upperBound == raw.endIndex
                        || raw[upperBound].isWhitespace
                    else {
                        return nil
                    }
                    let normalizedName = name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard normalizedName.isEmpty == false else { return nil }
                    return TokenOccurrence(
                        kind: kind,
                        name: normalizedName,
                        range: markerIndex ..< upperBound
                    )
                } else {
                    name.append(character)
                }
                index = raw.index(after: index)
            }
            return nil
        }

        var upperBound = contentStart
        while upperBound < raw.endIndex && raw[upperBound].isWhitespace == false {
            upperBound = raw.index(after: upperBound)
        }
        let name = raw[contentStart..<upperBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }
        return TokenOccurrence(
            kind: kind,
            name: name,
            range: markerIndex ..< upperBound
        )
    }

    fileprivate static func lastBoundaryMarkerIndex(in text: String) -> String.Index? {
        var result: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isBoundaryMarker = tokenKind(for: text[index]) != nil
                && isTokenBoundary(index, in: text)
            if isBoundaryMarker {
                result = index
            }
            index = text.index(after: index)
        }
        return result
    }

    private static func isTokenBoundary(
        _ index: String.Index,
        in text: String
    ) -> Bool {
        guard index != text.startIndex else { return true }
        let preceding = text[text.index(before: index)]
        if preceding.isWhitespace || preceding.isASCII == false {
            return true
        }
        return preceding.isLetter == false
            && preceding.isNumber == false
            && preceding != "_"
    }

    private static func tokenKind(
        for marker: Character
    ) -> NewTaskClassificationTokenKind? {
        switch marker {
        case "#":
            .label
        case "@":
            .category
        default:
            nil
        }
    }

    fileprivate static func encodedClassificationName(_ name: String) -> String {
        guard name.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" })
        else {
            return name
        }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func containsUnescapedQuote(_ text: Substring) -> Bool {
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return true
            }
        }
        return false
    }

    private static func unescaped(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }
}

private struct TokenOccurrence {
    let kind: NewTaskClassificationTokenKind
    let name: String
    let range: Range<String.Index>
}
