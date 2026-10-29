import Foundation
import SwiftUI

struct CatalogEntry {
    let file: String
    let section: DocSectionID
    let symbol: String
    let summary: String
}

enum DocSectionID: String, CaseIterable, Identifiable {
    case overview
    case quickstart
    case guide
    case advanced
    case reference
    case faq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .quickstart: return "快速开始"
        case .guide: return "功能指南"
        case .advanced: return "进阶"
        case .reference: return "参考"
        case .faq: return "FAQ"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "sparkles"
        case .quickstart: return "bolt.fill"
        case .guide: return "figure.dance"
        case .advanced: return "square.stack.3d.up.fill"
        case .reference: return "book.closed.fill"
        case .faq: return "questionmark.circle.fill"
        }
    }
}

struct DocArticle: Identifiable, Hashable {
    let id: String
    let fileName: String
    let section: DocSectionID
    let symbol: String
    let summary: String
    let title: String
    let document: MarkdownDocument
    let characterCount: Int
    let readingMinutes: Int

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DocArticle, rhs: DocArticle) -> Bool { lhs.id == rhs.id }
}

struct DocSection: Identifiable {
    let id: DocSectionID
    var articles: [DocArticle]
    var title: String { id.title }
    var symbol: String { id.symbol }
}

struct SearchHit: Identifiable {
    let id: String
    let article: DocArticle
    let snippet: String
    let ranges: [Range<String.Index>]
    let titleMatched: Bool

    var matchCount: Int { ranges.count }
}

final class DocLibrary: ObservableObject {
    static let catalog: [CatalogEntry] = [
        CatalogEntry(file: "overview", section: .overview, symbol: "house.fill",
                     summary: "产品定位、本地优先与隐私理念、能力全景"),
        CatalogEntry(file: "ui-tour", section: .overview, symbol: "square.grid.2x2.fill",
                     summary: "侧边栏、训练台、动作库、音乐条的界面导览"),
        CatalogEntry(file: "quickstart", section: .quickstart, symbol: "terminal.fill",
                     summary: "构建、运行、测试与打包验证的完整命令"),
        CatalogEntry(file: "first-session", section: .quickstart, symbol: "figure.dance",
                     summary: "第一次打开应用的 15 分钟上手路径"),
        CatalogEntry(file: "motion-library", section: .guide, symbol: "cube.box.fill",
                     summary: "3D 示范、基本功、我的动作与 JSON 导入"),
        CatalogEntry(file: "training-studio", section: .guide, symbol: "play.rectangle.fill",
                     summary: "训练计划、四种画面布局与训练状态机"),
        CatalogEntry(file: "live-camera", section: .guide, symbol: "camera.fill",
                     summary: "实时摄像头、Vision 捕捉与入镜指导"),
        CatalogEntry(file: "video-library", section: .guide, symbol: "video.fill",
                     summary: "视频导入、录像与逐帧肢体识别"),
        CatalogEntry(file: "segmentation", section: .guide, symbol: "scissors",
                     summary: "智能分段建议、A–B 区间与编排库"),
        CatalogEntry(file: "music-library", section: .guide, symbol: "music.note",
                     summary: "原创八拍、导入音乐、BPM 估计与倍速"),
        CatalogEntry(file: "party", section: .guide, symbol: "person.2.fill",
                     summary: "房间码、TLS-PSK、节拍同步与共享限制"),
        CatalogEntry(file: "aist-dataset", section: .advanced, symbol: "externaldrive.fill",
                     summary: "AIST++ 下载、校验、数据规格与 CC BY 4.0"),
        CatalogEntry(file: "architecture", section: .advanced, symbol: "cpu",
                     summary: "HidanCore、Vision、VideoToolbox 与 Network.framework"),
        CatalogEntry(file: "data-privacy", section: .advanced, symbol: "lock.shield.fill",
                     summary: "数据存哪里、隔离变量与不上传承诺"),
        CatalogEntry(file: "verification", section: .reference, symbol: "checkmark.seal.fill",
                     summary: "各版本验证记录摘要与证据边界"),
        CatalogEntry(file: "scripts", section: .reference, symbol: "hammer.fill",
                     summary: "全部构建、测试与 QA 脚本速查表"),
        CatalogEntry(file: "faq", section: .faq, symbol: "questionmark.bubble.fill",
                     summary: "常见问题与故障排查"),
        CatalogEntry(file: "roadmap", section: .faq, symbol: "map.fill",
                     summary: "当前限制与分阶段路线图"),
    ]

    @Published private(set) var sections: [DocSection] = []
    @Published var query: String = ""
    @Published var selectedArticleID: String?
    @Published var scrollRequest: ScrollRequest?

    private var articlesByID: [String: DocArticle] = [:]

    init() {
        load()
    }

    var allArticles: [DocArticle] {
        sections.flatMap(\.articles)
    }

