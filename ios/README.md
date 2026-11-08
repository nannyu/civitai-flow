# Flow for iOS

基于 Civitai Flow 的公开功能说明，独立实现的原生 iOS 客户端。SwiftUI + AVFoundation，最低 iOS 17，支持 iPhone 和 iPad。没有第三方运行时依赖。

## 上游仓库核查

核查日期：2026-11-08。`WalidAliAlfaid/civitai-flow` 的 `main`（`24b8d58`）、`v1.0.0` 标签、全部 10 次提交均只有说明、Issue 模板与宣传图片；没有应用源码、构建文件或 GitHub Release。上游 README 的 APK / EXE 是编译成品。

因此，本目录是新增的独立实现，不是对未公开源码的直接移植。上游 README、LICENSE 与图片原样保留；iOS 应用不打包上游宣传图片，也未反编译安装包。

## 已实现

- 发现页：双列/自适应网格、图片与视频切换、热门/最新/热议排序、时间范围筛选、按创作者用户名查询。
- 沉浸浏览：纵向整页滑动；视频循环播放、静音、手动暂停、自动播放开关；离开作品释放播放器，后台暂停。
- 生成信息：公开的正反向提示词、基础模型、参数和资源信息，支持复制。
- 收藏：本地 JSON 原子保存，重启恢复，按创作者/模型/提示词搜索。收藏的是作品信息，媒体仍需联网。
- 分享作品链接、跳转 Civitai 查看评论、下载原图/视频到相册。
- 下载中心：粘贴 Civitai 模型链接，选择版本与模型文件，配套保存预览、完整版本 JSON 和描述文本；作品也可连同生成信息下载到本机。
- 下载进度、串行队列、取消、失败重试、记录恢复、去重、删除和系统“文件”导出。
- 可选 API Key 保存在设备 Keychain；不在日志、URL 或 UserDefaults 中存储。
- 加载、错误、空内容、重试、游标分页和重复数据处理。
- 普通内容（SFW）筛选，客户端再次检查作品等级。

## 尚未实现

- Civitai 账户登录、云端收藏同步、关注流、原生点赞/评论/Buzz。
- 个性化推荐、成熟内容切换、离线媒体缓存、生成工具。
- App Store 分发与签名配置。

“热门”使用公开接口的排序，不表示个性化推荐；API Key 不是完整账户登录。以上未实现项没有伪装成可用按钮。

## 打开运行

1. 安装完整 **Xcode 16 或更新版本**，并安装 iOS Simulator runtime。
2. 打开 `ios/Flow.xcodeproj`，等待本地 `FlowCore` Swift Package 解析。
3. 选择 **Flow** scheme 和 iPhone 模拟器，按 **⌘R**。
4. 真机：在 Target → Signing & Capabilities 中选择自己的 Team，并将 Bundle Identifier 改为自己的唯一标识。

无需启动后端。公开浏览无需 API Key；设备需要能够访问 `civitai.com` 和 `image.civitai.com`。首次点击保存才请求相册“添加”权限。

## 使用下载功能

1. 打开底部 **下载** → **粘贴模型链接下载**，输入 `https://civitai.com/models/模型ID`。也支持 `?modelVersionId=版本ID` 和 `https://civitai.com/api/download/models/版本ID`；链接中的文件类型、格式、精度参数用于匹配对应文件。
2. 读取信息后选择版本、文件（显示体积、格式、精度），设置是否保存预览、是否仅选择图片预览、是否保存描述，再点 **加入下载**。有明确版本 ID 的生成资源，也可从作品的“生成信息”进入下载。
3. 模型下载同时保存同名 `.civitai.info`（完整版本 JSON）、可选 `.preview.*` 和 `.description.txt`。预览只选择普通内容，未提供预览/描述时跳过并说明；网络下载失败会将整项标记为失败，可重试。
4. 在作品的 **下载** 菜单中选择 **下载到文件（含生成信息）**，即可保存图片/视频及其生成元数据；**保存到相册**仍使用系统相册权限。
5. 在下载列表查看当前文件和字节进度，取消或重试；完成后点 **导出到文件** 选择 iCloud Drive 或本机目录。也可直接在系统“文件”→“我的 iPhone / iPad”→“Flow”→“Downloads”访问下载结果。

每项下载使用独立文件夹，避免同名覆盖。大文件由 URLSession 直接写入临时文件，完成整项后才发布到下载目录；不会将模型整体加载进内存。预览扩展名根据实际文件头确定，不会把 JPEG/WebP 直接改名为 PNG。

下载为**前台串行任务**：不提供后台传输或断点续传，取消、失败和应用退出后的重试会从头开始。已完成文件与记录在重启后保留；下载记录不保存 API Key。受限模型需要在“设置”中填写有下载权限的 API Key，认证头只用于 Civitai API，跳转到文件存储域名时移除。

功能参考：[nihedon/civitai-downloader](https://github.com/nihedon/civitai-downloader)。使用 Swift / URLSession 独立实现其配套文件下载流程，未引入浏览器用户脚本或第三方运行时。

已提交生成好的 Xcode 工程，无需先安装 XcodeGen。修改目录或工程配置后，可用：

```sh
brew install xcodegen
cd ios
xcodegen generate
```

## 验证

安装 Xcode 16 或 Swift 6 Command Line Tools 后，可使用兼容两种环境的脚本测试核心包（Swift Testing）：

```sh
bash ios/scripts/test.sh
```

可选真实网络冒烟测试（会访问公开 API，默认测试跳过）：

```sh
FLOW_LIVE_API=1 bash ios/scripts/test.sh --filter LiveAPITests
```

完整 Xcode 环境中的模拟器构建：

```sh
xcodebuild -project ios/Flow.xcodeproj -scheme Flow \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/FlowDerivedData CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 中已添加同样的核心测试和 iOS 构建任务；需要推送后才会运行。

本次开发机器只有 Command Line Tools，没有 iOS SDK 或模拟器，因此不能把 Swift 语法解析或核心包测试当成 iOS 编译与真机验证。具体已执行结果见 `VALIDATION.md`。

## 工程结构

```text
ios/
  Flow.xcodeproj/           可直接打开的应用工程
  project.yml              XcodeGen 配置
  Flow/App/                入口、共享状态
  Flow/Views/              SwiftUI 页面与视频播放器
  Flow/Services/           Keychain、相册保存
  Flow/Resources/          图标、Info.plist、隐私清单
  FlowCore/                API、模型、分页、收藏、下载计划/传输/队列与测试
```

接口依据：[Civitai Images API](https://developer.civitai.com/site/reference/images)。分页仅使用 opaque `nextCursor`，不跟随任意 `nextPage` 链接；请求 `withMeta=true` 获取作者公开的生成参数。非图片/视频条目被忽略。服务端权限、地区与网络条件仍可能限制返回内容。
