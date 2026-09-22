# AIST++ 数据接入与验收

2026-09-09，已从官方 GitHub release 下载**完整 3D 关键点档案**，完成全档 CRC、官方 SHA-256 对照和每一个坐标的无损转换校验。应用直接读取本地 Float64 数据，不依赖 Python 运行时。

## 本机实际数据

数据目录：`~/Library/Application Support/HidanClub/Datasets/AISTPlusPlus/`。

| 项目 | 实测结果 |
| --- | ---: |
| 完整原始 `keypoints3d.zip` | 876,142,511 bytes |
| 独立 `cAll` 3D 序列 | 1,408 |
| 原始时间帧（逐序列累加 N） | 1,123,873 |
| 原始帧率 | 精确 60 FPS |
| 每帧骨架 | COCO 17 关节 × 3 坐标 |
| 原始 + 官方优化两层数据 | 917,080,368 bytes |
| 全序列总时长 | 18,731.2167 秒，约 5.203 小时 |
| 官方 ignore list 命中的序列 | 45，合计 45,849 帧，全部保留 |
| 原始层 NaN 坐标 | 83,721，原位保留 |
| 官方优化层 NaN / Inf | 0 / 0 |

官网首页的 **10,108,015** 是与 3D 标注对应的多视角图像统计。每个 `cAll` 序列对应最多九台相机的同一次动作，不能将九个视角当作九段独立 3D 动作。当前下载档案的 `N` 累加为 **1,123,873**；乘九为 10,114,857，与网页图像统计略有差异，当前未对所有原始视频逐一核对该差异，不能声称两者严格相等。这里没有删帧来凑网页数字。

| 官方代码 | 官方舞种名称 | 序列 | 原始帧 |
| --- | --- | ---: | ---: |
| gBR | Break | 141 | 111,766 |
| gHO | House | 141 | 96,262 |
| gJB | Ballet Jazz | 141 | 114,645 |
| gJS | Street Jazz | 141 | 115,110 |
| gKR | Krump | 141 | 114,180 |
| gLH | LA style Hip-hop | 141 | 116,072 |
| gLO | Lock | 141 | 113,832 |
| gMH | Middle Hip-hop | 141 | 115,961 |
| gPO | Pop | 140 | 112,296 |
| gWA | Waack | 140 | 113,749 |

舞种标签来自文件命名规范，不是应用新训练的动作分类结果。`chXX` 是来源编排编号；仅基础 `sBM` 序列通过官方 `choreo.xlsx` 的舞种加编排编号映射到 100 个基础动作原名，进阶 `sFM` 不套用这些名称。

## 来源、许可与证据边界

