# Hidan Club 标志

设计日期：2026-09-09。

直接以低重心的街舞姿态构成标记：斜向延展的手臂、屈膝站姿、宽松裤装与落地的运动鞋，以暖白剪影呈现在深墨紫底上。脚边的荧光绿短线提示节拍。图形不含字母、首字母或字母变形；侧栏原有 hidan 名称作为独立文字保留。

## 正式资源

- `Sources/HidanClub/Resources/Brand/HidanLogo.png`：内置 imagegen 生成的原始 1254 × 1254 PNG，含 alpha，完整保存。
- `Sources/HidanClub/Resources/Brand/AppIcon.icns`：通过系统 sips/iconutil 制作的 macOS 多尺寸图标。
- `script/generate_app_icon.sh`：从原始 PNG 生成 16/32/128/256/512 pt 及各自 @2x 的十个标准图标表示；不改写原始 PNG。

图标显示于 Dock / 应用包、侧栏品牌区和设置页。构建脚本将 icns 拷贝到 `.app/Contents/Resources` 并设置 `CFBundleIconFile`；应用内图片优先读取打包资源，保留正式 PNG 和 icns 在版本控制中。

## 生成方式与最终提示词

使用内置 `imagegen`，未使用 CLI/API 回退。提示词如下（生成器实际返回 1254 px 方图，macOS 标准尺寸由打包脚本派生）：

> Use case: logo-brand. Design ONE new final macOS app icon for a serious, beautifully designed street-dance learning app. The previous letter-based concept was rejected. ABSOLUTELY NO LETTERS, NO INITIALS, NO MONOGRAM, NO TYPOGRAPHY, no hidden h or k forms. Develop the icon directly from a dynamic human STREET DANCE POSE. A striking, compact, near-white sculptural silhouette of one dancer in a low asymmetric hip-hop groove: small round head, torso leaning diagonally, one arm extending fluidly outward/up, the other bent across the rhythm, clearly bent knees with wide grounded footwork. Anatomically plausible recognizable dance energy, abstracted into a few confident thick rounded geometric shapes with carefully separated limbs and generous negative spaces, not a stick figure, not the generic accessibility/running symbol, not a ballet pose, not acrobatics. The pose itself is the sole brand symbol. A single tiny electric-lime accent near one foot can suggest the beat, but no orbit rings or decorative particles. Background: a solid deep ink-violet (#252248) macOS continuous rounded-square tile, subtle restrained top lighting. Silhouette: warm porcelain-white, flat clean vector-like design with just a hint of soft dimensionality, no chrome, no glass, no heavy shadows, no gradients in the silhouette. Premium editorial and modern dance studio identity, precise, mature, lively but minimal, extremely legible at 32 pixels. Single centered icon on square PNG, icon tile occupies about 84% of canvas with equal transparent margin on all sides; actual transparent alpha outside, no white or gray surrounding background. No text, no border, no mockup, no watermark, no thin outlines, no sports equipment, no music note, no sheet of alternatives. Make this feel like a strong designed symbol, not a generic generated logo.
