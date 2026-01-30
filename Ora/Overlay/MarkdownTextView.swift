//
//  MarkdownTextView.swift
//  Ora
//
//  Markdown rendering for chat bubbles
//

import AppKit
import SwiftUI

struct MarkdownTextView: View {
    let text: String
    let role: ChatBubbleView.Role

    private var horizontalAlignment: HorizontalAlignment { .leading }

    private var frameAlignment: Alignment { .leading }

    private var textAlignment: TextAlignment { .leading }

    var body: some View {
        let blocks = MarkdownParser.parseBlocks(self.text)
        VStack(alignment: self.horizontalAlignment, spacing: MarkdownLayout.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { index in
                self.blockView(blocks[index])
            }
        }
        .multilineTextAlignment(self.textAlignment)
        .frame(maxWidth: .infinity, alignment: self.frameAlignment)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content):
            MarkdownInlineText(
                text: content,
                baseFont: .body,
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment,
                expandsToFillWidth: true
            )
        case .heading(let level, let content):
            MarkdownInlineText(
                text: content,
                baseFont: MarkdownLayout.headingFont(level: level),
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment,
                expandsToFillWidth: true
            )
        case .codeBlock(_, let code):
            CodeBlockView(
                code: code,
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment
            )
        case .unorderedList(let items):
            ListBlockView(
                items: items.map { ListBlockView.Item(marker: "\u{2022}", text: $0) },
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment
            )
        case .orderedList(let items):
            ListBlockView(
                items: items.map { ListBlockView.Item(marker: "\($0.number).", text: $0.text) },
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment
            )
        case .blockquote(let content):
            BlockquoteView(
                text: content,
                alignment: self.frameAlignment,
                textAlignment: self.textAlignment
            )
        case .horizontalRule:
            Rectangle()
                .fill(MarkdownLayout.ruleColor)
                .frame(height: 1)
                .frame(maxWidth: .infinity, alignment: self.frameAlignment)
        }
    }
}

private enum MarkdownLayout {
    static let blockSpacing: CGFloat = 8
    static let listItemSpacing: CGFloat = 4
    static let listBulletSpacing: CGFloat = 8
    static let quoteBarWidth: CGFloat = 2
    static let quoteBarCornerRadius: CGFloat = 1
    static let quoteSpacing: CGFloat = 8
    static let codeCornerRadius: CGFloat = 8
    static let codePadding: CGFloat = 8
    static let codeFont: Font = .system(.callout, design: .monospaced)
    static let inlineCodeBackground: Color = Color.primary.opacity(0.12)
    static let inlineCodeForeground: Color = .primary
    static let codeBlockBackground: Color = Color.primary.opacity(0.08)
    static let codeBlockBorder: Color = Color.primary.opacity(0.12)
    static let linkColor: Color = Color(nsColor: .linkColor)
    static let ruleColor: Color = Color.primary.opacity(0.18)

    static func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .title3.weight(.semibold)
        case 2:
            return .headline.weight(.semibold)
        case 3:
            return .headline.weight(.medium)
        default:
            return .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownInlineText: View {
    let text: String
    let baseFont: Font
    let alignment: Alignment
    let textAlignment: TextAlignment
    let expandsToFillWidth: Bool

    var body: some View {
        Text(self.attributedText)
            .font(self.baseFont)
            .multilineTextAlignment(self.textAlignment)
            .frame(maxWidth: self.expandsToFillWidth ? .infinity : nil, alignment: self.alignment)
    }

    private var attributedText: AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.allowsExtendedAttributes = true
        var attributed = (try? AttributedString(markdown: self.text, options: options)) ?? AttributedString(self.text)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = .system(.body, design: .monospaced)
                attributed[run.range].foregroundColor = MarkdownLayout.inlineCodeForeground
                attributed[run.range].backgroundColor = MarkdownLayout.inlineCodeBackground
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = MarkdownLayout.linkColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

private struct CodeBlockView: View {
    let code: String
    let alignment: Alignment
    let textAlignment: TextAlignment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: self.code)
                .font(MarkdownLayout.codeFont)
                .multilineTextAlignment(self.textAlignment)
                .frame(maxWidth: .infinity, alignment: self.alignment)
                .padding(MarkdownLayout.codePadding)
        }
        .background(
            RoundedRectangle(cornerRadius: MarkdownLayout.codeCornerRadius, style: .continuous)
                .fill(MarkdownLayout.codeBlockBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarkdownLayout.codeCornerRadius, style: .continuous)
                .stroke(MarkdownLayout.codeBlockBorder, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: self.alignment)
    }
}

private struct ListBlockView: View {
    struct Item: Equatable {
        let marker: String
        let text: String
    }

