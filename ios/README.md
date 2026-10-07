# HidanClub iOS

基于同一个 SwiftPM 包（`HidanCore`）的 iOS 版本，与 macOS 版并存，不影响 macOS target。

## 生成工程

```sh
brew install xcodegen   # 若未安装
xcodegen generate --spec ios/project.yml --project ios
```

## 构建（无需签名/模拟器）

```sh
xcodebuild -project ios/HidanClubIOS.xcodeproj -scheme HidanClubIOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 功能

- 动作库：DanceCatalog 浏览 + 内置骨架预览动画（PracticeMotionLibrary，2D Canvas 渲染，可调速）
- 训练：PlanBuilder 生成计划，TrainingClock 驱动计时练习，完成后写入练习录
- 编排：SequenceBuilder 生成 4×8 拍组合（BPM 可调，含风险提示）
- 练习录 / 关于：历史记录（UserDefaults）与内容声明

## 已知限制

- 不含 AIST++ 数据集回放、视频库、音乐库、相机跟练与 Party 模式（这些依赖 macOS 端
  AppKit/SceneKit/本地数据集，留在 macOS 版本）。
- Bundle ID 为 `app.hidanclub.ios`，与 macOS 版区分；默认 `CODE_SIGNING_ALLOWED=NO`，
  真机分发需自行配置签名。
