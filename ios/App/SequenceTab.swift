import SwiftUI
import HidanCore

struct SequenceTab: View {
    @State private var selectedIDs: Set<String> = []
    @State private var bpm: Double = 90
    @State private var sequence: DanceSequence?
    @State private var errorMessage: String?
    @State private var seed = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ClubCardIOS {
                        VStack(alignment: .leading, spacing: 10) {
                            EyebrowIOS(text: "4 × 8 BUILDER")
                            Text("编排一个 4×8 拍组合").font(.headline)
                            Text(DanceSequence.generationNotice)
                                .font(.footnote).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text("BPM：\(Int(bpm))").font(.callout)
                                Slider(value: $bpm, in: 60...140, step: 1)
                            }
                            Button {
                                build()
                            } label: {
                                Label(sequence == nil ? "生成组合" : "换一个组合", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    ClubCardIOS {
                        VStack(alignment: .leading, spacing: 6) {
                            EyebrowIOS(text: "PICK MOVES")
                            Text("选择动作（低冲击站立动作才会入选）")
                                .font(.headline)
                            ForEach(DanceCatalog.moves) { move in
                                Button {
                                    toggle(move.id)
                                } label: {
                                    HStack {
                                        Image(systemName: selectedIDs.contains(move.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedIDs.contains(move.id)
                                                             ? ClubThemeIOS.accent : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(move.name).font(.subheadline)
                                            Text("\(move.style.displayName) · \(move.bpmLabel)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }

                    if let sequence {
                        ClubCardIOS {
                            VStack(alignment: .leading, spacing: 8) {
                                EyebrowIOS(text: "SEQUENCE")
                                Text("\(Int(sequence.bpm)) BPM · 约 \(String(format: "%.0f", sequence.durationSeconds)) 秒")
                                    .font(.headline)
                                ForEach(sequence.slots) { slot in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("第\(slot.index + 1)个八拍")
                                            .font(.caption.bold().monospaced())
                                            .frame(width: 66, alignment: .leading)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(slot.moveName).font(.subheadline.weight(.medium))
                                            Text(slot.cue).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                ForEach(sequence.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("编排")
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func build() {
        seed += 1
        do {
            sequence = try SequenceBuilder.make(moveIDs: Array(selectedIDs), bpm: bpm, seed: seed)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
