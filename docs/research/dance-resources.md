# 街舞学习应用：可用资源与授权核查

核查日期：2026-09-09。范围为 10 个高价值资源组，读取官方项目页、作者仓库、许可文件及论文摘要。本轮已下载完整 AIST++ 3D 标注与相机、划分、质量清单，完成源归档与全坐标无损校验；未下载原视频、音乐或模型权重。结构化索引见同目录 `dance-resources.json`。下文的“可以”均限定在明确列出的资产与许可范围，未把仓库开源许可扩展到训练数据、音乐或第三方人体模型。

## 第一版选择

当前使用**原创动作说明、AIST++ 全帧 3D 参考、本地关节轨迹与原创节拍音频**，建立可追查来源的动作库。教练授权/用户自录视频可继续补充真实示范；第三方课程保留外链。识别研究需先验证指定动作中的时序与姿态比较，不能把已有舞种标签或骨架观测当成经过验证的教学评分。

AIST++ 已成为本地动作参考库：**1,408 条三维序列、1,123,873 个独立时间帧、10 舞种，原始与官方优化两层均完整保留为 Float64。** Google 标注为 CC BY 4.0；API 根许可为 Apache-2.0，部分移植的特征代码有 BSD 声明；原 AIST 视频和音乐遵循独立研究用途条款。此前停留在“可选适配器”而未下载标注过于保守，原媒体限制不妨碍直接使用这份标注。

FineDance、AMASS 及 HumanML3D 的 AMASS 衍生动作层不适合作为默认商业素材库。EDGE 可以研究实现思路，但公开的 MIT 代码不能单独证明预训练权重和音乐全部可商用。BEAT/BEAT2 的任务是伴随语音的手势，与街舞教学的目标不同。

| 资源 | 核心用途 | 已核实的许可边界 | 第一版决定 |
| --- | --- | --- | --- |
| AIST Dance DB | 多舞种、多机位真实街舞视频/音乐 | 学术研究；商业须事先书面同意；禁止未授权分发 | 外链/申请授权，不内置素材 |
| AIST++ | 2D/3D 姿态、舞蹈与音乐关系研究 | 标注 CC BY 4.0；代码按文件许可；原媒体许可独立 | 完整 3D 标注已下载并校验，接入全帧动作参考库 |
| FineDance | 手指精细动作、舞种条件生成 | data/model/software 非商业；商业训练和第三方分发受限 | 研究参考，排除发行包 |
| BEAT / BEAT2 | co-speech gesture、身体/脸/手表达 | HF 卡为 Apache-2.0；旧项目页为 non-commercial，范围待澄清；SMPLX 等独立 | 不作为街舞核心数据 |
| AMASS | 通用人体运动与动作先验 | 非商业；明确禁止商业训练；不可直接第三方分发 | 不作为默认商用数据 |
| HumanML3D | 文字到动作、动作语义检索 | 仓库代码 MIT；动作来源 AMASS 等，不能据 MIT 重新分发源动作 | 研究语义结构，商用需逐源核查 |
| EDGE | 音乐驱动生成、局部编辑/衔接 | 代码 MIT；独立权重许可未核实；训练媒体另有许可 | 后续实验，不接入默认运行链 |
| SMPL Model / Body | 参数人体模型、骨架/网格显示 | Model 非商业；Body 子集 CC BY 4.0，二者不同 | 第一版自有骨架；3D 资产逐项核查 |
| STEEZY | 课程与训练工具的产品参考 | 个人非商业；禁止抓取及未经许可复制/分发 | 外链、功能参考、寻求合作 |
| Red Bull Dance | 舞种文化、基础知识、访谈/教学外链 | 本次请求 403，内容与复用授权未核实 | 待人工核验的外链候选 |

## 1. AIST Dance Video Database

