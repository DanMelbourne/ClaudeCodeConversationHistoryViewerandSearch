import SwiftUI

// MARK: - MarkdownTextView

/// Renders a markdown string as styled SwiftUI views using regex-based parsing.
/// Handles: code blocks, inline code, bold, italic, headers, bullet lists,
/// numbered lists, and links.
///
/// Parsing is done once per distinct string and cached. `body` is evaluated on
/// every scroll tick and every unrelated state change, so re-parsing there is
/// what turns a long transcript into an app hang.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let elements = MarkdownCache.shared.elements(for: markdown)
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                renderElement(element)
            }
        }
    }

    // MARK: - Element Rendering

    @ViewBuilder
    private func renderElement(_ element: MarkdownElement) -> some View {
        switch element {
        case .header(let level, let text):
            text
                .font(headerFont(level: level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 8 : 4)
                .padding(.bottom, 2)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

        case .bulletItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\u{2022}")
                    .foregroundStyle(.secondary)
                text
                    .font(DesignConstants.monoFont)
            }
            .padding(.leading, 12)

        case .numberedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                text
                    .font(DesignConstants.monoFont)
            }
            .padding(.leading, 8)

        case .paragraph(let text):
            text
                .font(DesignConstants.monoFont)

        case .blankLine:
            Spacer()
                .frame(height: 4)
        }
    }

    // MARK: - Header Font

    private func headerFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - Parsed Element

/// A markdown block whose inline spans have already been resolved into a `Text`.
enum MarkdownElement {
    case header(level: Int, text: Text)
    case codeBlock(language: String?, code: String)
    case bulletItem(text: Text)
    case numberedItem(number: String, text: Text)
    case paragraph(text: Text)
    case blankLine
}

// MARK: - Markdown Parser

enum MarkdownParser {

    /// A single left-to-right pass over the line with one bounded alternation.
    ///
    /// Every inner pattern is newline-free and length-capped on purpose. The
    /// previous parser retried five unbounded regexes against the whole
    /// remaining string once per unmatched trigger character (`` ` ``, `*`,
    /// `_`, `[`), which made it O(triggers x length): a 16 KB line of ordinary
    /// prose containing snake_case identifiers blocked the main thread for
    /// ~7.9 s, well past Sentry's 2 s app-hang threshold. Bounding the inner
    /// patterns means a lone trigger fails inside a fixed window instead of
    /// backtracking to the end of the line, and `matches(of:)` walks the line
    /// exactly once. Same 16 KB line now costs ~28 ms.
    private static let inlineRegex =
        /(`[^`\n]{1,500}`)|(\*\*\*[^\n]{1,500}?\*\*\*)|(\*\*[^\n]{1,500}?\*\*)|(\*[^*\n]{1,300}\*)|(\[[^\]\n]{1,300}\]\([^)\s]{1,500}\))/

    /// Lines longer than this are rendered as plain text. Inline styling on a
    /// line this long is invisible to the reader and only costs render time.
    private static let inlineParseLimit = 20_000

    /// Whole messages longer than this are truncated for display. A transcript
    /// line can carry a multi-megabyte payload; laying that out as one `Text`
    /// blocks the main thread for seconds.
    static let displayLimit = 400_000

    static func parse(_ text: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        // `utf8.count` is O(1) on a native Swift string; `count` walks the whole
        // string doing grapheme breaking, which is itself a stall on the
        // multi-megabyte records this guard exists to catch.
        let byteLength = text.utf8.count
        let source = byteLength > displayLimit
            ? String(text.prefix(displayLimit)) + "\n\n… truncated for display (\(byteLength) bytes)"
            : text
        let lines = source.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Code block (fenced)
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // skip closing ```
                elements.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Header
            if let headerMatch = line.wholeMatch(of: /^(#{1,6})\s+(.+)$/) {
                elements.append(.header(level: headerMatch.1.count, text: inlineText(String(headerMatch.2))))
                index += 1
                continue
            }

            // Bullet list item (-, *, +)
            if let bulletMatch = line.wholeMatch(of: /^\s*[-*+]\s+(.+)$/) {
                elements.append(.bulletItem(text: inlineText(String(bulletMatch.1))))
                index += 1
                continue
            }

            // Numbered list item
            if let numMatch = line.wholeMatch(of: /^\s*(\d+)[.)]\s+(.+)$/) {
                elements.append(.numberedItem(number: String(numMatch.1), text: inlineText(String(numMatch.2))))
                index += 1
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                elements.append(.blankLine)
                index += 1
                continue
            }

            // Regular paragraph line
            elements.append(.paragraph(text: inlineText(line)))
            index += 1
        }

        return elements
    }

    /// Resolve one line's inline markdown into a single `Text`.
    static func inlineText(_ input: String) -> Text {
        guard input.utf8.count <= inlineParseLimit else { return Text(input) }

        var segments: [Text] = []
        var cursor = input.startIndex

        for match in input.matches(of: inlineRegex) {
            if match.range.lowerBound > cursor {
                segments.append(Text(String(input[cursor..<match.range.lowerBound])))
            }
            segments.append(styled(String(input[match.range])))
            cursor = match.range.upperBound
        }

        if cursor < input.endIndex {
            segments.append(Text(String(input[cursor...])))
        }

        // Balanced reduction keeps the ConcatenatedTextStorage tree depth
        // O(log n) instead of O(n), which is what prevents a stack overflow in
        // SwiftUI's resolve() for messages with many inline spans.
        return balancedReduce(segments)
    }

    /// Style one matched inline span according to its delimiters.
    private static func styled(_ span: String) -> Text {
        if span.hasPrefix("`") {
            return Text(String(span.dropFirst().dropLast()))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(DesignConstants.accentColor)
        }
        if span.hasPrefix("***") {
            return Text(String(span.dropFirst(3).dropLast(3))).bold().italic()
        }
        if span.hasPrefix("**") {
            return Text(String(span.dropFirst(2).dropLast(2))).bold()
        }
        if span.hasPrefix("*") {
            return Text(String(span.dropFirst().dropLast())).italic()
        }
        if span.hasPrefix("["),
           let linkMatch = span.wholeMatch(of: /\[([^\]]+)\]\(([^)]+)\)/) {
            let linkText = String(linkMatch.1)
            let urlString = String(linkMatch.2)
            if let url = URL(string: urlString) {
                return Text(.init("[\(linkText)](\(url.absoluteString))"))
                    .foregroundColor(DesignConstants.accentColor)
                    .underline()
            }
            return Text(linkText).foregroundColor(DesignConstants.accentColor)
        }
        return Text(span)
    }

    /// Reduce an array of Text segments into a single Text via balanced binary
    /// tree concatenation. Depth = O(log n) instead of O(n) for left-folding.
    static func balancedReduce(_ texts: [Text]) -> Text {
        guard !texts.isEmpty else { return Text("") }
        if texts.count == 1 { return texts[0] }
        if texts.count == 2 { return texts[0] + texts[1] }
        let mid = texts.count / 2
        return balancedReduce(Array(texts[..<mid])) + balancedReduce(Array(texts[mid...]))
    }
}

// MARK: - Parse Cache

/// Caches parsed markdown so scrolling re-renders cost a dictionary lookup
/// rather than a fresh parse of every visible message.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private final class Box {
        let elements: [MarkdownElement]
        init(_ elements: [MarkdownElement]) { self.elements = elements }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    func elements(for markdown: String) -> [MarkdownElement] {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) { return cached.elements }
        let parsed = MarkdownParser.parse(markdown)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}
