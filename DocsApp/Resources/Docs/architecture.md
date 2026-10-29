# 架构与技术实现

Hidan Club 是纯原生 Apple 技术栈应用：SwiftUI 界面 + Foundation-only 核心库，零第三方依赖。本文介绍模块划分、关键系统框架的使用方式与工程决策。

## 分层结构

```text
SwiftUI scenes / views
  ├─ HidanCore: 动作、训练计划、组合规则、计时状态机（Foundation-only，无 AppKit 依赖）
  ├─ TrainingStore: 训练状态与本地历史
  ├─ VideoService: AVPlayer、镜像显示、速度、A–B 循环
  ├─ MusicService: AVAudioEngine / PlayerNode / TimePitch；MusicLibraryStore 保存曲目与节拍
  ├─ AISTLibraryStore: 本地 manifest、全帧 Float64 序列与动作参考
  └─ PoseAnalyzer: AVAssetReader → Vision → 全帧 PoseReport
```

SwiftUI 应用与 `HidanCore` 分离的意义：核心逻辑可在无 UI 环境跑行为探针（QA 脚本正是这么做的），也为未来 iOS / iPadOS 移植留出空间。

## 源码目录

```text
Sources/
├── HidanCore/                 # Foundation-only 核心
│   ├── AISTArrangement.swift  # AIST 编排模型
│   ├── AISTModels.swift       # manifest 与序列数据合同
│   ├── AISTPractice.swift     # 片段跟练
│   ├── AISTTrainingPlan.swift # 训练计划模型
│   ├── DanceCatalog.swift     # 舞种目录
│   ├── DanceModels.swift      # 动作卡与规则组合
│   ├── LivePoseFeedback.swift # 实时反馈（入镜、角度）
│   ├── MusicTempo.swift       # 节拍模型
│   ├── PartyProtocol.swift    # 「一起跳」协议（Foundation-only）
│   ├── PlanBuilder.swift      # 计划生成规则
│   ├── PracticeMotion.swift   # 练习动作
│   ├── SequenceBuilder.swift  # 四组八拍序列
│   ├── TempoEstimator.swift   # 频谱通量 BPM 估计
│   └── TrainingClock.swift    # 计时状态机
└── HidanClub/                 # SwiftUI 应用
    ├── App/                   # HidanClubApp 入口
    ├── Models/                # CapturedMotion、CapturedMotionImport、LibraryTrack、
    │                          # LibraryVideo、PoseArrangementPlanner
    ├── Services/              # 见下表
    ├── Stores/                # 见下表
    ├── Support/               # AISTVisualStyle、BrandAssets、PlaybackControls、Theme
    ├── Views/                 # 24 个 SwiftUI 视图
    └── Resources/             # Brand（Logo PNG 与 AppIcon.icns）
```

### Services（系统框架封装）

| 服务 | 职责 | 关键框架 |
| --- | --- | --- |
| `PoseAnalyzer` | AVAssetReader 顺序解码 → Vision 逐帧检测 → 全帧 PoseReport | AVFoundation, Vision |
| `LivePoseCamera` | 摄像头采集与逐帧分发 | AVFoundation |
| `LivePoseFrameTap` | 图像与姿态同帧发布 | Vision |
| `CameraMovieRecorder` | 训练台录像生命周期 | AVFoundation |
| `VideoService` | 播放、镜像、速度、A–B 循环、精确 seek | AVFoundation |
| `MusicService` | 原创八拍合成与文件播放、TimePitch 变速 | AVAudioEngine |
| `MusicBeatAnalyzer` | 频谱通量 BPM 估计 | AVFoundation, Accelerate |
| `PartyService` | Bonjour 发现、TLS-PSK 连接管理 | Network.framework |
| `PartyVideoCodec` | H.264 编解码（640/960 宽） | VideoToolbox |
| `PartyMusicBridge` | 节拍镜像与 NTP 式时钟对齐 | Foundation |

### Stores（持久化与状态）

