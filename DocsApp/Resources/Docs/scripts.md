# 脚本参考

`script/` 目录包含构建、数据安装与 20 余个 QA 脚本。QA 脚本 = shell 包装 + Swift 行为探针（`qa_*_probe.swift`），全部使用隔离数据目录，不触碰用户真实库。

## 构建与运行

| 脚本 | 作用 |
| --- | --- |
| `build_and_run.sh` | 编译、打包 `dist/HidanClub.app`、ad-hoc 签名并启动 |
| `build_and_run.sh --build` | 只构建，不启动 |
| `build_and_run.sh --verify` | 打包、启动并执行严格签名校验 |
| `generate_app_icon.sh` | 从原始 Logo PNG 生成 16/32/128/256/512 pt 及 @2x 共十个标准图标表示；不改写原始 PNG |

## 数据安装

| 脚本 | 作用 |
| --- | --- |
| `aist_dataset.py` | 下载 AIST++ 官方完整 3D 标注、无损转换为 f64、全量校验 |
| `aist_dataset.py --verify-only` | 不下载、不写文件，独立重读原档核对 manifest 与所有二进制 |
| `aist_dataset.py --root <dir>` | 使用外置数据目录 |

需要 Python 3.10+、NumPy 2.x、curl；仅安装与验收阶段使用，应用运行不需要。

## 核心测试

| 脚本 | 覆盖 |
| --- | --- |
| `test.sh` | 核心行为探针 15,108 项：计划组合、计时状态机、输入边界；有 XCTest 时也运行 `swift test` |
| `test_media.sh` | 音乐与视频播放探针：播放、暂停位置、倍速运算（需音频输出设备，默认静音） |
| `test_aist.sh` | 生产 Swift loader 读取两层全部 2,247,746 帧、验证 2,816 个 SHA-256（需先安装数据） |
| `test_live_pose.sh` | 实时姿态：合成 VFR 缓冲、PTS、同帧发布、丢帧计数、权限拒绝路径（不开真实相机） |
| `test_camera_recording.sh` | 录像生命周期：启停、中断、写入失败、收尾先于退出回调、完成标记 |

## QA 套件

| 脚本 | 覆盖 |
| --- | --- |
| `qa_store.sh` | 训练历史持久化：实际时长、UUID 去重、损坏保护、写失败恢复 |
| `qa_aist_store.sh` | 动作名称映射、快速切序列、坐标层切换、8 拍范围、训练计划预算 |
| `qa_aist_appearance.sh` | 三种人形样式：三舞种首/中/末帧、17 节点/19 连线、网格、NaN 隐藏恢复 |
| `qa_aist_arrangements.sh` | AIST 编排草稿：UUID 持久化、排序、重复片段、原始引用/哈希 |
| `qa_training_stage.sh` | 训练台状态机：四风格、开始/暂停/续练/跳段/结束、异步加载取消、快速换段 |
| `qa_training_overlay.sh` | SceneKit 透明叠加真实 snapshot：三样式透明背景、照明、相机稳定 |
| `qa_video_library.sh` | 视频库：原片字节一致、重启恢复、并发导入、VFR、symlink 拒绝 |
| `qa_pose_arrangement.sh` | 智能分段：停顿附近建议、保守行为、显式应用、旧 JSON 兼容 |
| `qa_video_motion_library.sh` | 动作/编排独立快照、来源身份、编辑保存、发布队列 |
| `qa_captured_motion.sh` | 完整模型：VFR 8/8 解码、Double 位精度、导出、2 万帧并发保存 |
| `qa_music_library.sh` | 音乐库：BPM 估计（120/86）、原字节一致、手动 BPM、重启选择、损坏保护 |
| `qa_library_import.sh` | JSON 导入合同：真实导出逐位相等、拒绝矩阵、混合批次（需一份真实导出的 `*.hidanclub.json`） |
| `qa_library_import_ui.sh` | 同上 + 离屏渲染 PNG 到 `output/qa-library-import/` |
| `qa_party.sh` | 「一起跳」回环连线：TLS-PSK 握手、H.264 往返、节拍同步 |
| `qa_party_ui.sh` | 「一起跳」页面离屏渲染 PNG 到 `output/qa-party/` |

## 运行顺序建议

全新环境（未装 AIST++ 数据）：

```bash
./script/build_and_run.sh --verify
./script/test.sh
./script/test_media.sh
./script/qa_store.sh
./script/qa_video_library.sh
./script/qa_music_library.sh
./script/qa_party.sh
```

安装数据后追加：

```bash
python3 script/aist_dataset.py
./script/test_aist.sh
./script/qa_aist_store.sh
./script/qa_aist_appearance.sh
./script/qa_training_stage.sh
./script/qa_training_overlay.sh
```

## 输出位置

| 路径 | 内容 |
| --- | --- |
| `dist/HidanClub.app` | 构建产物 |
| `output/qa-state/` | UI 自动化测试数据 |
| `output/qa-library-import/` | 导入界面离屏渲染 PNG |
| `output/qa-party/` | 「一起跳」页面离屏渲染 PNG |
| `output/qa-video-library/` | 视频库 QA 隔离数据 |

> **约定**：QA 脚本失败不会被忽略；探针「通过」指软件合同验证，不构成真实硬件录制、舞蹈质量评分或三维动作生成的验证。
