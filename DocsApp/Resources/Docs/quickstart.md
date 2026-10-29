# 构建与运行

Hidan Club 使用 SwiftPM 构建，脚本完成打包、签名与启动。本文覆盖环境要求、构建命令、测试脚本与打包验证。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更高（验证环境：Apple Silicon Mac、macOS 26） |
| 工具链 | Swift 6 工具链（源码为 Swift 5 语言模式；验证使用 Swift 6.3.3） |
| 第三方包 | 无——全部使用系统框架，无依赖下载 |
| AIST++ 数据安装 | Python 3.10+、NumPy 2.x、curl（仅安装与验收阶段使用，应用运行不需要） |

## 一键构建并运行

```bash
./script/build_and_run.sh
```

- 构建结果输出到 `dist/HidanClub.app`，并完成本地 ad-hoc 签名
- Codex 的 Run 按钮已连接到同一脚本（`.codex/environments/environment.toml`）
- 构建脚本将 `AppIcon.icns` 拷贝到 `.app/Contents/Resources` 并设置 `CFBundleIconFile`

### 常用变体

```bash
./script/build_and_run.sh --build     # 只构建 .app，不启动
./script/build_and_run.sh --verify    # 打包、启动并执行严格 ad-hoc 签名校验
```

`--verify` 会执行等价于以下的检查：

```bash
codesign --verify --deep --strict dist/HidanClub.app
```

## 测试脚本

测试脚本在缺少 XCTest 的 Command Line Tools 环境运行**可复现行为探针**；具备 XCTest 时也会运行 `swift test`，其他测试失败不会被忽略。

### 基础套件（无需 AIST++ 数据）

```bash
./script/test.sh              # 核心行为探针，15,108 项检查
./script/test_media.sh        # 音乐与视频播放探针（需要音频输出设备，默认静音）
./script/qa_store.sh          # 训练历史持久化 QA
```

### AIST++ 套件（安装数据后）

```bash
./script/test_aist.sh               # 生产 Swift loader 读取两层全部 2,247,746 帧
./script/qa_aist_store.sh           # 动作名称映射、坐标层切换、训练计划预算
./script/qa_aist_appearance.sh      # 三种人形样式的真实帧渲染回归
```

### 功能 QA 套件

```bash
./script/qa_training_stage.sh       # 训练台状态机与多参考编排训练
./script/qa_training_overlay.sh     # SceneKit 透明叠加真实快照
./script/test_live_pose.sh          # 实时摄像头姿态探针（不开启真实相机）
./script/test_camera_recording.sh   # 录像生命周期探针
./script/qa_video_library.sh        # 视频库原字节一致性与恢复
./script/qa_pose_arrangement.sh     # 智能分段与编排行为
./script/qa_video_motion_library.sh # 动作/编排独立快照与发布队列
./script/qa_music_library.sh        # BPM 估计、原字节保存与重启恢复
./script/qa_library_import.sh       # JSON 导入（需要一份真实导出的动作模型 JSON）
./script/qa_library_import_ui.sh    # 同上，另存离屏渲染 PNG 到 output/qa-library-import
./script/qa_party.sh                # 「一起跳」回环连线：TLS-PSK、H.264 往返、节拍同步
./script/qa_party_ui.sh             # 「一起跳」页面离屏渲染 PNG 到 output/qa-party
```

完整脚本清单与逐条说明见[脚本参考](scripts)。

## AIST++ 数据安装

应用运行不依赖 Python，但首次接入 AIST++ 3D 动作库需要安装数据：

```bash
python3 script/aist_dataset.py                 # 下载、转换并全量校验
python3 script/aist_dataset.py --verify-only   # 只校验，不下载、不写文件
```

数据默认存于 `~/Library/Application Support/HidanClub/Datasets/AISTPlusPlus/`，不进入 Git 或 `.app`。也支持外置目录：

```bash
python3 script/aist_dataset.py --root '/Volumes/Research/AISTPlusPlus'
python3 script/aist_dataset.py --root '/Volumes/Research/AISTPlusPlus' --verify-only
```

下载约 876 MB（`keypoints3d.zip`），加上相机与划分元数据，请预留磁盘空间；脚本会先检查磁盘空间，下载用 `.partial` 支持续传。详见 [AIST++ 数据接入全解](aist-dataset)。

## 构建验证记录

| 检查 | 结果 |
| --- | --- |
| `swift build` | 成功，SwiftUI/AVFoundation/Vision 全部系统框架 |
| `build_and_run.sh --build` | 生成 `dist/HidanClub.app` 并 ad-hoc 签名 |
| Launch Services 启动 | 通过，读取到完整原生窗口和控件 |
| `codesign --verify --deep --strict` | 成功 |
| `git diff --check` 与 shell 语法检查 | 通过 |

> **注意**：本机 Command Line Tools 缺少 XCTest，直接 `swift test` 会报 `no such module 'XCTest'`。项目从不声称 XCTest 套件已通过；`test.sh` 仅对这一具体缺依赖启用独立验证，其他错误仍会失败。测试文件完整保留在 `Tests/` 目录。

## 平台现状

当前只在 macOS 验证构建与运行；iOS / iPadOS 是后续目标。`HidanCore` 为 Foundation-only、无 AppKit 依赖，可用于未来 iOS 移植；导入、相机权限、后台音频、屏幕方向与文件访问需另做平台适配。本应用为本地 ad-hoc 签名原型，**不是** App Store／公证发行版本。
