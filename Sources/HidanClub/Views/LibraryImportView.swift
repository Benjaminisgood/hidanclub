import SwiftUI
import UniformTypeIdentifiers

/// Formats one import batch for the page that started it. Successes name the
/// published entry; refusals name the file and the exact reason.
enum LibraryImportNotice {
    static func text(_ results: [LibraryFileImport], destination: CapturedLibraryStore.Destination) -> String {
        guard !results.isEmpty else { return "" }
        let target = destination == .actions ? "动作库" : "编排库"
        let succeeded = results.filter(\.succeeded)
        var lines: [String] = []
        if succeeded.isEmpty {
            lines.append("没有文件被导入\(target)；原文件未被修改。")
        } else {
            lines.append("已导入 \(succeeded.count) 条到\(target)：" + succeeded.compactMap { item in
                guard let model = item.published else { return nil }
                return "「\(model.name)」\(item.detail ?? "")"
            }.joined(separator: "；"))
        }
        for item in results {
            for note in item.notes { lines.append("· \(item.fileName)：\(note)") }
            if let problem = item.problem { lines.append("· \(item.fileName)：\(problem)") }
        }
        lines.append("导入只读取原文件，保存的是独立副本；完整原始帧、置信度与时间戳保留。")
        return lines.joined(separator: "\n")
    }
}

/// One import entry point shared by 动作库 and 编排库: pick JSON files, publish
/// independent copies, and report every file by name. The page owns the notice
/// binding so it can place the status where its layout expects it.
struct LibraryImportButton: View {
    var title: String
    var destination: CapturedLibraryStore.Destination
    @ObservedObject var store: CapturedLibraryStore
    @Binding var notice: String?
    var onImported: ([LibraryFileImport]) -> Void = { _ in }
    @State private var isPicking = false

    private var prompt: String {
        destination == .actions
            ? "选择 Hidan Club 动作模型 JSON（例如 *.hidanclub.json）。文件里的片段范围会成为一条独立动作；原文件只读。"
            : "选择 Hidan Club 动作模型 JSON（例如 *.hidanclub.json）。文件里的全部片段顺序和重复次数会保留为一套编排；原文件只读。"
    }

    var body: some View {
        Button(title, systemImage: "square.and.arrow.down") { notice = nil; isPicking = true }
            .disabled(store.isImporting || store.isLoading)
            .accessibilityIdentifier(destination == .actions ? "library.import.actions" : "library.import.arrangements")
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.json], allowsMultipleSelection: true,
                          onCompletion: complete)
    }

    private func complete(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task {
                let results = await store.importFiles(urls, to: destination)
                notice = LibraryImportNotice.text(results, destination: destination)
                onImported(results)
            }
        case .failure(let error):
            notice = "无法打开文件选择器：\(error.localizedDescription)"
        }
    }
}

/// Status line for an import batch, including the busy state of the store.
struct LibraryImportStatus: View {
    @ObservedObject var store: CapturedLibraryStore
    var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isImporting {
                Label("正在导入并校验文件…", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
