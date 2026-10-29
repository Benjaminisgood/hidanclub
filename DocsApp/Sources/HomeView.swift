import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: DocLibrary
    @Environment(\.colorScheme) private var scheme

    private var articleCount: Int { library.allArticles.count }
    private var totalChars: Int { library.totalCharacters }

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                hero
                statsBar
                featureGrid
                quickLinks
                allSectionsCard
                footer
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .background(backgroundLayer)
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "figure.dance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.heroGradient)
                Text("HIDAN CLUB · 官方文档")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(.secondary)
            }

            Text("Hidan Club Docs")
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.heroGradient)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("本地优先的 SwiftUI 街舞学习应用完整手册：训练台对照示范录制练习、视频库、Apple Vision 二维肢体识别、AIST++ 完整 3D 动作库（1,408 条序列）、动作与编排库、原创八拍音乐库，以及「一起跳」P2P 好友连线。")
                .font(.system(size: 15.5))
                .lineSpacing(7)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 640, alignment: .leading)

            HStack(spacing: 10) {
                heroLink(title: "快速开始", symbol: "bolt.fill", articleID: "quickstart", filled: true)
                heroLink(title: "产品概览", symbol: "sparkles", articleID: "overview", filled: false)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroLink(title: String, symbol: String, articleID: String, filled: Bool) -> some View {
        destination(for: articleID) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                filled
                    ? AnyShapeStyle(Theme.brandGradient)
                    : AnyShapeStyle(Color.primary.opacity(0.06))
            )
            .foregroundStyle(filled ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(filled ? Color.clear : Theme.cardStroke(scheme: scheme), lineWidth: 1)
            )
        }
    }

    private var statsBar: some View {
        HStack(spacing: 0) {
            statItem(value: "\(articleCount)", label: "篇文档", symbol: "doc.text.fill")
            divider
            statItem(value: "\(totalChars / 1000)k+", label: "总字数", symbol: "textformat.123")
            divider
            statItem(value: "1,408", label: "3D 动作序列", symbol: "cube.box.fill")
            divider
            statItem(value: "10", label: "舞种全覆盖", symbol: "music.note.list")
        }
        .padding(.vertical, 16)
        .background(Theme.cardBackground(scheme: scheme).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke(scheme: scheme), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func statItem(value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.brandGradient)
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private struct Feature {
        let symbol: String
        let title: String
        let text: String
        let articleID: String
        let tint: Color
    }

    private var features: [Feature] {
        [
            Feature(symbol: "play.rectangle.fill", title: "实时训练台",
                    text: "AIST++ 真实示范驱动训练计划，开始／暂停／换段联动，四种画面布局。",
                    articleID: "training-studio", tint: Theme.accentPurple),
            Feature(symbol: "camera.fill", title: "摄像头跟练",
                    text: "本机 Apple Vision 二维关节捕捉、入镜指导、肘膝投影角度，不上传画面。",
                    articleID: "live-camera", tint: Theme.accentCyan),
            Feature(symbol: "cube.box.fill", title: "动作库",
                    text: "1,408 条 3D 示范序列、16 张基本功文字卡、从视频导入的我的动作。",
                    articleID: "motion-library", tint: Theme.accentMagenta),
            Feature(symbol: "video.fill", title: "视频库与分段",
                    text: "原字节保存视频，逐帧识别，智能分段建议，A–B 区间导入动作库。",
                    articleID: "video-library", tint: Theme.accentLime),
            Feature(symbol: "music.note", title: "音乐库",
                    text: "原创八拍与导入音乐双播放器，本机估计整体 BPM，动作按倍速跟随。",
                    articleID: "music-library", tint: Theme.accentPurple),
            Feature(symbol: "person.2.fill", title: "「一起跳」",
                    text: "Bonjour 发现 + TLS-PSK 加密直连，H.264 画面互传，NTP 式节拍同步。",
                    articleID: "party", tint: Theme.accentCyan),
            Feature(symbol: "externaldrive.fill", title: "AIST++ 数据",
                    text: "官方完整 3D 标注无损接入：全帧 Float64、逐字节校验、CC BY 4.0。",
                    articleID: "aist-dataset", tint: Theme.accentMagenta),
            Feature(symbol: "lock.shield.fill", title: "数据与隐私",
                    text: "所有数据留在本机应用支持目录，无账户、无云端、无第三方依赖。",
                    articleID: "data-privacy", tint: Theme.accentLime),
        ]
    }

    private var featureGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("核心特性", symbol: "square.grid.2x2.fill")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(features, id: \.title) { feature in
                    featureCard(feature)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureCard(_ feature: Feature) -> some View {
        destination(for: feature.articleID) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(feature.tint)
                Text(feature.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(feature.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(Theme.cardBackground(scheme: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.cardStroke(scheme: scheme), lineWidth: 1)
            )
        }
    }

    private var quickLinks: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("快速入口", symbol: "arrow.turn.down.right")
            HStack(spacing: 10) {
                quickChip("构建与运行", symbol: "terminal.fill", id: "quickstart")
                quickChip("界面导览", symbol: "macwindow", id: "ui-tour")
                quickChip("AIST++ 数据接入", symbol: "externaldrive.fill", id: "aist-dataset")
                quickChip("FAQ 与排查", symbol: "questionmark.bubble.fill", id: "faq")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickChip(_ title: String, symbol: String, id: String) -> some View {
        destination(for: id) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(Theme.accentPurple)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.accentPurple.opacity(scheme == .dark ? 0.14 : 0.08))
            .clipShape(Capsule())
        }
    }

    private var allSectionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("全部章节", symbol: "books.vertical.fill")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 22)],
                      alignment: .leading, spacing: 20) {
                ForEach(library.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Theme.brandGradient)
                        ForEach(section.articles) { article in
                            destination(for: article.id) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(article.title)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(article.readingMinutes)′")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Theme.brandGradient)
                .frame(width: 60, height: 3)
                .clipShape(Capsule())
            Text("Hidan Club · 本地原生原型 · 版本 0.5 · 无第三方依赖 · AIST++ 标注 © Google LLC, CC BY 4.0")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func destination<Content: View>(for articleID: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        Button {
            library.open(articleID)
        } label: {
            content()
        }
        .buttonStyle(.plain)
        #else
        NavigationLink(value: articleID) {
            content()
        }
        .buttonStyle(.plain)
        #endif
    }

    private var backgroundLayer: some View {
        ZStack {
            Theme.accentPurple.opacity(scheme == .dark ? 0.07 : 0.05)
                .clipShape(Circle())
                .frame(width: 560, height: 560)
                .blur(radius: 90)
                .offset(x: -340, y: -300)
            Theme.accentCyan.opacity(scheme == .dark ? 0.06 : 0.05)
                .clipShape(Circle())
                .frame(width: 480, height: 480)
                .blur(radius: 90)
                .offset(x: 360, y: -160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
