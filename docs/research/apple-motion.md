# Swift 街舞学习：Apple 动作分析与音乐技术调研

检索日期：2026-09-09。下列事实来自本次实际读取的 Apple 文档 JSON、WWDC 文字稿、Apple Developer Program License Agreement 和 Google / Apple 开源工具官方文档；工程方案与未验证的能力另行标明。

## 建议先做什么

以 **macOS 14+ 原生 SwiftUI 训练台** 为第一步；动作与课程数据模型可复用到 **iOS / iPadOS 17+**。第一版能可靠交付的是：导入有使用权的视频和非 DRM 音乐、视频慢放与片段循环、镜像练习、8 拍提示、训练/休息流程、训练记录，以及 **离线逐帧人体关键点提取**。分析结果应显示检测覆盖率、多人/缺失帧和骨架复查，不冒充舞步命名、动作质量分数或教学纠错。

舞蹈动作由时序、音乐关系、重心、身体控制与风格组成。骨架坐标只是观测层；动作类别模型、教师标注和评分标尺都需要额外建立，不能把 `confidence` 显示成“你跳得 92 分”。

## Apple 能力与限制

| 能力 | 本次核实的官方事实 | 产品影响 |
| --- | --- | --- |
| Vision 2D | `VNDetectHumanBodyPoseRequest` 从 iOS/iPadOS 14、macOS 11 可用；最多 19 个身体点；多人体可以返回多个 observation；坐标归一化为 0…1，原点左下；point confidence = 0 为无效点。[1] | 适合首版骨架叠加和数据采集。保存原始置信度，展示时明确缺失，不能将零置信点当真实关节。 |
| Vision 3D | `VNDetectHumanBodyPose3DRequest` 从 iOS/iPadOS 17、macOS 14 可用；17 个关节；目前只分析最显著的人；返回完整 17 点或没有结果；深度不是必要条件，但可改善准确度。[2] | 3D 是估计，不等于动作捕捉真值。不能用它自动解决多人跟踪、脚底接触、遮挡和地板动作。 |
| 3D 尺度 | 世界位置以根关节为参考、单位米。身高在缺少足够深度元数据时回退到 1.8 m 参考值，实测高度要求适当 LiDAR capture 配置。[2] | 不把普通视频推断结果当身高、位移或能量消耗的精密测量。模型中保存 height-estimation 来源。 |
| 2D 观测条件 | Apple 建议人物至少占画面高度约 1/3、大部分关键部位入镜。飘动/宽松衣物、密集人群会降低准确性。[1] | 街舞常见宽松衣物、转身遮挡、贴地支撑均属于需要真实舞者视频验证的场景。 |
| Create ML | `MLActionClassifier` 的训练接口从 macOS 11 可用。训练使用 Vision 每帧人体点，学习时间窗口内的运动模式，导出 Core ML 后在 app 推理。[3][4] | 训练在 Mac，应用端部署推理；它不自带 street dance 动作词库。 |

`Vision 2D 19 点`、WWDC20 示例提到的 action classifier 18 landmarks、`Vision 3D 17 点` 是不同接口/特征契约。实现必须使用模型实际要求的 `keypointsMultiArray()` 与模型 metadata，不能按“都是骨架”直接替换、补齐或静默重排。

## 动作识别的数据门槛

Apple 官方建议 **每一个动作至少收集 50 个示例视频**，人物单人、全身、光照充足、相机固定，并收集无关动作作为 **negative class**。[3][4] 这是开始训练的建议下限，不能理解为“50 条街舞视频即可达到教学准确度”。

建议先选 3–5 个有清晰定义、站立、单人、正面可见的基础任务。正式选择与命名由课程设计者确认。每条训练数据需有舞者匿名 ID、拍摄 session、视角、速度/BPM、左右方向、起止时间、动作标签与标注者。划分训练、验证和测试时按 **舞者与拍摄 session** 隔离，避免同一录像相邻片段进入训练和测试造成虚高指标。

必须单独采集等待、走入镜头、调整衣服、非目标动作、动作间过渡等负例。混淆矩阵、每类 precision/recall、拒识率，以及不同舞者/视角/衣物下表现是验证目标；泛化不佳时显示“无法判断”，不能强制选一个类别。

Create ML 的运行帧率应与训练配置匹配；预测窗口长度 = 帧率 × action duration（官方例子为 30 fps × 2 s = 60 帧）。[3] 本项目应保留输入的全部帧与原始时间戳。对不匹配帧率或 VFR 视频，不得为满足固定窗口模型偷偷抽帧、降采样或插入伪观测；先做完整提取，之后选择与原始速率匹配的模型、明确限制支持源格式，或研究使用时间戳的自定义时序模型。模型窗口可以重叠，但每帧原始记录仍必须保留。

WWDC20 曾提出将分类 confidence 用于质量反馈。[5] 这不能证明分类置信度具有教学评分效度：姿态分类 confidence 只表示模型对类别的支持程度，可能因衣物、取景或域偏移变化。教学评分需要教师标注、明确维度与独立验证，首版不使用这一捷径。

## 视频全帧处理与训练播放

离线分析路径建议如下：

