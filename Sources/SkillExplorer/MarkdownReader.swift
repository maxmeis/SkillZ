import SwiftUI

struct MarkdownReader: View {
    let source: String

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case quote(String)
        case item(String, String)
        case divider
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: Character?

        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openFence = fence {
                if trimmed.hasPrefix(String(repeating: openFence, count: 3)) {
                    result.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = trimmed.first
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush()
                result.append(.heading(heading.1.count, String(heading.2)))
            } else if let item = trimmed.firstMatch(of: /^([-+*]|[0-9]+[.)])\s+(.+)$/) {
                flush()
                let marker = String(item.1)
                result.append(.item(marker.count == 1 ? "•" : marker, String(item.2)))
            } else if trimmed.hasPrefix("> ") {
                flush()
                result.append(.quote(String(trimmed.dropFirst(2))))
            } else if ["---", "***", "___"].contains(trimmed) {
                flush()
                result.append(.divider)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        if fence != nil { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        ScrollView {
            let content = blocks
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(content.indices, id: \.self) { index in
                    switch content[index] {
                    case let .heading(level, text):
                        inline(text).font(level == 1 ? .largeTitle : level == 2 ? .title2 : .headline).bold()
                    case let .paragraph(text):
                        inline(text)
                    case let .code(text):
                        ScrollView(.horizontal) {
                            Text(verbatim: text).font(.system(.body, design: .monospaced)).padding(12)
                        }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    case let .quote(text):
                        inline(text).italic().foregroundStyle(.secondary).padding(.leading, 16)
                    case let .item(marker, text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(marker)
                            inline(text)
                        }.padding(.leading, 12)
                    case .divider:
                        Divider()
                    }
                }
            }.frame(maxWidth: 780, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity)
                .textSelection(.enabled)
        }
    }
}
