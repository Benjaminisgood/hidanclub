# Hidan Club

基于 SwiftUI 的本地街舞学习应用：在训练台对照动作示范并录制自己的练习，在视频库保存原视频、识别二维身体动作，整理成动作或编排后跟练。

## 运行

要求 macOS 14+ 与 Swift 6 工具链（源码采用 Swift 5 语言模式）。应用运行不依赖第三方包、云端密钥或下载模型；AIST++ 数据安装与独立校验使用 Python 3.10+、NumPy 2.x 和 curl。

```bash
./script/build_and_run.sh
./script/test.sh
./script/test_media.sh
./script/qa_store.sh
# 安装 AIST++ 数据后：
./script/test_aist.sh
./script/qa_aist_store.sh
./script/qa_aist_appearance.sh
./script/qa_training_stage.sh
./script/qa_training_overlay.sh
./script/test_live_pose.sh
./script/test_camera_recording.sh
./script/qa_video_library.sh
./script/qa_pose_arrangement.sh
./script/qa_video_motion_library.sh
./script/qa_music_library.sh
./script/qa_library_import.sh        # 需要一份真实导出的动作模型 JSON
./script/qa_library_import_ui.sh     # 同上，另存离屏渲染 PNG 到 output/qa-library-import
```

Codex 的 Run 按钮已连接到同一脚本。构建结果：`dist/HidanClub.app`。测试脚本在缺少 XCTest 的 Command Line Tools 环境运行可复现行为探针；具备 XCTest 时也会运行 `swift test`，其他测试失败不会被忽略。

## 已实现

- 统一「动作库」入口：「3D 示范」用于观察和片段跟练；「基本功」提供 16 张原创文字卡；「我的动作」保存从视频中导入的二维动作片段。文字卡与 AIST 片段尚未逐条对应。
- 动作库支持从 JSON 文件导入：接受完整的二维动作模型导出（`*.hidanclub.json`）或裸识别报告。导入只读取原文件，保存独立副本，保留全部原始帧、置信度与原始 PTS；动作库使用文件自带的片段范围。编排库只排动作库里的三维片段。
- 训练台内嵌真实 AIST++ 示范：四种训练风格各 3 个真实命名动作，10–45 分钟计划每个练习段有对应模型，开始／暂停／换段联动。热身和休息显示下一动作预告。
- 实时摄像头跟练：本机 Vision 二维关节捕捉、入镜指导、可见关节与肘膝投影角度；并排、仅示范、仅摄像头、透明叠加四种显示方式。
- 左侧「音乐库」放两类东西：多套原创八拍（各自记住一个速度），以及导入后永久保存的本地音乐。两种播放器样式不同。音乐在本机估计一个整体 BPM，可手改；动作按 ¼×、½×、1×、2× 跟随，不改音乐本身。估计没有第一拍，短于约 8 秒或没有稳定周期时需要手填 BPM。视频动作仍按原片时间播放。
- 视频库：多选导入并原字节保存视频，训练台可手动录像并自动入库，重启后继续回放。录像为当前相机尺寸的画面，不录音、不叠加示范或骨架。
- 本机 Vision 肢体识别后，可依据全帧动作变化生成分段建议；显式应用后调整 A–B、顺序和重复次数，再导入动作库。没有重新生成舞步或过渡动画。
- 原视频播放、镜像、慢放、A–B 循环保留，用于核对捕捉结果。
- Apple Vision 全帧 2D 人体关键点分析、原始 PTS 保留、骨架逐帧复查与 JSON 导出。
- 四组八拍动作规则组合、研究资源入口。
- AIST++ 完整 3D 动作库、100 个官方基础动作名、全帧循环与片段训练。
- 柔光人形、霓虹人形与经典骨架，支持样式切换和骨架叠加；原关节数据与时间轴不变。

未包含授权教学视频；文字卡待教师审核。未实现自动舞步分类、舞蹈评分、自由生成三维编舞或 MusicKit。

## AIST++ 动作数据接入

本机已下载并无损转换官方完整 3D 标注：**1,408 条序列、1,123,873 个独立时间帧、10 个舞种**。原始与官方优化两种坐标均以 Float64 保留，维持精确 60 FPS、全部帧、源帧顺序和缺失值。100 个基础动作名称另由 AIST 官方元数据提供，保留原文与出处；它们不是本应用 AI 的识别结果。

已实现 3D 动作库、动作名/舞种检索、收藏、逐帧查看、A–B 与八拍区间、连续片段导出，以及将选定片段加入训练计划。数据全量校验、异步状态与训练行为探针、0.2 应用包构建/启动/签名和原生界面检查均已通过，范围与限制见[验证记录](docs/VERIFICATION.md)。

官网的 10,108,015 统计多机位图像，不能当作独立三维时间帧。对应图像需从原 AIST 视频获取，视频、音乐及其使用条款独立于 Google 的 CC BY 4.0 标注。本轮没有下载或打包这些原媒体，也没有按官方 FPS 转换示例重采样视频。

数据默认存于 `~/Library/Application Support/HidanClub/Datasets/AISTPlusPlus/`，不进入 Git 或 `.app`。新机器可运行：

```bash
python3 script/aist_dataset.py
python3 script/aist_dataset.py --verify-only
```

安装、外置目录、来源哈希与数据合同见 [AIST++ 接入说明](docs/AIST_DATASET.md)。

## 文档

- [产品与技术方案](docs/PRODUCT_AND_TECHNICAL_PLAN.md)
- [动作资源、数据库与授权调研](docs/research/dance-resources.md)
- [Apple / AI / 音乐技术调研](docs/research/apple-motion.md)
- [机器可读资源索引](docs/research/dance-resources.json)
- [AIST++ 下载、全帧数据合同与校验](docs/AIST_DATASET.md)
- [AIST++ 图像计数、媒体与动作元数据核查](docs/research/aist-images-and-counts.md)
- [3D 人形与骨架样式](docs/AIST_APPEARANCE.md)
- [实时训练台](docs/TRAINING_STUDIO.md)
- [验证记录与限制](docs/VERIFICATION.md)
- [Logo 设计与图标资源](docs/BRAND.md)

## 数据

数据位于 `~/Library/Application Support/HidanClub/`：`Videos/` 保存原视频和视频条目，`CapturedMotions/` 保存完整二维识别模型，`VideoMotionLibrary/` 保存导入动作库/编排库的独立副本（含从 JSON 文件导入的副本），`Music/` 保存导入音乐的原字节、估计节拍和手动 BPM，`PendingRecordings/` 保留录像原件。相应隔离变量为 `HIDAN_VIDEO_DIR`、`HIDAN_CAPTURE_DIR`、`HIDAN_PUBLISHED_DIR`、`HIDAN_MUSIC_DIR`。所有分析在本机进行，完整原始帧和时间戳保留；损坏记录不静默覆盖。

历史位于 `history.json`，可用 `HIDAN_DATA_DIR` 隔离。正常退出会等待录像完成和入库，再保存当前练习；强制结束或崩溃不保证录像完成，运行中的练习也不跨启动恢复。

SwiftUI 应用与 Foundation-only `HidanCore` 分离。当前只验证 macOS，iOS / iPadOS 是后续目标。
