import SwiftUI
import HidanCore

struct MoveLibraryTab: View {
    @State private var styleFilter: DanceStyle? = nil
    @State private var levelFilter: Int = 0

    private var moves: [DanceMove] {
        DanceCatalog.moves.filter { move in
            (styleFilter == nil || move.style == styleFilter) &&
            (levelFilter == 0 || move.level == levelFilter)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("风格", selection: $styleFilter) {
                        Text("全部").tag(DanceStyle?.none)
                        ForEach(DanceStyle.allCases) { style in
                            Text(style.displayName).tag(DanceStyle?.some(style))
                        }
                    }
                    Picker("等级", selection: $levelFilter) {
                        Text("全部").tag(0)
                        Text("入门").tag(1)
                        Text("基础进阶").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text(DanceCatalog.contentNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(moves) { move in
                    NavigationLink(value: move.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(move.name).font(.headline)
                            Text("\(move.style.displayName) · \(move.levelName) · \(move.bpmLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("动作库")
            .navigationDestination(for: String.self) { id in
                if let move = DanceCatalog.move(id: id) {
                    MoveDetailView(move: move)
                }
            }
        }
    }
}

struct MoveDetailView: View {
    let move: DanceMove
    @State private var speed: Double = 1
    private static var frameCache: [String: [[SIMD3<Double>]]] = [:]

    private var frames: [[SIMD3<Double>]] {
        if let cached = Self.frameCache[move.id] { return cached }
        let built = SkeletonCanvasView.frames(for: move)
        Self.frameCache[move.id] = built
        return built
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SkeletonCanvasView(frames: frames, speed: speed)
                    .frame(height: 300)

                ClubCardIOS {
                    VStack(alignment: .leading, spacing: 8) {
                        EyebrowIOS(text: "SKELETON PREVIEW")
                        Text(move.name).font(.title3.bold())
                        Text(move.summary).font(.callout).foregroundStyle(.secondary)
                        Picker("速度", selection: $speed) {
                            ForEach(MotionTempo.speedChoices, id: \.self) { value in
                                Text(String(format: "%.2g×", value)).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Label("\(move.style.displayName) · \(move.levelName) · \(move.impact.displayName)",
                              systemImage: "figure.dance")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(move.bpmLabel + "（建议练习起点）", systemImage: "metronome")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("约 \(move.durationSeconds) 秒一组", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                ClubCardIOS {
                    VStack(alignment: .leading, spacing: 6) {
                        EyebrowIOS(text: "CUES")
                        Text("练习提示").font(.headline)
                        ForEach(move.cues, id: \.self) { cue in
                            Label(cue, systemImage: "checkmark.circle")
                                .font(.callout).labelStyle(.titleAndIcon)
                        }
                    }
                }

                ClubCardIOS {
                    VStack(alignment: .leading, spacing: 6) {
                        EyebrowIOS(text: "MISTAKES")
                        Text("常见错误").font(.headline)
                        ForEach(move.commonMistakes, id: \.self) { mistake in
                            Label(mistake, systemImage: "exclamationmark.triangle")
                                .font(.callout).labelStyle(.titleAndIcon)
                        }
                    }
                }

                if !move.prerequisites.isEmpty {
                    ClubCardIOS {
                        VStack(alignment: .leading, spacing: 6) {
                            EyebrowIOS(text: "PREREQUISITES")
                            Text("建议先熟悉").font(.headline)
                            ForEach(move.prerequisites, id: \.self) { id in
                                Text(DanceCatalog.move(id: id)?.name ?? id).font(.callout)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(move.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
