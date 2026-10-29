import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: DocLibrary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索文档…", text: $library.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !library.query.isEmpty {
                    Button {
                        library.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            List(selection: $library.selectedArticleID) {
                Label("首页", systemImage: "house.fill")
                    .font(.system(size: 13, weight: .medium))
                    .tag(String?.none)

                ForEach(library.sections) { section in
                    Section {
                        ForEach(section.articles) { article in
                            ArticleRow(article: article)
                                .tag(Optional(article.id))
                        }
                    } header: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minHeight: 400)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.145, green: 0.133, blue: 0.282))
                Image(systemName: "figure.dance")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.heroGradient)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Hidan Club")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                Text("官方文档 · Docs")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct TOCView: View {
    let article: DocArticle
    @EnvironmentObject private var library: DocLibrary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Label("本页目录", systemImage: "list.bullet")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                if article.document.toc.isEmpty {
                    Text("本篇没有子章节。")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(article.document.toc) { entry in
                        Button {
                            library.requestScroll(to: entry.id)
                        } label: {
                            Text(entry.title)
                                .font(.system(size: entry.level == 2 ? 12.5 : 11.5,
                                                weight: entry.level == 2 ? .medium : .regular))
                                .foregroundStyle(entry.level == 2 ? Color.primary : Color.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .padding(.leading, entry.level == 3 ? 12 : 0)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
