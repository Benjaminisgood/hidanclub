import Foundation

enum MDAlign {
    case leading
    case center
    case trailing
}

struct InlineRun: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var code: Bool = false
    var link: String? = nil
}

struct ListItem: Equatable {
    var runs: [InlineRun]
    var children: [ListItem] = []
    var childrenOrdered: Bool = false
}

enum Block: Equatable {
    case heading(level: Int, id: String, runs: [InlineRun])
    case paragraph(runs: [InlineRun])
    case codeBlock(language: String, code: String)
    case list(ordered: Bool, items: [ListItem])
    case table(header: [[InlineRun]], alignments: [MDAlign], rows: [[[InlineRun]]])
    case blockquote(blocks: [Block])
    case thematicBreak
}

struct MarkdownDocument: Equatable {
    var blocks: [Block]
    var title: String
    var toc: [TOCEntry]
    var plainText: String
}

struct TOCEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let level: Int
}

struct InlineParser {
    static func parse(_ input: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var buffer = ""
        var bold = false
        var italic = false
        var code = false
        var linkText: String? = nil
        var linkURL = ""
        var inLinkURL = false

        func flush() {
            if !buffer.isEmpty {
                runs.append(InlineRun(text: buffer, bold: bold, italic: italic, code: code,
                                      link: linkText != nil ? linkURL : nil))
                buffer = ""
            }
        }

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if inLinkURL {
                if c == ")" {
                    inLinkURL = false
                    let savedBold = bold, savedItalic = italic
                    flush()
                    runs.append(InlineRun(text: linkText ?? linkURL, bold: savedBold, italic: savedItalic,
                                          link: linkURL))
                    linkText = nil
                    linkURL = ""
                    bold = savedBold
                    italic = savedItalic
                } else {
                    linkURL.append(c)
                }
                i += 1
                continue
            }

            if c == "\\" && i + 1 < chars.count, "*`_[]()#".contains(chars[i + 1]) {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`" {
                flush()
                code.toggle()
                i += 1
                continue
            }

            if !code {
                if c == "*" {
                    let starCount = runLength(chars, at: i, of: "*")
                    if starCount >= 3 {
                        flush(); bold.toggle(); italic.toggle(); i += 3; continue
                    } else if starCount == 2 {
                        flush(); bold.toggle(); i += 2; continue
                    } else {
                        flush(); italic.toggle(); i += 1; continue
                    }
                }
                if c == "[" {
                    flush()
                    linkText = ""
                    i += 1
                    var depth = 1
                    while i < chars.count {
                        if chars[i] == "[" { depth += 1 }
                        if chars[i] == "]" {
                            depth -= 1
                            if depth == 0 { i += 1; break }
                        }
                        linkText?.append(chars[i])
                        i += 1
                    }
                    if i < chars.count, chars[i] == "(" {
                        inLinkURL = true
                        i += 1
                        continue
                    } else {
                        buffer.append("[")
                        buffer.append(linkText ?? "")
                        linkText = nil
                        continue
                    }
                }
            }

            buffer.append(c)
            i += 1
        }
        flush()
        if let leftover = linkText {
            runs.append(InlineRun(text: "[" + leftover))
        }
        if inLinkURL, !linkURL.isEmpty {
            runs.append(InlineRun(text: "(" + linkURL))
        }
        return mergeAdjacent(runs)
    }

    private static func runLength(_ chars: [Character], at index: Int, of c: Character) -> Int {
        var n = 0
        var j = index
        while j < chars.count, chars[j] == c { n += 1; j += 1 }
        return n
    }

    private static func mergeAdjacent(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs {
            if var last = out.last,
               last.bold == run.bold, last.italic == run.italic,
               last.code == run.code, last.link == run.link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }
}

struct MarkdownParser {
    static func parse(_ source: String) -> MarkdownDocument {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = []
        var toc: [TOCEntry] = []
        var plainParts: [String] = []
        var headingCounter = 0
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let l = lines[index]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(l)
                    index += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                plainParts.append(codeLines.joined(separator: " "))
                continue
            }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    let runs = InlineParser.parse(content)
                    let id = "heading-\(headingCounter)"
                    headingCounter += 1
                    blocks.append(.heading(level: level, id: id, runs: runs))
                    if level >= 2 && level <= 3 {
                        toc.append(TOCEntry(id: id, title: content, level: level))
                    }
                    plainParts.append(content)
                    index += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let l = lines[index]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = String(t.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoteLines.append(content)
                        index += 1
                    } else if t.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                let inner = MarkdownParser.parse(quoteLines.joined(separator: "\n"))
                blocks.append(.blockquote(blocks: inner.blocks))
                plainParts.append(inner.plainText)
                continue
            }

            if isListLine(trimmed) {
                var listLines: [String] = []
                while index < lines.count {
                    let l = lines[index]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        var lookahead = index + 1
                        while lookahead < lines.count, lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
                            lookahead += 1
                        }
                        if lookahead < lines.count, isListLine(lines[lookahead].trimmingCharacters(in: .whitespaces))
                            || lines[lookahead].hasPrefix("  ") {
                            index = lookahead
                            continue
                        }
                        break
                    }
                    if isListLine(t) || l.hasPrefix(" ") || l.hasPrefix("\t") {
                        listLines.append(l)
                        index += 1
                    } else {
                        break
                    }
                }
                let (items, ordered) = parseList(listLines)
                blocks.append(.list(ordered: ordered, items: items))
                plainParts.append(listPlainText(items))
                continue
            }

            if trimmed.hasPrefix("|") && index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                var tableLines: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") {
                        tableLines.append(t)
                        index += 1
                    } else {
                        break
                    }
                }
                if let table = parseTable(tableLines) {
                    blocks.append(table)
                    plainParts.append(tablePlainText(table))
                }
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let l = lines[index]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("~~~")
                    || t.hasPrefix(">") || isListLine(t)
                    || t == "---" || t == "***" || t == "___" {
                    break
                }
                paragraphLines.append(t)
                index += 1
            }
            if !paragraphLines.isEmpty {
                let text = paragraphLines.joined(separator: " ")
                blocks.append(.paragraph(runs: InlineParser.parse(text)))
                plainParts.append(text)
            }
        }

        let plain = plainParts.joined(separator: "\n")
        let title: String = {
            for block in blocks {
                if case let .heading(level, _, runs) = block, level == 1 {
                    return runs.map(\.text).joined()
                }
            }
            return ""
        }()
        return MarkdownDocument(blocks: blocks, title: title, toc: toc, plainText: plain)
    }

    private static func isListLine(_ trimmed: String) -> Bool {
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            return rest.hasPrefix(" ") || rest.hasPrefix("\t")
        }
        var digits = ""
        for c in trimmed {
            if c.isNumber { digits.append(c) } else { break }
        }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            return rest.hasPrefix(". ") || rest.hasPrefix(") ")
        }
        return false
    }

    private final class Node {
        var runs: [InlineRun] = []
        var childList: ListBucket?
    }

    private final class ListBucket {
        var ordered: Bool
        var nodes: [Node] = []
        init(ordered: Bool) { self.ordered = ordered }
    }

    private static func parseList(_ lines: [String]) -> (items: [ListItem], ordered: Bool) {
        struct Token {
            let indent: Int
            let ordered: Bool
            var content: String
        }
        var tokens: [Token] = []
        for line in lines {
            var indent = 0
            for c in line {
                if c == " " { indent += 1 } else if c == "\t" { indent += 4 } else { break }
            }
            let trimmed = String(line.dropFirst(line.prefix(while: { $0 == " " || $0 == "\t" }).count))
            if trimmed.isEmpty { continue }
            if let first = trimmed.first, "-*+".contains(first), trimmed.count > 1,
               trimmed[trimmed.index(after: trimmed.startIndex)] == " " {
                tokens.append(Token(indent: indent, ordered: false,
                                    content: String(trimmed.dropFirst(2))))
                continue
            }
            var digits = ""
            for c in trimmed {
                if c.isNumber { digits.append(c) } else { break }
            }
            if !digits.isEmpty {
                let rest = trimmed.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                    tokens.append(Token(indent: indent, ordered: true, content: String(rest.dropFirst(2))))
                    continue
                }
            }
            if var last = tokens.last {
                last.content += " " + trimmed
                tokens[tokens.count - 1] = last
            }
        }

        guard !tokens.isEmpty else { return ([], false) }
        let rootOrdered = tokens[0].ordered
        let rootBucket = ListBucket(ordered: rootOrdered)
        var stack: [(indent: Int, bucket: ListBucket)] = [(tokens[0].indent, rootBucket)]

        for token in tokens {
            let node = Node()
            node.runs = InlineParser.parse(token.content)
            while stack.count > 1, stack[stack.count - 1].indent > token.indent {
                stack.removeLast()
            }
            let top = stack[stack.count - 1]
            if token.indent <= top.indent {
                top.bucket.nodes.append(node)
            } else {
                guard let parentNode = top.bucket.nodes.last else {
                    top.bucket.nodes.append(node)
                    continue
                }
                let childBucket: ListBucket
                if let existing = parentNode.childList {
                    childBucket = existing
                } else {
                    childBucket = ListBucket(ordered: token.ordered)
                    parentNode.childList = childBucket
                }
                childBucket.nodes.append(node)
                stack.append((indent: token.indent, bucket: childBucket))
            }
        }

        func convert(_ node: Node) -> ListItem {
            guard let bucket = node.childList else {
                return ListItem(runs: node.runs)
            }
            return ListItem(runs: node.runs,
                            children: bucket.nodes.map(convert),
                            childrenOrdered: bucket.ordered)
        }
        return (rootBucket.nodes.map(convert), rootOrdered)
    }

    private static func listPlainText(_ items: [ListItem]) -> String {
        var parts: [String] = []
        for item in items {
            parts.append(item.runs.map(\.text).joined())
            if !item.children.isEmpty {
                parts.append(listPlainText(item.children))
            }
        }
        return parts.joined(separator: " ")
    }

    private static func isTableSeparator(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("|") || trimmed.contains("---") else { return false }
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        guard !body.isEmpty else { return false }
        for c in body where !"-: ".contains(c) { return false }
        return body.contains("-")
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTable(_ lines: [String]) -> Block? {
        guard lines.count >= 2 else { return nil }
        let headerCells = splitRow(lines[0]).map { InlineParser.parse($0) }
        let alignCells = splitRow(lines[1])
        var alignments: [MDAlign] = []
        for cell in alignCells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { alignments.append(.center) }
            else if right { alignments.append(.trailing) }
            else { alignments.append(.leading) }
        }
        var rows: [[[InlineRun]]] = []
        for line in lines.dropFirst(2) {
            let cells = splitRow(line).map { InlineParser.parse($0) }
            rows.append(cells)
        }
        return .table(header: headerCells, alignments: alignments, rows: rows)
    }

    private static func tablePlainText(_ block: Block) -> String {
        guard case let .table(header, _, rows) = block else { return "" }
        var parts = header.map { $0.map(\.text).joined() }
        for row in rows {
            parts.append(contentsOf: row.map { $0.map(\.text).joined() })
        }
        return parts.joined(separator: " ")
    }
}
