import SwiftUI

struct ResourceItem: Identifiable {
    let id: String
    let category: String
    let title: String
    let summary: String
    let use: String
    let url: String
}

struct ResourcesView: View {
    @State private var query = ""
    private let resources: [ResourceItem] = [
        .init(id: "aist", category: "舞蹈数据", title: "AIST++", summary: "已接入完整发布集：1,408 条序列、10 个舞种、1,123,873 个独立 3D 帧。在动作库点开一条，即可慢放、循环并开始练习。", use: "原始与官方优化全帧坐标；CC BY 4.0；原视频与音乐另有条款", url: "https://google.github.io/aistplusplus_dataset/"),
        .init(id: "fine", category: "舞蹈数据", title: "FineDance", summary: "关注手部与全身细节的音乐舞蹈数据。论文总量与公开子集大小不同。", use: "研究参考；非商业与分发限制", url: "https://github.com/li-ronghui/FineDance"),
        .init(id: "edge", category: "生成研究", title: "EDGE", summary: "音乐条件下生成舞蹈的研究系统，不能据此认定生成动作适合教学或训练。", use: "代码、权重和训练素材分别核对许可", url: "https://github.com/Stanford-TML/EDGE"),
        .init(id: "amass", category: "动作数据", title: "AMASS", summary: "统一人体动作捕捉数据，涵盖范围很广，并非街舞教学动作库。", use: "不作为本应用内置训练素材", url: "https://amass.is.tue.mpg.de/"),
        .init(id: "vision", category: "开发能力", title: "Apple Vision", summary: "设备端人体关键点检测，是视频动作观察的底层能力。骨架不是舞步标签。", use: "原型使用 2D；未训练舞步分类器", url: "https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest"),
        .init(id: "st", category: "教学入口", title: "STEEZY Studio", summary: "分级舞蹈课程；可参考镜像、循环、视角切换、慢速学习等交互。", use: "外部订阅服务，不抓取或内置课程", url: "https://www.steezy.co/"),
        .init(id: "redbull", category: "待核实候选", title: "Red Bull Dance", summary: "街舞文化阅读与视频发现的候选入口。本轮访问返回 403，未核实具体内容。", use: "仅外部链接，内容与使用条款待核查", url: "https://www.redbull.com/int-en/tags/dance")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(text: "RESEARCH / 有出处的学习")
                Text("动作背后，也有知识。").font(.system(size: 30, weight: .bold))
                Text("从街舞文化到动作数据，区分“可以阅读”和“可以放进应用”。").foregroundStyle(.secondary)
                TextField("搜索资源、技术或舞蹈数据", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                ForEach(resources.filter { query.isEmpty || ($0.title + $0.summary + $0.category).localizedCaseInsensitiveContains(query) }) { item in
                    ClubCard {
                        HStack(alignment: .top, spacing: 20) {
                            Image(systemName: item.category.contains("数据") ? "square.stack.3d.up" : "arrow.up.right.square").font(.title2).foregroundStyle(ClubTheme.accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(item.title).font(.title3.weight(.semibold)); Text(item.category).font(.caption).foregroundStyle(.secondary) }
                                Text(item.summary)
                                Text(item.use).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = URL(string: item.url) { Link("打开来源 ↗", destination: url).font(.callout.weight(.medium)) }
                        }
                    }
                }
                Text("调研日期：2026-09-09。完整来源与数据校验见项目 docs。AIST++ 坐标存放在本机应用支持目录，独立于应用包；原视频、音乐及模型权重尚未下载。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
    }
}
