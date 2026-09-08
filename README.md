# Hidan Club

基于 SwiftUI 的本地街舞学习原型：先建立练习习惯，再用可追查的视频观测研究动作。

## 运行

要求 macOS 14+ 与 Swift 6 工具链（源码采用 Swift 5 语言模式）。不依赖第三方包、云端密钥或下载模型。

```bash
./script/build_and_run.sh
./script/test.sh
./script/test_media.sh
./script/qa_store.sh
```

Codex 的 Run 按钮已连接到同一脚本。构建结果：`dist/HidanClub.app`。测试脚本在缺少 XCTest 的 Command Line Tools 环境运行可复现行为探针；具备 XCTest 时也会运行 `swift test`，其他测试失败不会被忽略。

## 已实现

- 16 个原创基础练习卡：Hip-Hop、Popping、Locking、House。
- 10–45 分钟规则训练计划：热身、分解、休息、组合、放松；暂停、下一段、结束与真实历史。
- 原创八拍节拍、本地音频、速度/音量控制。
- 本地视频播放、镜像、慢放、A–B 循环。
- Apple Vision 全帧 2D 人体关键点分析、原始 PTS 保留、骨架逐帧复查与 JSON 导出。
- 四组八拍动作规则组合、研究资源入口。

未包含授权教学视频；文字卡待教师审核。未实现自动舞步分类、舞蹈评分、自由生成三维编舞、摄像头实时录制或 MusicKit。

## 文档

- [产品与技术方案](docs/PRODUCT_AND_TECHNICAL_PLAN.md)
- [动作资源、数据库与授权调研](docs/research/dance-resources.md)
- [Apple / AI / 音乐技术调研](docs/research/apple-motion.md)
- [机器可读资源索引](docs/research/dance-resources.json)
- [验证记录与限制](docs/VERIFICATION.md)
- [Logo 设计与图标资源](docs/BRAND.md)

## 数据

历史默认位于 `~/Library/Application Support/HidanClub/history.json`；可通过 `HIDAN_DATA_DIR` 指定隔离测试目录。损坏记录不会被覆盖。导入媒体仅在当前会话使用本地引用，视频分析不上传；完整姿态导出由用户选择位置。正常退出会结束并保存当前练习；运行中的练习不做跨启动恢复，强制结束或崩溃后的恢复尚未实现。

SwiftUI 应用与 Foundation-only `HidanCore` 分离。当前只验证 macOS，iOS / iPadOS 是后续目标。