1. `AVURLAsset` 异步加载视频轨道、duration、preferred transform；拒绝没有视频轨或无法读取的媒体。
2. `AVAssetReader` + 解码后的 `AVAssetReaderTrackOutput` 顺序读取全部 sample buffer。解码输出按 presentation order 返回；保存每个 `CMSampleBuffer` 的 presentation timestamp。[6]
3. 根据轨道旋转/镜像元数据设置图像 orientation。每帧执行 Vision 2D；零人保留空 joints，多人保留 ambiguous 标记并跳过该帧的单人骨架，不静默切换人物。
4. 只将解码后的视频帧顺序送入分析；不使用固定数量缩略图、每秒抽帧或 `AVAssetImageGenerator` 定时截帧替代。取消时停止任务，最终报告只在完整成功后发布。进度 UI 的刷新频率与实际数据处理频率分开。
5. 保存全部姿态帧；播放器展示时按时间查找，不将 UI 渲染频率误写为分析频率。

当前 Apple 文档已对将来平台标出 `copyNextSampleBuffer()` 向 `AVAssetReaderOutput.Provider.next()` 的迁移。macOS 14 基线仍需兼容的 reader API；后续 SDK 升级按 availability 接入新接口，而不改变全帧契约。[6]

播放与训练节奏分开设计：视频可用 `AVPlayer` 变速并配置音高算法；音乐类素材优先 `.spectral` 或单独评估 `AVAudioUnitTimePitch` 的听感。`AVAudioUnitTimePitch` 官方支持独立调整速度和音高。[7] `AVPlayerLooper` 支持指定 `CMTimeRange` 的循环，但模板 item 初始化后的修改不会自动同步到内部 replica；修改 A/B 点时应重新配置 looper 并验证边界。[8]

不要把 `Timer` 当音频时钟。需要紧密同步的自有/授权媒体使用一个 master media timebase；AVPlayer 的 `setRate(_:time:atHostTime:)` 可对齐外部 host time，但官方强调它不会替你预加载媒体。[9] 音频、倒数、节拍提示需从媒体时间与用户 BPM/首拍位置推导。无线耳机与不同设备的输出延迟仍要测试；不能宣称所有设备零延迟。

第一版可先提供用户输入 BPM、首拍偏移和 8 拍格；自动 beat tracking 单独研究与验证。BPM 本身不能确定 downbeat、swing 或 groove。

## 音乐：MusicKit 不是可任意处理的音源

MusicKit Swift 提供 Apple Music metadata、搜索、订阅能力检查和受控播放，需用户授权以及 `NSAppleMusicUsageDescription`。框架从 macOS 12 可用，但 **`ApplicationMusicPlayer` 的 macOS 支持从 14 才开始**。[10]

更关键的是 Apple Developer Program License Agreement **3.3.6(D) MusicKit**：[11]

> “You may not, and You may not permit Your end users to, download, upload, or modify any MusicKit Content and MusicKit Content cannot be synchronized with any other content, unless otherwise permitted by Apple in the Documentation;”

协议还要求用户主动开始播放并提供标准媒体控件，只能通过 MusicKit API/JS 按文档方式播放。故不能把 Apple Music 订阅曲目默认纳入解码 PCM、波形/beat 分析、变速混音、训练视频配乐同步、导出或模型训练流程。能搜索歌曲、拥有订阅或者歌曲已下载到用户设备，都不自动获得这些使用权。

训练播放器首选 **用户合法导入的非 DRM 本地文件**，以及明确允许应用内使用、变速/同步和相应分发用途的授权音乐。非 DRM 只是技术可读取，仍不等于拥有再分发/商业授权。MusicKit 如日后接入，作为另行审查的标准播放能力，不与训练中的同步音源混为一谈。

## 替代路线

**MediaPipe Pose Landmarker** 提供 iOS Swift/Objective-C 官方集成，使用 `MediaPipeTasksVision` CocoaPods；输出 33 个 normalized/world landmarks，可配置多姿态数量。[12] 它的 `world landmarks` 仍是模型估计，不是实测 mocap。iOS 集成文档不能证明原生 macOS SwiftPM 一行即可接入，若首版是 macOS，Vision 有更清晰的系统集成路径。

MediaPipe 官方明确：live stream mode 在模型忙碌时调用 `detectAsync`，**会忽略新输入帧**。[12] 因此它不能直接承担本项目的全帧存档分析；离线应在后台顺序调用 video mode，逐帧传入真实 timestamp 并记录全部结果。

如后期需要自定义时序识别、2D-to-3D lifting 或动作 embedding，可在 PyTorch 训练后用 Apple `coremltools` 转换部署。官方支持从 TorchScript / ExportedProgram 捕获图并转 Core ML，但可转换不代表所有算子、动态形状或设备性能都符合要求，必须对特定模型进行数值一致性和真机性能验证。参见 [PyTorch Conversion Workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)。

AI 设计动作第一步应是 **从已审核动作库组合训练序列**：根据先修技能、BPM 范围、左右平衡、重心/朝向衔接、负荷和休息约束生成候选，输出引用的动作 ID 和解释，允许教师/用户修改。自由生成 3D choreography、ground-contact 或重心物理约束不是 Vision 的能力，不作为首版已支持功能。

