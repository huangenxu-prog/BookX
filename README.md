# BookX

极简 iOS 本地阅读器。书架、书库、TXT / EPUB 导入；保留 Core Text 按屏排版和 UIPageViewController 沉浸式仿真翻页，也支持左右滑动、上下滚动。

## EPUB 按需读取

- 导入只读取 container、OPF 和 NCX / EPUB 3 导航元数据。
- 打开时只转换、分页目标 XHTML；显示后预加载前后相邻的文字章节，跳过空章节。
- 使用 ZIPFoundation 读取 ZIP，复用现有 Foundation XMLParser 转换 XHTML。资源索引、定位和相邻预加载参考 [Readium 的资源模型](https://readium.org/swift-toolkit/latest/documentation/readium/getting-started/)，没有引入或声称使用 Readium 的渲染引擎。
- 内存最多保留五个章节的文字分页，单资源解压限制 16 MiB。正文缓存按资源保存，身份和内容一起原子写入；源路径、大小、修改时间、资源路径与缓存版本共同校验。应用导入文件使用独立 UUID，不原地编辑 EPUB。
- 阅读位置保存为 spine 资源序号 + 章内 UTF-16 偏移，字号、模式、窗口增删不改变位置。预加载插入前一章时，滚动和仿真翻页按资源/偏移重新定位；交互式翻页期间延后替换 UIKit 数据源。
- 退出、目录跳转、调整排版取消对应后台任务，并用请求代次阻止旧结果覆盖新页面。Core Text 每页、ZIP 解压分块、XML 解析事件检查取消。
- 目录按 spine 章节显示，读取 NCX / EPUB 3 标题；不解析全书标题。目录内同一个 XHTML 的多个锚点仍合并到该章节（与原有每 XHTML 一项的目录粒度一致）。
- 不预先计算全书页数。原页脚位置、字体、布局不变，EPUB 数值显示章节位置和当前章页数；书架百分比是章节加权进度，不是全书字数百分比。

## 历史数据与边界

已有书库 JSON 可直接读取。旧 EPUB 全书偏移首次打开时迁移到资源定位：有兼容的章节元数据则直接定位，否则只扫描到旧书签所在章节；这次迁移可能仍慢，后续打开不再扫描前文。旧版本曾混用字符与 UTF-16 偏移，含大量 emoji 的旧书签可能有偏差；新位置统一 UTF-16。TXT 保留原有编码识别、全文缓存和分页流程。

纯文字阅读器不保留图片、复杂 CSS、脚注跳转；不支持 DRM、纯图片书。单个特别大的 XHTML 仍需完成该章节解析/分页，无法保证所有 EPUB 同样快。章节缓存可由系统清理并重新生成。当前不记录垂直滚动的块内像素位置。

## 开发与验证

macOS / Xcode 26.2：

```sh
python3 scripts/make_test_epubs.py
swift test
xcodegen generate
xcodebuild -project BookX.xcodeproj -scheme BookX -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 在开发分支和 main 上执行核心测试、模拟器编译、arm64 真机构建并打包未签名 IPA。测试使用合成 EPUB，覆盖延迟解析、导航、空章节、章间窗口、Unicode 书签、换字号、缓存替换/并发、取消及 1,836 个资源的首次读取。基准输出属于 macOS，不代表 iPhone 耗时。

现有 UITests 文件是早期 UI 的测试，当前工作流不执行它，不应把模拟器编译称为 UI 测试通过。真机仍须确认三种模式的跨章节手势、沉浸式卷页、菜单点击、听书连续播放、冷启动耗时、退后台/退出及长时间阅读内存。

## 依赖

[ZIPFoundation 0.9.19](https://github.com/weichsel/ZIPFoundation)（MIT License）。
