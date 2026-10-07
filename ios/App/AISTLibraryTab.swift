import SwiftUI
import HidanCore

/// One entry from AIST/training-moves.json.
struct AISTTrainingMoveEntry: Decodable, Identifiable, Hashable {
    let id: String
    let style: String
    let genreCode: String
    let choreographyCode: String
    let name: String
    let observationCue: String
}

struct AISTTrainingMovesFile: Decodable {
    let sourceURL: String?
    let entries: [AISTTrainingMoveEntry]
}

struct AISTChoreographyNameEntry: Decodable, Identifiable, Hashable {
    let genreCode: String
    let choreographyCode: String
    let sourceName: String
    var id: String { genreCode + "/" + choreographyCode }
}

struct AISTChoreographyNamesFile: Decodable {
    let entries: [AISTChoreographyNameEntry]
}

/// Loads the AIST JSON datasets that ship inside the app bundle. On iOS these are
/// referenced as individual folders (AIST/, Brand/) rather than a "Resources" dir.
@MainActor
final class AISTResourceStore: ObservableObject {
    @Published private(set) var trainingMoves: [AISTTrainingMoveEntry] = []
    @Published private(set) var choreographyNames: [AISTChoreographyNameEntry] = []
    @Published private(set) var logo: UIImage?
    @Published private(set) var loadMessage: String?

    init() { load() }

    func load() {
        var notes: [String] = []

        if let url = Bundle.main.url(forResource: "training-moves", withExtension: "json", subdirectory: "AIST") {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(AISTTrainingMovesFile.self, from: data)
                trainingMoves = decoded.entries
                notes.append("training-moves.json \(decoded.entries.count) 段")
            } catch {
                notes.append("training-moves.json 解析失败：\(error.localizedDescription)")
            }
        } else {
            notes.append("未找到 AIST/training-moves.json")
        }

        if let url = Bundle.main.url(forResource: "choreography-names", withExtension: "json", subdirectory: "AIST") {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(AISTChoreographyNamesFile.self, from: data)
                choreographyNames = decoded.entries
                notes.append("choreography-names.json \(decoded.entries.count) 条")
            } catch {
                notes.append("choreography-names.json 解析失败：\(error.localizedDescription)")
            }
        } else {
            notes.append("未找到 AIST/choreography-names.json")
        }

        if let url = Bundle.main.url(forResource: "HidanLogo", withExtension: "png", subdirectory: "Brand") {
            logo = UIImage(contentsOfFile: url.path)
            notes.append(logo == nil ? "HidanLogo.png 解码失败" : "HidanLogo.png 已加载")
        } else {
            notes.append("未找到 Brand/HidanLogo.png")
        }

        loadMessage = notes.joined(separator: " · ")
    }

    func name(for move: AISTTrainingMoveEntry) -> String {
        choreographyNames.first { $0.genreCode == move.genreCode && $0.choreographyCode == move.choreographyCode }?.sourceName
            ?? move.name
    }
}

struct AISTLibraryTab: View {
    @StateObject private var store = AISTResourceStore()
    @State private var styleFilter: String = "all"

    private var styles: [String] {
        var seen: [String] = []
        for move in store.trainingMoves where !seen.contains(move.style) { seen.append(move.style) }
        return seen
    }

    private var filtered: [AISTTrainingMoveEntry] {
        styleFilter == "all" ? store.trainingMoves : store.trainingMoves.filter { $0.style == styleFilter }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if let logo = store.logo {
                            Image(uiImage: logo)
                                .resizable().scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "figure.dance")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AIST 曲库").font(.headline)
                            Text(store.loadMessage ?? "加载中…")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !store.trainingMoves.isEmpty {
                    Section {
                        Picker("风格", selection: $styleFilter) {
                            Text("全部").tag("all")
                            ForEach(styles, id: \.self) { style in
                                Text(style).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    if filtered.isEmpty {
                        Text("没有可显示的 AIST 动作数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { move in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(move.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(move.genreCode) · \(move.choreographyCode)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Text(store.name(for: move) == move.name ? move.observationCue : "来源名：\(store.name(for: move)) · \(move.observationCue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
            .navigationTitle("AIST 曲库")
        }
    }
}