    let items: [Item]
    let alignment: Alignment
    let textAlignment: TextAlignment

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownLayout.listItemSpacing) {
            ForEach(self.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: MarkdownLayout.listBulletSpacing) {
                    Text(self.items[index].marker)
                        .font(.body)
                        .foregroundStyle(.primary)
                    MarkdownInlineText(
                        text: self.items[index].text,
                        baseFont: .body,
                        alignment: .leading,
                        textAlignment: self.textAlignment,
                        expandsToFillWidth: false
                    )
                }
                .frame(maxWidth: .infinity, alignment: self.alignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: self.alignment)
    }
}

private struct BlockquoteView: View {
    let text: String
    let alignment: Alignment
    let textAlignment: TextAlignment

    var body: some View {
        HStack(alignment: .top, spacing: MarkdownLayout.quoteSpacing) {
            RoundedRectangle(cornerRadius: MarkdownLayout.quoteBarCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: MarkdownLayout.quoteBarWidth)
            MarkdownInlineText(
                text: self.text,
                baseFont: .body,
                alignment: .leading,
                textAlignment: self.textAlignment,
                expandsToFillWidth: true
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: self.alignment)
    }
}

private struct MarkdownOrderedListItem: Equatable {
    let number: Int
    let text: String
}

private enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case codeBlock(language: String?, code: String)
    case unorderedList(items: [String])
    case orderedList(items: [MarkdownOrderedListItem])
    case blockquote(String)
    case horizontalRule
}

private enum MarkdownParser {
    static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var index = 0
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let content = paragraphLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !content.isEmpty {
                blocks.append(.paragraph(content))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let rawLine = String(lines[index])
            let trimmed = rawLine.trimmingCharacters(in: CharacterSet.whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = parseFenceLanguage(trimmed)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let line = String(lines[index])
                    let lineTrimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    if lineTrimmed.hasPrefix("```") {
                        break
                    }
                    codeLines.append(line)
                    index += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                while index < lines.count {
                    let line = String(lines[index])
                    if line.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if parseBlockquoteStart(trimmed) != nil {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let line = String(lines[index])
                let lineTrimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    guard let quote = parseBlockquoteStart(lineTrimmed) else { break }
                    quoteLines.append(quote)
                    index += 1
                }
                let quoteText = quoteLines.joined(separator: "\n")
                blocks.append(.blockquote(quoteText))
                continue
            }

            if let item = parseUnorderedListItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                index += 1
                while index < lines.count {
                    let line = String(lines[index])
                    let lineTrimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    if lineTrimmed.isEmpty { break }
                    if let nextItem = parseUnorderedListItem(lineTrimmed) {
                        items.append(nextItem)
                        index += 1
                        continue
                    }
                    if let continuation = parseContinuation(line) {
                        let last = items.removeLast()
                        items.append(last + "\n" + continuation)
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.unorderedList(items: items))
                continue
            }

            if let item = parseOrderedListItem(trimmed) {
                flushParagraph()
                var items: [MarkdownOrderedListItem] = [item]
                index += 1
                while index < lines.count {
                    let line = String(lines[index])
                    let lineTrimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    if lineTrimmed.isEmpty { break }
                    if let nextItem = parseOrderedListItem(lineTrimmed) {
                        items.append(nextItem)
                        index += 1
                        continue
                    }
                    if let continuation = parseContinuation(line) {
                        let last = items.removeLast()
                        items.append(
                            MarkdownOrderedListItem(
                                number: last.number,
                                text: last.text + "\n" + continuation
                            )
                        )
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            paragraphLines.append(rawLine)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseFenceLanguage(_ trimmed: String) -> String? {
        let language = trimmed.dropFirst(3).trimmingCharacters(in: CharacterSet.whitespaces)
        return language.isEmpty ? nil : String(language)
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = trimmed.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = remainder.trimmingCharacters(in: CharacterSet.whitespaces)
        return (hashes.count, text)
    }

    private static func parseUnorderedListItem(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet.whitespaces)
        }
        return nil
    }

    private static func parseOrderedListItem(_ trimmed: String) -> MarkdownOrderedListItem? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        guard let number = Int(digits) else { return nil }
        let remainder = trimmed.dropFirst(digits.count)
        if remainder.hasPrefix(". ") || remainder.hasPrefix(") ") {
            let text = String(remainder.dropFirst(2)).trimmingCharacters(in: CharacterSet.whitespaces)
            return MarkdownOrderedListItem(number: number, text: text)
        }
        return nil
    }

    private static func parseBlockquoteStart(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        let remainder = trimmed.dropFirst().trimmingCharacters(in: CharacterSet.whitespaces)
        return remainder
    }

    private static func parseContinuation(_ line: String) -> String? {
        let indentCount = line.prefix { $0 == " " || $0 == "\t" }.count
        guard indentCount >= 2 else { return nil }
        return line.trimmingCharacters(in: CharacterSet.whitespaces)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let normalized = trimmed.replacingOccurrences(of: " ", with: "")
        if normalized.count < 3 { return false }
        return normalized.allSatisfy { $0 == "-" } ||
            normalized.allSatisfy { $0 == "*" } ||
            normalized.allSatisfy { $0 == "_" }
    }
}