## 推荐的数据模型

| 对象 | 最小字段与契约 |
| --- | --- |
| `MoveDefinition` | 稳定 ID；名称及同义词；风格；版本；语言；先修动作；难度；建议 BPM 范围；左右/镜像语义；教师来源；教学提示；风险与替代动作。标签不由骨架直接推断。 |
| `ReferenceTake` | move ID；视频来源/许可/作者；原文件标识；时间范围；原始时间基；旋转/镜像；舞者匿名 ID；视角；BPM/首拍/拍数；教师标注状态。 |
| `PoseFrame` | 原始 PTS（最好同时保存 rational value/timescale）；2D/3D 模型/版本；坐标系；每点 x/y/(z)、confidence；人体数量；无检测/多人/有效等状态。完整序列保留，不插值覆盖原始值。 |
| `ActionSegment` | 起止时间；候选标签与概率；拒识状态；模型与训练集版本；输入窗口；人工更正；动作标签与质量指标明确分列。 |
| `TrainingPlan` | 热身、技术练习、组合、freestyle、放松；每段动作/音乐/时间；目标速度；组数与休息；用户可随时跳过/停止。 |
| `TrainingSession` | 实际开始结束、完成段落、用户主观难度/感受、练习用速度、记录权限、可选分析报告；不因全身镜头不可用而阻断训练。 |
| `MusicAsset` | 来源类型（local/licensed/MusicKit）；可处理权限；BPM/downbeat 的来源和置信度；本地资源引用或 catalog ID；许可说明。禁止把 MusicKit catalog ID 伪装成本地可分析音频 URL。 |

评分研究需要另建 `AssessmentRubric`：由老师定义角度/时间相位/动作顺序等可解释指标、允许的风格差异、目标人群、标注一致性和阈值验证。报告维度而不是未经验证的综合“舞感分”。

## 首版验收与后续研究门槛

- 导入普通、旋转、镜像、不同帧率/VFR 视频，核对解码帧数、时间戳顺序和导出条目数；无检测帧不能消失。
- 多人出现时显示不可判断；取消后不能发布部分报告；连续启动分析时旧任务不能覆盖新任务。
- 用教师有权提供的真实街舞短片检查宽松衣物、脚部、遮挡、转身/地板动作；软件编译通过不等于这些场景已经验证。
- 检查变速保调听感、A/B 循环边界、切换音源、结束/暂停/恢复、训练计时和休息流程。
- 动作命名、计数、节拍对齐和纠错均为后续受验证功能。没有教师标签或独立测试集时只交付数据提取与复查。

### 本次已执行的软件检查

`Sources/HidanClub/Services/PoseAnalyzer.swift` 已实现 macOS 14 基线的离线 Vision 2D 分析服务。独立 `swiftc -swift-version 5 -warnings-as-errors -typecheck` 通过，且单独运行真实 AVAssetWriter → AVAssetReader → Vision 流程：8 帧 VFR 测试片保留 8/8 帧与全部原始 PTS，无人帧保留为空 joints。JSON 编解码、8 种标准旋转/镜像映射、非标准旋转拒绝、取消、旧任务隔离和无效源错误均通过。

这次测试素材是程序生成的无人短片，验证的是媒体读写、任务状态与导出契约；**尚不能据此确认真实街舞的检测准确度或实际视频叠加视觉效果**。标准方向映射做了数学枚举检查，仍需在有人的横竖/镜像片段中复查显示。完整 app 构建和训练界面验收由主集成流程负责。

## 主要来源

1. [Detecting Human Body Poses in Images](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images)；本次同时读取 `VNDetectHumanBodyPoseRequest` 的 platform metadata。
2. [Identifying 3D human body poses in images](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images)；并交叉读取 [WWDC23: Explore 3D body pose and person segmentation in Vision](https://developer.apple.com/videos/play/wwdc2023/111241/) 及 request metadata。
3. [Creating an Action Classifier Model](https://developer.apple.com/documentation/createml/creating-an-action-classifier-model)。
4. [Gathering Training Videos for an Action Classifier](https://developer.apple.com/documentation/createml/gathering-training-videos-for-an-action-classifier)；另核实 `MLActionClassifier` macOS availability。
5. [WWDC20: Build an Action Classifier with Create ML](https://developer.apple.com/videos/play/wwdc2020/10043/)。
6. [AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader) 与 [`copyNextSampleBuffer()`](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/copynextsamplebuffer())。
7. [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch) 与 [AVPlayerItem.audioTimePitchAlgorithm](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiotimepitchalgorithm)。
8. [AVPlayerLooper time-range initializer](https://developer.apple.com/documentation/avfoundation/avplayerlooper/init(player:templateitem:timerange:))。
9. [AVPlayer.setRate(_:time:atHostTime:)](https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:))。
10. [MusicKit](https://developer.apple.com/documentation/musickit) 与 [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer)。
11. [Apple Developer Program License Agreement — 3.3.6(D)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)。
12. [Google MediaPipe Pose Landmarker — iOS](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker/ios)。
