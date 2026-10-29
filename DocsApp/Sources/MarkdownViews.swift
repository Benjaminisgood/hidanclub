import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

struct InlineTextView: View {
    let runs: [InlineRun]
    var baseSize: CGFloat = 15.5

    var body: some View {
        build(runs)
    }

    private func build(_ runs: [InlineRun]) -> Text {
        var result = Text("")
        for run in runs {
            var text: Text
            if let link = run.link, let url = URL(string: link) {
                var attributed = AttributedString(run.text)
                attributed.link = url
                attributed.foregroundColor = Theme.accentCyan
                attributed.underlineStyle = .single
                text = Text(attributed)
            } else if run.code {
                text = Text(run.text)
                    .font(.system(size: baseSize - 1.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.accentPurple)
            } else {
                text = Text(run.text)
            }
            if run.bold { text = text.bold() }
            if run.italic { text = text.italic() }
            result = result + text
        }
        return result
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.35)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.28)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 0.30, green: 0.83, blue: 0.49)).frame(width: 8, height: 8)
                Text(language.isEmpty ? "text" : language)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.leading, 4)
                Spacer(minLength: 8)
                Button {
                    Clipboard.copy(code)
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeInOut(duration: 0.3)) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(copied ? 0.95 : 0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.codeForeground)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

struct MarkdownTableView: View {
    let header: [[InlineRun]]
    let alignments: [MDAlign]
    let rows: [[[InlineRun]]]
    @Environment(\.colorScheme) private var scheme

    private func align(_ index: Int) -> Alignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .center: return .center
        case .trailing: return .trailing
        case .leading: return .leading
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        InlineTextView(runs: header[column], baseSize: 13.5)
                            .fontWeight(.semibold)
                            .frame(minWidth: 60, alignment: align(column))
                    }
                }
                GridRow {
                    Rectangle()
                        .fill(Theme.accentPurple.opacity(0.45))
                        .frame(height: 1.5)
                        .gridCellColumns(max(header.count, 1))
                }
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { column in
                            InlineTextView(runs: rows[rowIndex][column], baseSize: 13.5)
                                .frame(minWidth: 60, alignment: align(column))
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        GridRow {
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(height: 1)
                                .gridCellColumns(max(header.count, 1))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.cardBackground(scheme: scheme).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardStroke(scheme: scheme), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

struct MarkdownListView: View {
    let items: [ListItem]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Group {
                        if ordered {
                            Text("\(index + 1).")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.brandGradient)
                                .frame(minWidth: 20, alignment: .trailing)
                        } else {
                            Text("•")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.brandGradient)
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        InlineTextView(runs: items[index].runs)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !items[index].children.isEmpty {
                            MarkdownListView(items: items[index].children,
                                             ordered: items[index].childrenOrdered)
                                .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MarkdownBlockView: View {
    let block: Block
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case let .heading(level, _, runs):
            headingView(level: level, runs: runs)
        case let .paragraph(runs):
            InlineTextView(runs: runs)
                .lineSpacing(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)
        case let .list(ordered, items):
            MarkdownListView(items: items, ordered: ordered)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .table(header, alignments, rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
        case let .blockquote(blocks):
            blockquoteView(blocks: blocks)
        case .thematicBreak:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, runs: [InlineRun]) -> some View {
        let text = InlineTextView(runs: runs, baseSize: size(for: level))
        VStack(alignment: .leading, spacing: 6) {
            switch level {
            case 1:
                text.font(.system(size: size(for: 1), weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.heroGradient)
            case 2:
                text.font(.system(size: size(for: 2), weight: .bold, design: .rounded))
                Rectangle()
                    .fill(Theme.brandGradient)
                    .frame(width: 44, height: 3)
                    .clipShape(Capsule())
            default:
                text.font(.system(size: size(for: level), weight: .semibold, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, level <= 2 ? 18 : 12)
        .padding(.bottom, 2)
    }

    private func size(for level: Int) -> CGFloat {
        switch level {
        case 1: return 30
        case 2: return 22
        case 3: return 18
        case 4: return 16
        default: return 15
        }
    }

    private func blockquoteView(blocks: [Block]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.brandGradient)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlockView(block: blocks[index])
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(Theme.quoteBackground(scheme: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 4)
    }
}
