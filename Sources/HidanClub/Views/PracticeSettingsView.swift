import AppKit
import SwiftUI

enum CoordinateLayerPreference {
    static let key = "aist.coordinateLayer"
    static var usesOptimized: Bool { UserDefaults.standard.string(forKey: key) != "raw" }
}

struct PracticeSettingsView: View {
    @ObservedObject var aist: AISTLibraryStore
    let trainingDirectory: URL
    @AppStorage("aist.visualStyle") private var visualStyle: AISTVisualStyle = .porcelain
    @AppStorage("aist.skeletonOverlay") private var skeletonOverlay = false
    @AppStorage("aist.showReferenceGrid") private var showReferenceGrid = false
    @AppStorage("aist.showJointNames") private var showJointNames = false
    @AppStorage("training.displayMode") private var displayMode: TrainingDisplayMode = .sideBySide
    @AppStorage("training.cameraOnByDefault") private var cameraOnByDefault = false
    @AppStorage(CoordinateLayerPreference.key) private var coordinateLayer = "optimized"
    @AppStorage("training.defaultRounds") private var defaultRounds = 4
    var onCoordinateLayerChange: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: "SETTINGS")
                    Text("设置").font(.system(size: 28, weight: .bold))
                    Text("外观、坐标来源和进入练习时的默认画面放在这里。跟练时的播放、速度和镜像仍留在动作里。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                appearance
                coordinates
                practice
                data
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appearance: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("动作预览").font(.headline)
                Text("动作库和跟练使用同一种人形。体型、手掌与脚部是外观示意，不改变原始关键点。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    ForEach(AISTVisualStyle.allCases) { style in
                        Button { visualStyle = style } label: {
                            HStack(spacing: 9) {
                                Image(systemName: style.symbol).font(.system(size: 18, weight: .medium))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(style.title).font(.system(size: 12, weight: .semibold))
                                    Text(style.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if visualStyle == style { Image(systemName: "checkmark.circle.fill").font(.caption) }
                            }.padding(.horizontal, 12).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(visualStyle == style ? ClubTheme.accent : .primary)
                                .background(visualStyle == style ? ClubTheme.accent.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(visualStyle == style ? ClubTheme.accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel(style.title)
                            .accessibilityValue(visualStyle == style ? "已选中" : "未选中")
                            .accessibilityIdentifier("aist.style.\(style.rawValue)")
                    }
                }
                Toggle("叠加骨架", isOn: $skeletonOverlay).disabled(visualStyle == .skeleton)
                Toggle("参考网格", isOn: $showReferenceGrid).disabled(visualStyle == .skeleton)
                Toggle("关节名称", isOn: $showJointNames)
                Text(visualStyle == .skeleton ? "经典骨架已包含关节与连线。绿色为左侧，紫色为右侧。" : "叠加骨架和网格只加在人形上，方便对照关节。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var coordinates: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("坐标来源").font(.headline)
                Text("动作库列表始终用原始逐帧重建自动播放。点开一条，或开始练习时，使用下面这一套。默认是官方时序优化。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("点开与练习", selection: $coordinateLayer) {
                    Text("原始逐帧重建").tag("raw")
                    Text("官方时序优化").tag("optimized")
                }.pickerStyle(.segmented)
                    .onChange(of: coordinateLayer) { _, _ in onCoordinateLayerChange() }
                Text("每条动作都必须同时有这两套坐标，缺任何一套就不会进入动作库。应用不会再额外平滑。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var practice: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("跟练").font(.headline)
                Text("从动作、编排或视频开始练习时，先用这里的画面和组数。练习里不再重复这排选择。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("默认画面", selection: $displayMode) {
                    ForEach(TrainingDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("默认组数", selection: $defaultRounds) {
                    Text("2 组").tag(2); Text("4 组").tag(4); Text("6 组").tag(6)
                }.pickerStyle(.segmented)
                Toggle("进入练习时开启摄像头", isOn: $cameraOnByDefault)
                Text(cameraOnByDefault ? "画面包含摄像头时会自动打开。只看示范时不会打开相机。" : "进入练习后，需要时再手动打开摄像头。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var data: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("本机数据").font(.headline)
                Text("动作数据和练习记录都在这台 Mac 上。").font(.caption).foregroundStyle(.secondary)
                Text(aist.directory.path).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("选择动作库目录") { aist.chooseDirectory() }
                    Button("重新读取") { aist.reload() }
                    Button("在 Finder 中查看") { NSWorkspace.shared.open(aist.directory) }
                }
                Divider()
                Button("打开练习记录目录") {
                    try? FileManager.default.createDirectory(at: trainingDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(trainingDirectory)
                }
            }
        }
    }
}