- 官方介绍：[AIST Dance DB](https://aistdancedb.ongaaccel.jp/)。10 个主要舞种、40 位职业舞者、最多 9 台相机；包含独舞/群舞以及原创舞曲。页面称音乐为 “copyright-cleared dance music”，**此措辞不代表向应用开发者授予自由商用权**。
- 条款：[Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)。直接证据：
  > “AIST Dance DB may not be used for any purpose other than academic research.”
  > “Use for commercial purposes is not permitted without prior written consent from AIST.”
  > “Unauthorized redistribution of any content of the database is prohibited.”
- 使用前需填写 Application Form；商业或非研究用途应联系页面给出的 `aistdancedb-ml@aist.go.jp`。本次没有提交表单或发送邮件。
- 适用：舞种分类、跨机位姿态验证、音乐动作对齐研究。限制：其标签以舞种/场景为主，不能直接等同于面向初学者的“Running Man 第 3 拍错在哪里”教学标签，也没有证明某位舞者的表达是唯一正确标准。
- [原下载页](https://aistdancedb.ongaaccel.jp/database_download/) 提供单视频永久链接及批量 URL/metadata 清单，并允许分享永久 URL。对应静态图像需要由原视频解码；没有与 `keypoints3d.zip` 一并打包的图像。原视频/音乐本轮未下载，访问路径和许可流程保留，详见 [图像与计数核查](aist-images-and-counts.md)。
- 官方 [choreo.xlsx](https://aistdancedb.ongaaccel.jp/data/choreo.xlsx) 的 100 个基础动作短名已整理为应用检索元数据，保留原文和来源，仅按 `sBM + genre + choreography` 匹配。它们来自原 AIST 元数据，不宣称由 Google CC BY 标注或本应用 AI 生成。

## 2. AIST++

- [官方说明与标注许可](https://google.github.io/aistplusplus_dataset/factsfigures.html)、[下载/格式](https://google.github.io/aistplusplus_dataset/download.html)、[API 仓库](https://github.com/google/aistplusplus_api)。官网列出 1,408 段舞蹈、10 个舞种、30 名主体、9 机位和 **10,108,015 个多机位图像**的关节点标注；动作长度 7.4–48.0 秒。本机逐文件累加为 **1,123,873 个独立三维时间帧**，不能将图像数或原始/优化两个版本重复算成更多动作帧。
- 直接许可证据：
  > “The annotations are licensed by Google LLC under CC BY 4.0 license.”
- [CC BY 4.0 官方摘要](https://creativecommons.org/licenses/by/4.0/) 明确允许为商业目的分享和改编，要求署名、许可链接、标示修改，且不能添加限制他人行使许可权利的措施。其提示其他权利仍可能适用。**标注的许可不自动覆盖真人肖像、源音乐或人体模型工具。**
- [API LICENSE](https://raw.githubusercontent.com/google/aistplusplus_api/main/LICENSE) 为 Apache License 2.0；移植自 fairmotion 的 `features/kinetic.py`、`manual.py` 等另有 BSD 声明。代码和标注是不同许可对象。
- 格式：`keypoints2d` 为 `(9, N, 17, 3)`，末维 `x,y,confidence`；`keypoints3d` 为 `(N,17,3)`；`smpl_poses` 为 `(N,24,3)`，另有 root translation。标注严格 60 FPS；原视频 FPS 可能略有不同。数据页提供不良重建 `ignore_list.txt`，应记录排除原因，不能让低质量数据进入评分标准。
- 学习价值：COCO 17 点直接支撑骨架显示，无需引入 SMPL 形体模型。显示旋转/平移/缩放与原坐标分开；官方源码支持 Y-up，但不宜把未确认物理单位的源坐标标成实测米/厘米。评价姿态要按舞者切分；评价生成要避免音乐/编舞跨训练测试集泄漏，官方给出了这两类 split。
- 已下载官方 `keypoints3d.zip`（876,142,511 字节）及 cameras、splits、ignore list。原始与官方优化两层合计 917,080,368 字节，45 条官方低质量序列及原始 NaN 坐标全部保留。SHA-256、归档 CRC 与全部坐标逐字节校验通过，数据存于应用支持目录，未塞入 Git 或 `.app`。具体证据见 [AIST++ 接入与验收](../AIST_DATASET.md)。2D 和 SMPL motion 归档未在本轮下载。
- 本轮应用接入围绕检索/收藏、逐帧查看、A–B/八拍区间、连续片段导出及训练计划导入展开。数据验收与 UI 验收分别记录；界面构建和实际操作结果见 [VERIFICATION.md](../VERIFICATION.md)，不由数据校验代替。
- 官方从视频构造标注图像时使用 exact 60 FPS，API 的 FFmpeg `fps` filter 会重采样。后续媒体接入应保存原视频全部帧/PTS，并以独立 60 Hz 标注时间轴建立映射，不自动抽帧、插值或转码凑齐帧数。官方旧视频列表 URL 本轮返回 HTTP 403，单视频永久 URL 仍可访问；详见 [图像与计数核查](aist-images-and-counts.md)。

## 3. FineDance

- [ICCV 2023 正式摘要](https://openaccess.thecvf.com/content/ICCV2023/html/Li_FineDance_A_Fine-grained_Choreography_Dataset_for_3D_Full_Body_Dance_ICCV_2023_paper.html)：“14.6 hours of music-dance paired data”，22 个舞种，包含精细手部动作。不要将论文总规模写成当前可获取总规模。
- [当前仓库 README](https://github.com/li-ronghui/FineDance) 直接写：
  > “The part(7.7 hours) of FineDance dataset can be downloaded …”
- 发布部分提供 `label_json`（曲名/粗分类/细舞种）、SMPLH motion、WAV 音乐、音乐特征；有按舞种和按舞者切分。手部和细舞种更适合研究 Popping/Locking 等需要细节的表达，但仍不能替代教练标注的正确/错误样本。
- [LICENSE](https://raw.githubusercontent.com/li-ronghui/FineDance/main/LICENSE) 明确覆盖 “FineDance data, model and software”：
  > “To use the Data & Software for the sole purpose of performing non-commercial scientific research, non-commercial education, or non-commercial artistic projects;”
  > “The Data & Software may not be reproduced, modified and/or made available in any form to any third party without Xiu Li’s prior written permission.”
- 同一许可还禁止面向商业用途的模型训练与分发。因此代码、预训练权重、动作、视频、音乐不能因有公开下载链接就放入产品。项目网页模板页脚的 CC BY-SA 不可替代这一数据/软件许可。

## 4. BEAT / BEAT2（PantoMatrix / EMAGE）

- [BEAT 官方项目](https://pantomatrix.github.io/BEAT/) 的研究对象是 conversational gestures，列出 76 小时 3D motion，配套语音、文字、情绪、语义相关性、52 维面部 blendshape。这里的 “beat gestures” 是语音手势术语，不能理解为“踩音乐节拍的舞蹈动作”。
- [PantoMatrix 仓库](https://github.com/PantoMatrix/PantoMatrix) 将 BEAT 标作 BVH + ARKit，BEAT2 标作 SMPLX + FLAME，并链接模型权重及独立 SMPLX 资产。[EMAGE 项目](https://pantomatrix.github.io/EMAGE/) 研究 holistic co-speech gesture generation。
- 当前作者链接的数据卡：[BEAT](https://huggingface.co/datasets/H-Liu1997/BEAT/raw/main/README.md)、[BEAT2](https://huggingface.co/datasets/H-Liu1997/BEAT2/raw/main/README.md) 均只含 `license: apache-2.0`。另一方面 BEAT 项目页末写 “Licensed under the Non-commercial license.”，未清晰说明该页脚只适用于网站还是包括数据。本次仓库根目录未发现 LICENSE 文件。
- 决定：**授权信号存在范围歧义，尚不能给出整体商用/分发已获授权结论**；不同数据代际、模型、真人语音、SMPLX/FLAME 文件要分别核实。不要用 Apache 元数据覆盖其他权利。
- 适用：未来虚拟教练说话、表情/手势同步。第一版不投入此方向，也不训练其作为街舞动作分类器。

## 5. AMASS

- [官方许可](https://amass.is.tue.mpg.de/license.html) 标題为 “Dataset Copyright License for non-commercial scientific research purposes”。其商业限制明确包括模型训练：
  > “This license also prohibits the use of the Dataset to train methods/algorithms/neural networks/etc. for commercial use of any kind.”
  > “The Dataset may not be reproduced, modified and/or made available in any form to any third party without Max-Planck’s prior written permission.”
- 适用：通用人体运动先验、动作编码/重建研究；不是现成街舞课程库。商业许可询问入口为页面提供的 `ps-license@tue.mpg.de`，未代用户联系。
- 第一版不下载、不内置、不默认用其训练将用于产品的模型。若日后取得许可，仍需记录涉及的各原始运动捕捉库和人体模型权利。

## 6. HumanML3D

- [官方仓库](https://github.com/EricGuo5513/HumanML3D)：由 HumanAct12 与 AMASS 动作构建；14,616 段 motion、44,970 条描述、28.59 小时，总体覆盖生活/运动/杂技/舞蹈。平均动作 7.1 秒。
- [仓库 LICENSE](https://raw.githubusercontent.com/EricGuo5513/HumanML3D/main/LICENSE) 为 MIT **软件许可**。README 直接写：
  > “Due to the distribution policy of AMASS dataset, we are not allowed to distribute the data directly.”
- 仓库提供从 AMASS 重建数据的脚本，不等于赋予 AMASS 动作商用或再分发权；文字标注的独立授权范围也应在真实引入前核实。
- 适用：学习文字检索动作的描述模式，例如身体部位、方向、动作阶段、速度。第一版可借鉴任务设计，自己撰写动作元数据；不能把通用文字到动作模型的输出当作专业教学或合理训练计划。

## 7. EDGE：Editable Dance Generation from Music

- [官方项目](https://edge-dance.github.io/)、[官方仓库](https://github.com/Stanford-TML/EDGE)、[论文](https://arxiv.org/abs/2211.10658)。条件 diffusion 配合 Jukebox 音乐特征；支持局部关节条件、动作中间段补全和续跳。项目称 5 秒片段拼接为长舞蹈；该结果证明了研究可行性，未证明初学者可完成或动作教学准确性。
- [LICENSE](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/LICENSE) 是 MIT，允许软件使用、改写、销售、分发并保留版权与许可。仓库 README 提供外部 checkpoint 下载，但本次所读材料**没有单独明确权重的许可范围**。
- README 明确训练需要 AIST++ 的 `wavs and motion`；数据/音乐许可不能由 MIT 代码替代。自定义 WAV 输入也应是用户具有相应使用权的文件。
- 运行条件：官方推荐 Linux；PyTorch 1.12.1、CUDA 11.6、高端 NVIDIA GPU 且每卡至少 16 GB 显存。官方还明确这是 research implementation，发布后一般不会长期维护。没有本次验证的 Swift/Core ML 或 Apple Silicon 移植。
- 第一版使用确定性的已审核动作组合器（舞种、难度、BPM、动作前后条件、重复次数）。后续可做独立的生成实验，先明确权重/数据授权、评价关節极限/脚滑/连续性及教练可教性，再讨论产品接入。

## 8. SMPL-Model 与 SMPL-Body

- [SMPL-Model License](https://smpl.is.tue.mpg.de/modellicense.html)：完整软件/数据为非商业研究许可；明确禁止商业训练、默认禁止分发，商业许可入口为 Meshcapade/页面联系人。
- [SMPL-Body License](https://smpl.is.tue.mpg.de/bodylicense.html) 是不同许可对象，直接证据：
  > “SMPL-Body is a subset of SMPL-Model which excludes the shape blendshapes or the tools to create 3D bodies using the shape blendshapes of the SMPL-Model.”
  > “SMPL-Body is licensed under the Creative Commons Attribution 4.0 International License.”
- 因此“所有 SMPL 资产都不可商用”和“一个网格可商用所以整个 SMPL 工具链可商用”都不准确。取得 Body 子集资产时应记录来源、许可、署名；许可本身不是素材下载记录。SMPLH、SMPLX、FLAME 等也不能自动套用这个 Body 许可。
- 第一版使用系统姿态关键点和原创骨架可视化。需要角色时，使用自有或明确授权的 mesh/rig；不要顺带打包研究模型文件。

## 9. STEEZY

- [官网](https://www.steezy.co/) 核查时展示 1,500+ 课程、多舞种、分级学习，以及前后视角、循环播放、镜像、速度调整、章节跳转、摄像头并排。这些是值得实现的训练交互能力，但课程数量和内容会变化。
- [Terms of Use](https://www.steezy.co/terms) 的直接证据：
  > “You will only use the Services for your own internal, personal, non-commercial use …”
  > “Use, reproduction, modification, distribution or storage of any Content for any purpose other than using the Services is expressly prohibited without prior written permission from us.”
- 条款还明确禁止 “crawls,” “scrapes,” or “spiders” 以及复制/存储显著部分内容。本次仅读取公开首页和条款作研究，没有登录、下载课程、抽取舞蹈动作或复制教学内容。
- 第一版只保存原创简介与官方外链；未来通过合作取得课程视频、教练肖像、动作提取/模型训练、音乐与分发的实际授权。

## 10. Red Bull Dance

- 官方域名候选入口：[Dance](https://www.redbull.com/int-en/tags/dance)。本次对此入口及 `https://www.redbull.com/int-en/dance-tutorials` 的正常请求均返回 HTTP 403；没有绕过访问限制。
- 只能列为舞种文化与教学的**外链候选**。没有确认具体页面当前存在、可嵌入、可抓取或可复制，也不声明已验证其课程规模。应用发布前由正常浏览访问核验实际链接，再保留原创摘要和来源，或走授权合作。

## 素材与动作库的数据要求

建议每个资产分别保存 `assetID / sourceURL / retrievedAt / author / attribution / licenseURL / assetScope / commercialUseStatus / redistributionStatus / permissionEvidence / localFileHash`。把动作标注、源视频、音乐、代码、模型权重、角色网格拆成独立对象，避免对整个资源只打一个“开源”标签。

原创动作卡建议包含舞种、别名、学习目标、前置动作、难度、节拍计数、适用 BPM、左右版本、关键姿态阶段、教练提示、常见错误、对称性、空间需求、冲击等级与示范来源。单段舞蹈的 genre 标签不足以建立这样的教学数据库。

运动轨迹应保留原始时间戳与全部已捕获帧，分别存原始估计和派生指标。评估跟练时区分跟踪置信度、方向、节奏和动作幅度，不能把风格差异压成单一“正确率”，也不能在遮挡或脚出画时生成确定性的姿态纠错。

第一版建议用原创短段节拍/节拍器练习；本地文件播放不意味着应用取得了分发音乐的权利。研究数据附带音乐、订阅音乐播放权限、视频配乐同步许可是不同范围，不能相互替代。
