import SwiftUI

// MARK: - MarkdownTextView

/// Renders a markdown string as styled SwiftUI views using regex-based parsing.
/// Handles: code blocks, inline code, bold, italic, headers, bullet lists,
/// numbered lists, and links.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let elements = parseMarkdown(markdown)
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                renderElement(element)
            }
        }
    }

    // MARK: - Markdown Element Types

    private enum MarkdownElement {
        case header(level: Int, text: String)
        case codeBlock(language: String?, code: String)
        case bulletItem(text: String)
        case numberedItem(number: String, text: String)
        case paragraph(text: String)
        case blankLine
    }

    // MARK: - Parser

    private func parseMarkdown(_ text: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let lines = text.components(separatedBy: "\n")
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
                let level = headerMatch.1.count
                let text = String(headerMatch.2)
                elements.append(.header(level: level, text: text))
                index += 1
                continue
            }

            // Bullet list item (-, *, +)
            if let bulletMatch = line.wholeMatch(of: /^\s*[-*+]\s+(.+)$/) {
                elements.append(.bulletItem(text: String(bulletMatch.1)))
                index += 1
                continue
            }

            // Numbered list item
            if let numMatch = line.wholeMatch(of: /^\s*(\d+)[.)]\s+(.+)$/) {
                elements.append(.numberedItem(number: String(numMatch.1), text: String(numMatch.2)))
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
            elements.append(.paragraph(text: line))
            index += 1
        }

        return elements
    }

    // MARK: - Element Rendering

    @ViewBuilder
    private func renderElement(_ element: MarkdownElement) -> some View {
        switch element {
        case .header(let level, let text):
            renderInlineMarkdown(text)
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
                renderInlineMarkdown(text)
                    .font(DesignConstants.monoFont)
            }
            .padding(.leading, 12)

        case .numberedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                renderInlineMarkdown(text)
                    .font(DesignConstants.monoFont)
            }
            .padding(.leading, 8)

        case .paragraph(let text):
            renderInlineMarkdown(text)
                .font(DesignConstants.monoFont)

        case .blankLine:
            Spacer()
                .frame(height: 4)
        }
    }

    // MARK: - Inline Markdown Rendering

    private func renderInlineMarkdown(_ text: String) -> Text {
        parseInlineMarkdown(text)
    }

    private func parseInlineMarkdown(_ input: String) -> Text {
        var result = Text("")
        var remaining = input[input.startIndex..<input.endIndex]

        while !remaining.isEmpty {
            // Inline code: `code`
            if let codeMatch = remaining.firstMatch(of: /`([^`]+)`/) {
                let before = remaining[remaining.startIndex..<codeMatch.range.lowerBound]
                if !before.isEmpty {
                    result = result + Text(String(before))
                }
                result = result + Text(String(codeMatch.1))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(DesignConstants.accentColor)
                remaining = remaining[codeMatch.range.upperBound...]
                continue
            }

            // Bold + italic: ***text*** or ___text___
            if let biMatch = remaining.firstMatch(of: /\*\*\*(.+?)\*\*\*/) {
                let before = remaining[remaining.startIndex..<biMatch.range.lowerBound]
                if !before.isEmpty {
                    result = result + Text(String(before))
                }
                result = result + Text(String(biMatch.1)).bold().italic()
                remaining = remaining[biMatch.range.upperBound...]
                continue
            }

            // Bold: **text** or __text__
            if let boldMatch = remaining.firstMatch(of: /\*\*(.+?)\*\*/) {
                let before = remaining[remaining.startIndex..<boldMatch.range.lowerBound]
                if !before.isEmpty {
                    result = result + Text(String(before))
                }
                result = result + Text(String(boldMatch.1)).bold()
                remaining = remaining[boldMatch.range.upperBound...]
                continue
            }

            // Italic: *text* or _text_ (but not inside words for underscore)
            if let italicMatch = remaining.firstMatch(of: /\*(.+?)\*/) {
                let before = remaining[remaining.startIndex..<italicMatch.range.lowerBound]
                if !before.isEmpty {
                    result = result + Text(String(before))
                }
                result = result + Text(String(italicMatch.1)).italic()
                remaining = remaining[italicMatch.range.upperBound...]
                continue
            }

            // Link: [text](url)
            if let linkMatch = remaining.firstMatch(of: /\[([^\]]+)\]\(([^)]+)\)/) {
                let before = remaining[remaining.startIndex..<linkMatch.range.lowerBound]
                if !before.isEmpty {
                    result = result + Text(String(before))
                }
                let linkText = String(linkMatch.1)
                let urlString = String(linkMatch.2)
                if let url = URL(string: urlString) {
                    result = result + Text(.init("[\(linkText)](\(url.absoluteString))"))
                        .foregroundColor(DesignConstants.accentColor)
                        .underline()
                } else {
                    result = result + Text(linkText)
                        .foregroundColor(DesignConstants.accentColor)
                }
                remaining = remaining[linkMatch.range.upperBound...]
                continue
            }

            // No match found, consume one character to avoid infinite loop
            let nextChar = remaining[remaining.startIndex]
            result = result + Text(String(nextChar))
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
        }

        return result
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
