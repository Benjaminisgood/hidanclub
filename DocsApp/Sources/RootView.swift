import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        #if os(macOS)
        MacRootView()
            .environment(\.openURL, OpenURLAction { url in
                if let id = library.articleID(from: url) {
                    library.open(id)
                    return .handled
                }
                return url.scheme == "doc" ? .handled : .systemAction
            })
        #else
        IOSRootView()
        #endif
    }
}

#if os(macOS)
struct MacRootView: View {
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 330)
        } content: {
            Group {
                if !library.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView()
                } else if let id = library.selectedArticleID,
                          let article = library.article(id) {
                    ArticleView(article: article)
                } else {
                    HomeView()
                }
            }
            .frame(minWidth: 500)
        } detail: {
            if let id = library.selectedArticleID,
               library.query.trimmingCharacters(in: .whitespaces).isEmpty,
               let article = library.article(id) {
                TOCView(article: article)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 218, max: 280)
            } else {
                DetailPlaceholder()
                    .navigationSplitViewColumnWidth(min: 170, ideal: 210)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct DetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 30))
                .foregroundStyle(Theme.brandGradient)
            Text("本页目录")
                .font(.system(size: 14, weight: .semibold))
            Text("选择一篇文章后，这里会显示可跳转的章节锚点。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#else
struct IOSRootView: View {
    @EnvironmentObject private var library: DocLibrary
    @State private var homePath: [String] = []
    @State private var catalogPath: [String] = []
    @State private var searchPath: [String] = []

    var body: some View {
        TabView {
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationTitle("Hidan Club Docs")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: String.self) { id in
                        articleDestination(id)
                    }
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .environment(\.openURL, urlAction(path: $homePath))

            NavigationStack(path: $catalogPath) {
                CatalogListView()
                    .navigationTitle("目录")
                    .navigationDestination(for: String.self) { id in
                        articleDestination(id)
                    }
            }
            .tabItem { Label("目录", systemImage: "list.bullet") }
            .environment(\.openURL, urlAction(path: $catalogPath))

            NavigationStack(path: $searchPath) {
                SearchTabView()
                    .navigationTitle("搜索")
                    .navigationDestination(for: String.self) { id in
                        articleDestination(id)
                    }
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .environment(\.openURL, urlAction(path: $searchPath))
        }
        .tint(Theme.accentPurple)
    }

    @ViewBuilder
    private func articleDestination(_ id: String) -> some View {
        if let article = library.article(id) {
            ArticleView(article: article)
        } else {
            ContentUnavailableView("未找到文档", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func urlAction(path: Binding<[String]>) -> OpenURLAction {
        OpenURLAction { url in
            if let id = library.articleID(from: url) {
                path.wrappedValue.append(id)
                return .handled
            }
            return url.scheme == "doc" ? .handled : .systemAction
        }
    }
}

struct CatalogListView: View {
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        List {
            ForEach(library.sections) { section in
                Section {
                    ForEach(section.articles) { article in
                        NavigationLink(value: article.id) {
                            ArticleRow(article: article)
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct SearchTabView: View {
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        Group {
            if library.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("输入关键词搜索",
                                       systemImage: "magnifyingglass",
                                       description: Text("支持标题与全文检索，命中关键词会高亮显示。"))
            } else {
                SearchResultsList()
            }
        }
        .searchable(text: $library.query, prompt: "搜索文档…")
    }
}

struct SearchResultsList: View {
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        let results = library.searchResults
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: library.query)
            } else {
                List {
                    ForEach(results) { hit in
                        NavigationLink(value: hit.article.id) {
                            SearchHitRow(hit: hit)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
#endif

struct ArticleRow: View {
    let article: DocArticle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: article.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(2)
                Text("\(article.readingMinutes) 分钟 · \(article.characterCount) 字")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
