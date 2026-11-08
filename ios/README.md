# Flow for iOS

基于 Civitai Flow 的公开功能说明，独立实现的原生 iOS 客户端。SwiftUI + AVFoundation，最低 iOS 17，支持 iPhone 和 iPad。没有第三方运行时依赖。

## 上游仓库核查

核查日期：2026-11-08。`WalidAliAlfaid/civitai-flow` 的 `main`（`24b8d58`）、`v1.0.0` 标签、全部 10 次提交均只有说明、Issue 模板与宣传图片；没有应用源码、构建文件或 GitHub Release。上游 README 的 APK / EXE 是编译成品。

因此，本目录是新增的独立实现，不是对未公开源码的直接移植。上游 README、LICENSE 与图片原样保留；iOS 应用不打包上游宣传图片，也未反编译安装包。

## 已实现

- 发现页：原生图片/视频网格、卡片内播放、热门/最新/热议排序和时间筛选；支持 home、models、images、videos、3D Models、hubs、articles、comics、crucibles、updates、shop 导航。更多分类在应用内打开官网。
- 搜索栏默认隐藏，点右上角放大镜展开；可切换 models、images、articles、users、collections、comics、bounties、tools，结果在应用内官网展示。
- 沉浸浏览：纵向整页滑动；顶栏切换仅图片/仅视频/混合模式，右滑选择收藏夹。视频循环播放、静音、手动暂停、自动播放开关；离开作品释放播放器，后台暂停。浏览模式独立于发现页。
- 生成信息：公开的正反向提示词、基础模型、参数和资源信息，支持复制。
- 收藏：支持新建收藏夹、一个作品保存至多个收藏夹、旧版收藏迁移和搜索。本地 JSON 原子保存，重启恢复；API Key 配置后同步官网收藏夹及图片/视频收藏。本机未同步修改持久化并可重试，账户切换隔离各自云端收藏。收藏媒体仍需联网。
- 分享作品链接、跳转 Civitai 查看评论、下载原图/视频到相册。
- 下载中心：粘贴 Civitai 模型链接，选择版本与模型文件，配套保存预览、完整版本 JSON 和描述文本；作品也可连同生成信息下载到本机。
- 下载进度、串行队列、取消、失败重试、记录恢复、去重、删除和系统“文件”导出。
- 可选 API Key 保存在设备 Keychain；不在日志、URL 或 UserDefaults 中存储。
- 加载、错误、空内容、重试、游标分页和重复数据处理。
- 原生作品支持 PG、PG-13、R、X、XXX 多选筛选；默认 PG，可自动模糊 R+，轻点单项查看。API 请求和客户端均检查等级。官网页面使用官网本身的内容设置。

## 尚未实现

- Civitai 网页账户登录与原生账户会话互通、关注流、原生点赞/评论/Buzz。
- 个性化推荐、全站离线媒体缓存、生成工具。
- App Store 分发与签名配置。

“热门”使用公开接口的排序，不表示个性化推荐；API Key 不是完整网页登录。收藏同步使用具有收藏读写权限的 Key，通过 Civitai 的 `collection.*` tRPC 接口及 `/api/v1/me`、`/api/v1/images` 实现；非媒体收藏夹可从收藏页进入官网。官网页面不会接收本机 Keychain 中的 API Key。以上未实现项没有伪装成可用按钮。

## 打开运行

1. 安装完整 **Xcode 16 或更新版本**，并安装 iOS Simulator runtime。
2. 打开 `ios/Flow.xcodeproj`，等待本地 `FlowCore` Swift Package 解析。
3. 选择 **Flow** scheme 和 iPhone 模拟器，按 **⌘R**。
4. 真机：在 Target → Signing & Capabilities 中选择自己的 Team，并将 Bundle Identifier 改为自己的唯一标识。

无需启动后端。公开浏览无需 API Key；设备需要能够访问 `civitai.com` 和 `image.civitai.com`。首次点击保存才请求相册“添加”权限。

## 使用下载功能