- [官方下载页](https://google.github.io/aistplusplus_dataset/download.html)：3D 两层字段、`(N,17,3)`、精确 60 FPS、`ignore_list.txt` 的用途。
- [官方描述页](https://google.github.io/aistplusplus_dataset/factsfigures.html)：多视角图像统计、用途、论文、数据划分和 **CC BY 4.0** 标注许可。
- [当前官方 v1.0 release](https://github.com/google/aistplusplus_dataset/releases/tag/v1.0)：原 Google Storage 地址失效后于 2026 年迁移至 GitHub assets；下载工具使用该官方地址。
- [官方 loader](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/loader.py) 与 [README](https://github.com/google/aistplusplus_api/blob/main/README.md)：数组结构及 COCO 关节顺序。
- [AIST 命名规范](https://aistdancedb.ongaaccel.jp/data_formats/)：舞种、舞者、音乐、编排编号。
- 视频、对应图像和音乐来自 [AIST Dance Video Database](https://aistdancedb.ongaaccel.jp/database_download/)，适用其独立 [Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)。它们**不在 `keypoints3d.zip` 里**，本适配脚本不下载视频、图像或音乐，也不将标注的 CC BY 4.0 自动套用到这些媒体上。

归属：AIST++ annotations © Google LLC, CC BY 4.0。Ruilong Li, Shan Yang, David A. Ross, Angjoo Kanazawa, *AI Choreographer: Music Conditioned 3D Dance Generation with AIST++*, ICCV 2021。来源表演数据库：Shuhei Tsuchida, Satoru Fukayama, Masahiro Hamasaki, Masataka Goto, *AIST Dance Video Database*, ISMIR 2019。

本项目所做修改仅为容器格式适配：NumPy Float64 → little-endian Float64 顺序二进制。`keypoints3d_optim` 是官方已经施加时间平滑和约束的结果，不能称作未经处理的测量值。本项目保留 `keypoints3d` 与 `keypoints3d_optim` 两层，不额外平滑、不降采样、不插值、不改变坐标数值或源帧顺序。`ignored` 保留来源低质量标识，界面完整列出并以警示图标标记，不静默删除；不得直接将这些低质量重建用于教师级评分。

骨架能直接支撑动作浏览、旋转视角、逐帧观察和分段跟练。单凭这些数据仍不能证明自动舞步命名、动作教学正确性、危险动作安全性或评分有效性。源坐标保留原坐标系和尺度；显示时的平移、缩放、旋转应只发生在绘图变换中，不得覆盖源数据。

## 安装与独立复核

适配脚本：`script/aist_dataset.py`。需要 Python 3.10+、NumPy 2.x 和 curl，仅在安装与验收阶段使用。应用运行不需要这些依赖。

```sh
python3 script/aist_dataset.py
python3 script/aist_dataset.py --verify-only
```

也可指定外置目录：

```sh
python3 script/aist_dataset.py --root '/Volumes/Research/AISTPlusPlus'
python3 script/aist_dataset.py --root '/Volumes/Research/AISTPlusPlus' --verify-only
```

本轮执行使用 Codex 提供的 NumPy 2.3.5 Python 环境：

```sh
'/Users/ben/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3' script/aist_dataset.py --verify-only
```

脚本先检查磁盘空间；下载用 `.partial` 支持续传。官方 SHA-256 和字节数匹配后原子发布源文件；重跑验证已有源档，不静默覆盖不同数据。每个二进制文件原子写入，重新安装时相同内容复用，不同内容拒绝覆盖。`manifest.json` 最后发布，所以中断的首次安装不会伪装成完成。`--verify-only` 不下载、不写文件，会独立重新读取原档，并比较所有二进制字节和整个 manifest。

Pickle 读取用 `RestrictedNumpyUnpickler`，只允许 NumPy 数组及必要 dtype/reconstruction 对象，拒绝任意 Python globals 和 persistent IDs；而且只在整个源档哈希及 CRC 通过后读取。ZIP 路径穿越、重复路径和软链接均被拒绝。AppleDouble `__MACOSX` 元数据不是动作序列，完整保留在源 ZIP，并在验收报告列出。

## 文件结构和 Swift 数据合同

```text
AISTPlusPlus/
├── manifest.json
├── verification.json
├── source/
│   ├── keypoints3d.zip
│   ├── keypoints3d_members.json
│   ├── cameras.zip
│   ├── splits.zip
│   ├── ignore_list.txt
│   └── references/                 # 本轮官方网页、API、release元数据快照
├── metadata/
│   ├── cameras/                   # 相机参数、mapping.txt
│   └── splits/                    # 官方任务划分，不重新随机划分
└── sequences/
    ├── <id>.raw.f64
    └── <id>.optimized.f64
```

`manifest.json` 为 schemaVersion 1。顶层含 `fps`, `jointNamesCOCO`, `sourceURL`, `licenseURL`, `sourceSHA256`, `sequenceCount`, `totalFrames`, `ignoredSequenceCount`, `attribution`, `modifications`, `sequences`。每序列含 `id`, `genreCode`, `genreName`, `situationCode`, `dancerID`, `musicID`, `choreographyID`, `frameCount`, `fps`, `durationSeconds`, `rawPath`, `optimizedPath`, `ignored`, `byteCount`，以及两层 SHA-256、NaN/Inf 数量、源成员 CRC/SHA-256 和 `cameraEnvironment`。路径均相对数据目录。

两层 f64 文件均无文件头。维度为 `(N,17,3)`，顺序为 frame → joint → x/y/z，little-endian IEEE-754 64-bit。第 `frame` 帧第 `joint` 关节的第 `axis` 坐标起始字节：

```text
((frame * 17 + joint) * 3 + axis) * 8
```

`byteCount` 是**每一层**的字节数，等于 `frameCount * 17 * 3 * 8`，两层总字节为其两倍。Swift 用 `Double` 读取。NaN 不应导致整帧被删掉；绘图可以跳过不可用关节/连线并明确其缺失。COCO 关节顺序：nose, left_eye, right_eye, left_ear, right_ear, left_shoulder, right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip, left_knee, right_knee, left_ankle, right_ankle。

关键点源档官方 SHA-256：

```text
8b2a3bfcea233b8d1859a0dc93c7800a8f9e832136ef6828d0b3ddff640ddcfd
```

## 本轮数据验证

- 完整 1,408 序列原始层与官方优化层的所有帧、所有坐标转换后**逐字节相等**，包括 NaN 的位模式。
- 全源 ZIP CRC 校验通过，四份资产 SHA-256 均匹配官方 release 元数据。
- `--verify-only` 再次从原始 ZIP 独立重算并核对 manifest 和所有二进制数据。
- 定向防护验证通过：拒绝 `os.system` / `eval` 的 pickle globals；保留 IEEE-754 NaN、Inf 和负零；大端转换无损；拒绝覆盖不同已有文件；拒绝 ZIP `../` 路径。
- 原始 ZIP、官方网页/API 快照、来源分割清单、忽略清单、各序列哈希和汇总报告均留存。大体积数据存储在应用支持目录，不进入代码仓库或 `.app` 包。