    var totalCharacters: Int {
        allArticles.reduce(0) { $0 + $1.characterCount }
    }

    func article(_ id: String) -> DocArticle? {
        articlesByID[id]
    }

    func articleID(from url: URL) -> String? {
        guard url.scheme == nil || url.scheme == "doc" else { return nil }
        let candidate = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !candidate.isEmpty, article(candidate) != nil else { return nil }
        return candidate
    }

    func open(_ id: String) {
        selectedArticleID = id
        #if os(macOS)
        query = ""
        #endif
    }

    func requestScroll(to headingID: String) {
        scrollRequest = ScrollRequest(target: headingID,
                                      seq: (scrollRequest?.seq ?? 0) + 1)
    }

    private func load() {
        var built: [DocSectionID: [DocArticle]] = [:]
        for entry in Self.catalog {
            guard let url = Bundle.main.url(forResource: entry.file,
                                            withExtension: "md",
                                            subdirectory: "Docs")
                ?? Bundle.main.url(forResource: entry.file, withExtension: "md") else {
                continue
            }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let document = MarkdownParser.parse(source)
            let title = document.title.isEmpty ? entry.file : document.title
            let bodyText = document.plainText
            let count = Self.readableCharacterCount(bodyText) + title.count
            let article = DocArticle(
                id: entry.file,
                fileName: entry.file + ".md",
                section: entry.section,
                symbol: entry.symbol,
                summary: entry.summary,
                title: title,
                document: document,
                characterCount: count,
                readingMinutes: Self.readingMinutes(for: count)
            )
            built[entry.section, default: []].append(article)
            articlesByID[entry.file] = article
        }
        sections = DocSectionID.allCases.compactMap { sectionID in
            guard let articles = built[sectionID], !articles.isEmpty else { return nil }
            return DocSection(id: sectionID, articles: articles)
        }
    }

    static func readableCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    static func readingMinutes(for characters: Int) -> Int {
        max(1, Int((Double(characters) / 420.0).rounded()))
    }

    var searchResults: [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let needle = q.lowercased()
        var hits: [SearchHit] = []
        for article in allArticles {
            let titleMatched = article.title.lowercased().contains(needle)
                || article.summary.lowercased().contains(needle)
            let lowerText = article.document.plainText.lowercased()
            var ranges: [Range<String.Index>] = []
            var snippet = ""
            var searchStart = lowerText.startIndex
            var firstMatch: Range<String.Index>?
            while let r = lowerText.range(of: needle, range: searchStart..<lowerText.endIndex) {
                ranges.append(r)
                if firstMatch == nil { firstMatch = r }
                searchStart = r.upperBound
                if ranges.count >= 500 { break }
            }
            if let first = firstMatch {
                snippet = Self.makeSnippet(from: article.document.plainText,
                                           matchOffset: lowerText.distance(from: lowerText.startIndex,
                                                                           to: first.lowerBound))
            } else if titleMatched {
                snippet = article.summary
            }
            if titleMatched || !ranges.isEmpty {
                hits.append(SearchHit(id: article.id + "-hit",
                                      article: article,
                                      snippet: snippet,
                                      ranges: Self.snippetRanges(snippet, needle: q),
                                      titleMatched: titleMatched))
            }
        }
        hits.sort { lhs, rhs in
            if lhs.titleMatched != rhs.titleMatched { return lhs.titleMatched }
            return lhs.matchCount > rhs.matchCount
        }
        return hits
    }

    private static func makeSnippet(from text: String, matchOffset: Int) -> String {
        let start = max(0, matchOffset - 42)
        let end = min(text.count, matchOffset + 78)
        guard start < text.count else { return String(text.prefix(120)) }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        var snippet = String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
        if start > 0 { snippet = "…" + snippet }
        if end < text.count { snippet = snippet + "…" }
        return snippet
    }

    private static func snippetRanges(_ snippet: String, needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = snippet.startIndex
        while let r = snippet.range(of: needle,
                                    options: .caseInsensitive,
                                    range: start..<snippet.endIndex) {
            ranges.append(r)
            start = r.upperBound
        }
        return ranges
    }
}

struct ScrollRequest: Equatable {
    let target: String
    let seq: Int
}

func highlightedText(_ text: String, ranges: [Range<String.Index>]) -> Text {
    guard !ranges.isEmpty else { return Text(text) }
    var result = Text("")
    var cursor = text.startIndex
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        guard range.lowerBound >= cursor, range.upperBound <= text.endIndex else { continue }
        if range.lowerBound > cursor {
            result = result + Text(String(text[cursor..<range.lowerBound]))
        }
        result = result + Text(String(text[range]))
            .bold()
            .foregroundColor(Theme.accentPurple)
        cursor = range.upperBound
    }
    if cursor < text.endIndex {
        result = result + Text(String(text[cursor..<text.endIndex]))
    }
    return result
}
