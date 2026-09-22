# AIST++ 全量标注、图像与训练元数据核查

核查时间：2026-09-09（Asia/Shanghai）。所有下列网页、API 源码与发布资产元数据均在本轮实际读取；视频仅检查 HTTP 响应头，未在本核查中下载、转码、再分发或提交 AIST 表单。完整 3D 标注的下载与逐文件统计由应用接入流程单独记录。

## 结论与当前接入范围

此前将原视频/音乐的限制扩大成“只能做可选标注适配器”，导致没有直接接入 Google 已发布的 CC BY 4.0 3D 标注，是实现过度保守。Google 标注可以立即下载并用于全帧动作资料库、逐帧骨架演示、舞种/舞者/编舞检索、时间段循环，以及后续动作表示研究。保存源文件、标明 Google LLC、AIST++、许可与转换内容即可开展这些工作。

原视频/音乐属于另一来源。它们的条款不会阻止上述标注接入，也不应成为应用功能停工的理由。原媒体的下载、应用内播放和产品分发分别按 AIST 条款处理。

## 10,108,015 的含义

- [首页](https://google.github.io/aistplusplus_dataset/index.html) 原文为 “10,108,015 frames of 3D keypoints with corresponding images.”
- [Description](https://google.github.io/aistplusplus_dataset/factsfigures.html) 明确解释为 10.1M **images** 的 3D 关键点与相机标注，覆盖 30 个 subjects 和 9 个 views。
- 同页 Table 1 的 Images 列为 6,420,059 + 508,234 + 3,179,722 = **10,108,015**；Sequences 列为 868 + 70 + 470 = **1,408**。
- [下载页](https://google.github.io/aistplusplus_dataset/download.html) 的三维文件是 `(N, 17, 3)`；二维多视图文件是 `(9, N, 17, 3)`。一个三维时刻对应多个相机图像，不能把这些视图重复当作不同的三维动作时刻。
- 不宜直接把首页总数除以 9 并四舍五入作为独立 3D 帧数。总数不能被 9 整除，且原库存在缺失视频与质量例外。应用展示的独立 3D 帧数应逐文件累计 `N`；原始与优化版本是同一组时间点的不同坐标表示，也不应相加成更多帧。

## 实际可下载资产

2026-09-09 [GitHub v1.0 release API](https://api.github.com/repos/google/aistplusplus_dataset/releases/tags/v1.0) 返回以下精确字节数。网页按钮的 MB/GB 文案有历史差异，下载校验应以实际资产和本地校验记录为准。

| 发布资产 | 实际字节数 | 用途 |
| --- | ---: | --- |
| `keypoints3d.zip` | 876,142,511 | COCO 17 点，逐帧原始与官方优化三维坐标 |
| `keypoints2d.zip` | 1,316,187,461 | 9 机位二维点、检测置信度、时间戳等 |
| `motions.zip` | 78,684,689 | SMPL 姿态与位移参数；不是 SMPL 人体模型文件 |
| `cameras.zip` | 27,294 | 相机内外参、环境与序列映射 |
| `splits.zip` | 16,454 | 不同研究目标的划分 |
| `ignore_list.txt` | 1,217 | 官方低质量序列列表 |

资产的公开地址为 `https://github.com/google/aistplusplus_dataset/releases/download/v1.0/<资产名>`。

`keypoints3d` 是逐帧重建；`keypoints3d_optim` 采用官方时间平滑和约束。界面可以切换这两个源版本，但应明确命名，不要自行增加平滑。`ignore_list.txt` 中的序列可保留供审阅，并标为官方低质量；将它们排除出默认训练参考不能等同于删除原数据或减少一条序列中的帧。

## “corresponding images” 如何获得

[官方 Download](https://google.github.io/aistplusplus_dataset/download.html) 没有提供独立全量静态图像 ZIP。流程是：

1. 从原 AIST Dance Video Database 下载带音乐的 MP4。
2. 将视频转换为图像。官方特别要求以 **exact 60 FPS** 对齐标注，而不是视频容器记录的略有差异的原始帧率。

官方下载器位于 [downloader.py](https://github.com/google/aistplusplus_api/blob/main/downloader.py)，其目标媒体前缀为 `https://aistdancedb.ongaaccel.jp/v1.0.0/video/10M/`，并从 `https://storage.googleapis.com/aist_plusplus_public/20121228/video_list.txt` 取得待下载列表。该列表 URL 本轮返回 **HTTP 403**，所以复制官方命令不保证现时可用。脚本中的媒体 URL 本身依然可访问：已对 `gPO_sBM_c01_d10_mPO0_ch01.mp4` 做 HEAD 检查，返回 HTTP 200、15,005,529 字节。

可维护的替代路径是用已验证的三维序列名将 `cAll` 替换为 `c01`…`c09`，再与 AIST 官方完整媒体清单核对。不得将 404 自动当作网络失败反复重试：[原 AIST 下载页](https://aistdancedb.ongaaccel.jp/database_download/) 明确列出两段原始缺失的机位文件：

- `gMH_sBM_c08_d23_mMH1_ch05.mp4`
- `gMH_sBM_c09_d22_mMH2_ch01.mp4`

原 AIST 提供 full metadata CSV、只含永久 URL 的 CSV、单文件永久链接，以及原始/整理后视频和 10 Mbps/2 Mbps 版本。Google 下载器选的是 10 Mbps 整理后视频。整理后视频截去 pre-roll/post-roll，并用干净原音乐替换现场录音；它与原始视频在时间起点上有区别，不能混用后仍假定逐帧对齐。

### 保留全部帧的对齐规则

[API utils.py](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/utils.py) 的 `ffmpeg_video_read` 和 `ffmpeg_video_to_images` 在指定 `fps` 后会执行 `fps` filter，`round='down'`。帧率变换可能丢弃或复制帧，不能原样套用到本项目的无降采样数据处理流程。

应保存原 MP4 和全部解码帧的原始 presentation timestamps。标注有独立的 60 Hz 时间轴 `t = frameIndex / 60`。媒体接入时建立两个完整时间轴之间的显示映射，并记录每个标注时刻对应的源视频时间/帧索引；任何源视频帧都应能单独查看。FPS/时长/起点不同须在对齐状态中明确显示，不能假定一帧一帧同号对应，不能以“优化性能”为由抽帧。若要严格复现实验论文的 60 FPS 图像构造，应另行说明这是官方时间重采样流程；本版不自动执行。

## 三维坐标、向上方向与单位

- API 的 [loader.py](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/loader.py) 原样加载 `(N,17,3)`，没有轴交换。
- [run_vis.py](https://github.com/google/aistplusplus_api/blob/main/demos/run_vis.py) 在 3D 模式直接将这些坐标交给原相机参数投影；没有 `(x,z,y)` 等变换。
- [run_estimate_camera.py](https://github.com/google/aistplusplus_api/blob/main/processing/run_estimate_camera.py) 初始化 c01 时使用绕 y 180° 与绕 z 180° 的旋转，合成 `diag(1,-1,-1)`，平移 `[0,180,500]`。这与正 Y 为上、相机画面 Y 朝下的世界/相机关系一致。
- [features/kinetic.py](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/features/kinetic.py) 明确默认 `frame_time=1./60, up_vec="y"`；[features/manual.py](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/features/manual.py) 也用 `y_unit` 与 `y_min` 表示竖直方向/地面。这些是采用 Y-up 的源码证据。
- 没有在数据格式说明中找到原 3D 关键点的确定物理单位声明。相机初始值与厘米量级一致，但最终估计有尺度自由度，不能据此向用户报告实测米/厘米、跳跃高度或实际速度。
- [extract_motion_feats.py](https://github.com/google/aistplusplus_api/blob/main/demos/extract_motion_feats.py) 使用 `smpl_trans / smpl_scaling`，注释明确这是归一化到通用 SMPL 模型尺度。因此不能把 SMPL 归一化坐标的单位推回原始 COCO 坐标。

实现上保留源坐标，默认 Y-up，仅在 renderer 中进行记录清楚的显示旋转、平移、缩放。单位显示为“数据集坐标单位”，身高归一化只作为独立显示或比较表示，不覆盖源数据。旋转视角不应改变左右肢体标记；镜像练习应单独切换并标注。

## 可立即使用的舞种、基础动作和音乐元数据

[AIST Data Formats](https://aistdancedb.ongaaccel.jp/data_formats/) 给出了可靠的序列名称语义：

| 代码 | 原始舞种名 | 应用可读名称 |
| --- | --- | --- |
| gBR | Break | Breaking |
| gPO | Pop | Popping |
| gLO | Lock | Locking |
| gMH | Middle Hip-hop | Middle Hip-Hop |
| gLH | LA style Hip-hop | LA Style Hip-Hop |
| gHO | House | House |
| gWA | Waack | Waacking |
| gKR | Krump | Krump |
| gJS | Street Jazz | Street Jazz |
| gJB | Ballet Jazz | Ballet Jazz |

`sBM` 表示 Basic Dance，`sFM` 表示 Advanced Dance。序列还直接携带 dancer、music、choreography 标识。舞种和基础/进阶拍摄类别是原库 metadata；不能把它们宣称为本应用 AI 的识别结果或教学难度评分。

官方还提供 [choreo.xlsx](https://aistdancedb.ongaaccel.jp/data/choreo.xlsx)。本轮只读解析确认，`Sheet1!A1:C101` 列为 `GENRE / CHOREOGRAPHY / NAME`，100 个基础动作，10 舞种各 10 个。可以按 `(genre, choreography)` 查找名称；**只用于 Basic Dance (`sBM`)**，不要把同一编号套用到不同拍摄类别。

| 原始键 | 原文名称 | 工作表位置 |
| --- | --- | --- |
| gBR / ch07 | 6 step | Sheet1!A8:C8 |
| gPO / ch01 | fresno | Sheet1!A12:C12 |
| gPO / ch04 | hand wave | Sheet1!A15:C15 |
| gPO / ch05 | body wave | Sheet1!A16:C16 |
| gMH / ch09 | running man | Sheet1!A40:C40 |
| gHO / ch01 | loose legs | Sheet1!A52:C52 |
| gHO / ch08 | shuffle | Sheet1!A59:C59 |
| gKR / ch01 | stomp | Sheet1!A72:C72 |

表内也存在疑似拼写错误，例如 `crap`、`broolklyn bounce`、`paddbre`。应保留 `sourceName`；任何规范化名称应另存 `displayAlias` 并注明为人工整理。动作名表来自原 AIST，不要把它标成 Google 的 CC BY 标注产物。

音乐 ID `mXX0`…`mXX5` 的 BPM 可由官方表精确映射：

- House：`mHO0`…`mHO5` → 110、115、120、125、130、135 BPM。
- 其余九类：后缀 0…5 → 80、90、100、110、120、130 BPM。

这足以立即显示原音乐速度、提供原创节拍器的目标 BPM，并帮助分段训练。BPM 并不是精确 beat/downbeat 时间戳，也不提供音乐相位；不能仅凭 BPM 宣称节拍器与原视频已经同步。需要用完整音频、来源时间轴或人工明确的 first-beat offset 进行同步。原资料的 Basic 为 16 beats、Advanced 通常为 64 beats，可以作说明，实际循环边界仍需按该序列时间轴确认。

## 许可和外链入口

Google 在 [Description / Licenses](https://google.github.io/aistplusplus_dataset/factsfigures.html) 写明 annotations 由 Google LLC 以 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 发布。应保留署名、许可链接、论文信息与修改说明。`motions.zip` 提供的参数不能替代 SMPL 模型自身的下载与许可。

API 根 [LICENSE](https://github.com/google/aistplusplus_api/blob/main/LICENSE) 为 Apache-2.0；但 `aist_plusplus/features/kinetic.py`、`manual.py` 等移植自 fairmotion 的文件有独立 BSD 声明。若复制源码，应按具体文件保留声明；从格式文档独立实现数据读取/渲染无需打包这些 Python 特征实现。

[AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/) 要求使用前填写 [Application Form](https://forms.gle/9nVAxPFUhXNPrKQ5A)，允许机构、公司、个人的学术研究，非研究或商业用途须提前取得书面同意，并禁止未经授权分发内容。Google 官方 downloader 同样会交互询问是否接受这些条款。本轮没有代用户填写表单、同意条款、发送邮件或下载原媒体。

[原下载页](https://aistdancedb.ongaaccel.jp/database_download/) 明确允许分享视频永久 URL，若分享子集，应分享 URL 列表。应用可先提供“打开来源”和按序列/机位生成的永久链接，媒体许可和用户的本地研究使用流程独立于标注浏览。

Google 官方页面自带两个公开预览，2026-09-09 HEAD 均返回 HTTP 200：

- [带音乐的数据集概览](https://google.github.io/aistplusplus_dataset/images/dataset_example.mp4)，4,624,091 字节，来自 Description 页面。
- [首页合成预览](https://google.github.io/aistplusplus_dataset/images/combined.mp4)，2,491,574 字节，来自首页。

这些可以作为打开官方预览的外链。它们不是按序列一一对应的训练素材，也没有独立的重新打包许可声明；不应从预览剪出图片充当 1,408 条序列的对应帧。

## 对功能实现的直接建议

1. 全量 3D 资料库：1,408 条源序列、10 舞种筛选、原文件数量/实际 N 累计、质量标记、原始/官方优化切换。
2. 训练视图：Y-up 可旋转骨架、镜像、播放速度、逐帧前后步进、任意帧区间循环、源帧号与秒数同时显示。保留全部坐标，无抽帧缓存。
3. 名称与节拍：显示来源明确的舞种、基础类别、音乐 ID 与 BPM；动作名按原元数据映射，尚未整合原表时保留来源链接。
4. 学习记录：把引用序列 ID、原帧范围、播放速度和练习时长写入本地记录，使训练可以复现。
5. 下一阶段比较：先用全帧关节角度/归一化姿态比较观察练习视频与参考的差异；将置信度、遮挡、视角、时间对齐等限制显式处理。AIST++ 的舞种和序列标签不能自动产生经过教师验证的动作评分。