1. 打开底部 **下载** → **粘贴模型链接下载**，输入 `https://civitai.com/models/模型ID`。也支持 `?modelVersionId=版本ID` 和 `https://civitai.com/api/download/models/版本ID`；链接中的文件类型、格式、精度参数用于匹配对应文件。
2. 读取信息后选择版本、文件（显示体积、格式、精度），设置是否保存预览、是否仅选择图片预览、是否保存描述，再点 **加入下载**。有明确版本 ID 的生成资源，也可从作品的“生成信息”进入下载。
3. 模型下载同时保存同名 `.civitai.info`（完整版本 JSON）、可选 `.preview.*` 和 `.description.txt`。预览遵循设置中选择的内容等级，未提供匹配预览/描述时跳过并说明；网络下载失败会将整项标记为失败，可重试。
4. 在作品的 **下载** 菜单中选择 **下载到文件（含生成信息）**，即可保存图片/视频及其生成元数据；**保存到相册**仍使用系统相册权限。
5. 在下载列表查看当前文件和字节进度，取消或重试；完成后点 **查看内容** 可离线查看图片、播放视频、读取生成信息/描述，点文件名可直接选择该文件。模型权重可查看文件信息并导出到兼容应用。点 **导出到文件** 选择 iCloud Drive 或本机目录。也可直接在系统“文件”→“我的 iPhone / iPad”→“Flow”→“Downloads”访问下载结果。

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

本机现已安装 Xcode 26.3、iOS 26.2 SDK 和 iOS 26.3.1 模拟器，完整模拟器构建及首页启动检查已通过，也已在 iPhone 16 上完成签名安装和首次启动验证。上面的无签名命令仅用于编译验证；运行应用请在 Xcode 中选择模拟器并按 **⌘R**，使用正常的本地签名，否则钥匙串可能报告权限错误。具体结果与尚未完成的验收见 `VALIDATION.md`。

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


## 收藏同步与浏览交互

- 保存 API Key、应用启动、回到前台、收藏变更后触发同步；收藏页下拉或设置中的“立即同步收藏夹”可手动重试。
- 新建本地收藏夹会在关联账户创建私有 Image 收藏夹。支持同步账户自己的普通收藏夹；非媒体收藏夹只提供官网入口，不修改其模型/文章条目。比赛投稿集合不参与收藏同步。
- 同步时先上传本机队列，再导入官网快照；修改直到读回确认后才移出队列，失败或读取延迟的操作在重启后保留。文件夹绑定所属账户，不会把另一账户的收藏夹写到新账户。网站删除存在本机待上传收藏的文件夹时，会保留为“仅本机”恢复收藏夹，可从菜单明确选择重新同步。
- 原生视频右上角的播放/暂停按钮只控制卡片播放；画面和标题打开全屏。音量共享设置中的静音状态，显式点击播放可在关闭自动播放时使用。
- 全屏右滑会打开收藏夹多选面板，保存后生效；原有上下分页继续使用。
- 混合模式图标使用 imagegen 技能制作，提示词及资源说明见 [design/media-mode-icon.md](design/media-mode-icon.md)。

收藏 tRPC 接口不是稳定版本的公开 REST 契约，上游变更可能需要适配。未配置真实 API Key 时，只能验证固定响应下的读写、分页和恢复流程，真实账户同步需在设备上验收。


## 保存到系统相册

作品下载菜单的“保存到相册”只申请添加权限，等待 Photos 确认创建资产后才提示成功。新保存内容使用当前保存日期，避免原文件的旧 EXIF / 视频创建时间让内容落到时间线较早的位置。已保存的旧内容可在系统相册的“最近保存 / 最近添加”查找。

不兼容的可解码图片转换成 PNG，视频必要时尝试转换 MP4；不能转换时提示改用“下载到文件”。成功提示在页面底部显示 2 秒后淡出，不需要点击确认。

相册集成回归测试：`bash ios/scripts/test-photos.sh`（需要 XcodeGen）。脚本使用独立测试 App 和独立模拟器，验证图片/视频真实写入与回读，正式 App 不增加相册读取权限。首次遇到测试宿主的读取权限提示时，只对该隔离测试图库允许访问即可。

此前调整项的逐项实现、审核修复及验证边界见 [REVIEW.md](REVIEW.md)。

## 视觉样式

应用图标、发现页和沉浸页标识、设置品牌卡片共用新的流线 f Logo。原生页面采用暖白、石墨黑与珊瑚红，支持浅色和深色模式；分类、收藏夹、搜索和媒体操作共用圆角、边距与选中样式。完整配色、资源位置和 imagegen 提示词见 [design/visual-identity.md](design/visual-identity.md)。
