import SwiftUI

struct ArticleView: View {
    let article: DocArticle
    @EnvironmentObject private var library: DocLibrary
    @Environment(\.colorScheme) private var scheme

    private var bodyBlocks: [Block] {
        var blocks = article.document.blocks
        if case .heading(let level, _, _) = blocks.first, level == 1 {
            blocks.removeFirst()
        }
        return blocks
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    header
                    ForEach(bodyBlocks.indices, id: \.self) { index in
                        blockView(bodyBlocks[index])
                    }
                    articleFooter
                }
                .frame(maxWidth: Theme.contentMaxWidth)
                .padding(.horizontal, 30)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.cardBackground(scheme: scheme).opacity(0.25))
            .onChange(of: library.scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(request.target, anchor: .top)
                }
            }
            #if os(iOS)
            .navigationTitle(article.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if article.document.toc.isEmpty {
                            Text("本页没有子章节")
                        } else {
                            ForEach(article.document.toc) { entry in
                                Button(entry.title) {
                                    library.requestScroll(to: entry.id)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            #endif
        }
        #if os(macOS)
        .navigationTitle(article.title)
        #endif
    }

    private func blockView(_ block: Block) -> some View {
        Group {
            if case let .heading(_, id, _) = block {
                MarkdownBlockView(block: block)
                    .id(id)
            } else {
                MarkdownBlockView(block: block)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(article.section.title, systemImage: article.section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentPurple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accentPurple.opacity(scheme == .dark ? 0.16 : 0.09))
                    .clipShape(Capsule())

                Label("\(article.readingMinutes) 分钟阅读", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Label("\(article.characterCount) 字", systemImage: "textformat.size")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(article.title)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.heroGradient)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text(article.summary)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(5)

            Rectangle()
                .fill(Theme.brandGradient)
                .frame(width: 72, height: 4)
                .clipShape(Capsule())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
        .id("top")
    }

    private var articleFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 8)

            HStack(spacing: 10) {
                if let previous = neighbor(of: article.id, offset: -1) {
                    neighborChip(article: previous, symbol: "chevron.left", leading: true)
                }
                Spacer(minLength: 0)
                if let next = neighbor(of: article.id, offset: 1) {
                    neighborChip(article: next, symbol: "chevron.right", leading: false)
                }
            }
        }
    }

    private func neighbor(of id: String, offset: Int) -> DocArticle? {
        let all = library.allArticles
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard target >= 0, target < all.count else { return nil }
        return all[target]
    }

    private func neighborChip(article: DocArticle, symbol: String, leading: Bool) -> some View {
        navigationButton(id: article.id) {
            HStack(spacing: 8) {
                if leading { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                VStack(alignment: leading ? .leading : .trailing, spacing: 1) {
                    Text(leading ? "上一篇" : "下一篇")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(article.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                if !leading { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.cardBackground(scheme: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.cardStroke(scheme: scheme), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func navigationButton<Content: View>(id: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        Button {
            library.open(id)
            library.requestScroll(to: "top")
        } label: {
            content()
        }
        .buttonStyle(.plain)
        #else
        NavigationLink(value: id) {
            content()
        }
        .buttonStyle(.plain)
        #endif
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var library: DocLibrary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let results = library.searchResults
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索 “\(library.query)”")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(results.isEmpty
                         ? "没有匹配的文档，试试其他关键词。"
                         : "在 \(results.count) 篇文章中找到匹配，按相关度排序。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                ForEach(results) { hit in
                    SearchHitRow(hit: hit)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardBackground(scheme: scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Theme.cardStroke(scheme: scheme), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            library.open(hit.article.id)
                        }
                }
            }
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: hit.article.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.brandGradient)
                Text(hit.article.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                if hit.titleMatched {
                    Text("标题命中")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.accentCyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentCyan.opacity(0.13))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                Text(hit.article.section.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            if !hit.snippet.isEmpty {
                highlightedText(hit.snippet, ranges: hit.ranges)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if hit.matchCount > 1 {
                Text("全文共 \(hit.matchCount) 处匹配 · \(hit.article.readingMinutes) 分钟阅读")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