`TrainingStore`、`AISTLibraryStore`、`AISTArrangementStore`、`CapturedMotionStore`、`CapturedLibraryStore`、`VideoLibraryStore`、`MusicLibraryStore`、`PracticeMotionStore`、`TrainingDemonstrationStore`、`CapturedMotionPlayback`。全部基于本地 JSON / 二进制文件 + 原子写入，无数据库服务。

## Apple Vision：二维肢体识别

- 使用 `VNDetectHumanBodyPoseRequest` 做全帧 2D 人体关键点分析
- 顺序读取全部解码帧，校正轨道旋转／镜像（8 种标准变换的方向映射经过验证，非标准变换拒绝）
- 保存原始 PTS（value/timescale 逐位保留）；无检测保留空观测，多人保留 `ambiguous` 标记
- 取消不发布半份报告，旧任务不能覆盖新任务
- 坐标归一化且**原点左下**；骨架复查与视频显示不是相机标定后的运动捕捉

## SceneKit：3D 动作渲染

- COCO **17 节点、19 骨段**，固定显示变换，**逐帧无插值**
- 缺失关节及相邻连线隐藏；镜像／坐标轴／相机复位
- 关闭自动曝光，避免播放后颜色过亮
- 柔光人形／霓虹人形使用连续胸腰/骨盆曲面（`SCNGeometrySource` 自定义网格）、渐变四肢与示意手脚；经典骨架为双色节点加连线
- 透明叠加模式经真实 snapshot 验证：透明区域占 92.9%–98.3%，四角 alpha=0

性能决策：播放帧与播放状态拆入**独立 ObservableObject**，仅骨架／时间轴订阅逐帧更新，避免整份 1,408 行目录与导航每帧重建。相机逐帧状态同理独立发布。

## VideoToolbox + Network.framework：「一起跳」

- `VTCompressionSession` / `VTDecompressionSession` 做 H.264 硬件编解码，分辨率 640 或 960 宽
- 自定义二进制视频包（formatVersion 1）：timestamp、宽高、keyframe 标志、parameter sets，大端编码，`maxFrameLength` 8 MB
- `NWListener` / `NWConnection` / `NWBrowser`：Bonjour 服务类型 `_hidanclub._tcp`，TLS 1.2 预共享密钥由 4 位房间码派生
- NTP 式 ping/pong 采样估计时钟偏移；八拍网格 `beatsPerBar = 8`，条边界 `anchor + k × barLength`
- 协议层 `PartyProtocol.swift` 在 HidanCore（Foundation-only），传输、相机与编解码在应用 target——协议可脱离 UI 单测

## 音频：AVAudioEngine

原创八拍由 `AVAudioEngine` + `PlayerNode` + `TimePitch` 合成与变速；导入音乐保存原字节。BPM 估计用频谱通量，只分析开头最多 4 分钟。视频播放器和音频播放器**没有承诺共同时间基下的精准同步**——这是明确的工程边界而非缺陷掩盖。

## 一个真实的工程修复

本机 SwiftUI `VideoPlayer` 在 AVKit SwiftUI 元数据初始化时触发 **SIGABRT**；修复方式是改为窄范围 `NSViewRepresentable` 包装系统 `AVPlayerView`，沿用现有播放器和播放控制。替换后视频库原生启动、导航及预览流程通过。

## 构建体系

- SwiftPM `Package.swift`，Swift 6 工具链、Swift 5 语言模式，部署目标 macOS 14
- `script/build_and_run.sh` 打包 `dist/HidanClub.app` + ad-hoc 签名 + 图标接入
- QA 体系：Swift 行为探针（`script/qa_*_probe.swift`）由 shell 脚本编译运行，用环境变量（`HIDAN_DATA_DIR` 等）隔离数据目录，不触碰用户真实库
- 离屏渲染探针生成 PNG 到 `output/`，用于无窗口环境的 UI 回归

> **验证哲学**：探针使用合成数据验证软件合同（字节一致、状态机、并发），**不冒充**真实舞者检测精度或听感验证；离屏渲染图中系统控件是占位色，不当作真实窗口外观。
