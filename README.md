# BookX

极简 iOS 本地阅读 App。仅有书架、书库和导入入口，无账户、搜索或在线书城。

- 书架：最近阅读大卡片、更早读过三列展示。
- 书库：按书名拼音首字母分组，显示书名及可用作者。
- TXT：UTF-8、带 BOM 的 UTF-16、GB18030。
- EPUB：从 OPF 读取书名、作者，按 spine 顺序读取 XHTML 文字章节。
- 阅读：左右翻页、上下滚动、字号/行距/纸张颜色；记录文字块位置，重新打开及修改字号后恢复到所在块。

当前阅读器是纯文字阅读器：不保留 EPUB 图片、复杂排版、脚注跳转；不支持 DRM、扫描书。分页为可滚动文字块，不是按屏幕高度排版。位置精确到文字块，暂不记录块内滚动像素。

## 开发与验证

macOS 上运行 `swift test` 验证编码、EPUB 顺序/元数据和分页位置；运行 `xcodegen generate` 生成 Xcode 工程。打开工程后选择 iPhone 模拟器运行，最低 iOS 17。

GitHub Actions 自动运行核心测试及 iOS 模拟器编译，不生成安装包。

## 依赖

EPUB ZIP 读取使用 [ZIPFoundation 0.9.19](https://github.com/weichsel/ZIPFoundation)（MIT License）。
