# Sniffing Browser

跨端媒体嗅探下载器。内置浏览器打开网页，自动捕获页面里的图片、音频、视频和 HLS 流，支持下载、转码与导出到相册。

目标平台：Android、HarmonyOS NEXT、Windows。一套 Flutter/Dart 代码。

## 当前状态

骨架 + 极简可跑界面。核心链路（嗅探 → 队列 → 单文件下载 → HLS 分片下载解密合并）已写完，转码和相册导出留有接口待接原生。

详细方案见 [docs/tech-design.md](docs/tech-design.md)。

## 已实现

| 模块 | 内容 |
| --- | --- |
| 浏览器 | 地址栏、前进后退、刷新、加载进度 |
| 嗅探（移动端） | `onLoadResource` + `shouldInterceptRequest` 双通道，请求头缓存（Referer/Cookie） |
| 嗅探（Windows） | CDP `Network.responseReceived` / `requestWillBeSent` 事件推送，非阻塞 |
| 资源面板 | 类型分组筛选、文件名/大小展示、一键入队 |
| 下载队列 | 并发 3、状态机、取消、重试、进度独立通知 |
| 单文件下载 | `.part` 临时文件 + rename，中断不污染目标文件 |
| HLS | master 选最高码率、并发分片、AES-128 解密、fMP4 init 段处理、二进制合并、分片级续传 |
| 日志与诊断 | 文件日志、全局错误捕获、通道计数器、诊断页 |
| 导出 | 桌面纯 Dart 复制；移动端走 MethodChannel（原生待实现） |
| 转码 | 队列与命令构造完成，执行层走原生 MethodChannel（待接 FFmpeg） |

## 嗅探通道按平台分叉

这一点必须写清楚，因为踩过一次坑：**Windows 上不能照搬移动端的写法**。

| 平台 | 通道 | 阻塞页面？ |
| --- | --- | --- |
| Android | `onLoadResource` + `shouldInterceptRequest` | 否 |
| HarmonyOS | 同上（ArkWeb `onInterceptRequest`） | 否 |
| **Windows** | **仅 CDP** | 否 |

`flutter_inappwebview_windows` 的实现里：

- 原生侧**没有** `onLoadResource`（只有 `onLoadResourceWithCustomScheme`），传了也不会触发
- `shouldInterceptRequest` 注册的是
  `AddWebResourceRequestedFilter("*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)`，
  每个请求都 `GetDeferral()` 挂起等 Dart 回话才放行。一个普通首页两三百个请求全串行
  排在主 isolate 上，**页面直接卡死无响应**

所以 Windows 端走 CDP 订阅，不影响请求本身。实现在
`lib/features/sniffer/data/cdp_sniffer.dart`。

## 排查问题

界面右上角虫形图标进诊断页，能看到：

- 实时日志（可按“只看警告和错误”过滤）
- 通道计数器。判断嗅探为什么没结果：

| 现象 | 含义 |
| --- | --- |
| `cdp.responseReceived` 为 0 | CDP 没挂上（仅 Windows） |
| `sniffer.shouldIntercept` 为 0 | 原生回调没来（仅移动端） |
| 两者都有但 `sniffer.captured` 为 0 | 分类器把资源全过滤了 |
| `webview.loadStop` 有但 `captured` 为 0 | 页面打开了但嗅探没生效，日志里会有对应 warn |

日志文件位置（下载目录下的 `SniffingBrowser/logs/app.log`）：

- Windows / 桌面：`下载/SniffingBrowser/logs/app.log`
- Android：`/sdcard/Android/data/com.sniffing.sniffing_browser/files/SniffingBrowser/logs/app.log`
- HarmonyOS：应用 `filesDir/SniffingBrowser/logs/app.log`

全局错误捕获已装好（`FlutterError.onError`、`PlatformDispatcher.onError`、
`runZonedGuarded` 三重），崩溃信息会写进同一个文件。


## 未实现

- `MediaExporter` 的 Android（MediaStore）/ HarmonyOS（showAssetsCreationDialog）实现
- FFmpeg 接入：Android `ffmpeg_kit_flutter_new`、鸿蒙 `@ohos/ffmpeg-kit`
- DASH 分片重组（当前直接提示不支持）

## 运行

```bash
flutter pub get
flutter run -d windows      # 桌面
flutter run -d <android>    # Android
```

### Windows 构建前提

- **WebView2 Runtime**：Win11 与新版 Win10 自带，缺失时从微软官网装 Evergreen Runtime
- **NuGet**：`flutter_inappwebview_windows` 通过 NuGet 拉取 WebView2 SDK 和 WIL，缺了会报
  `NUGET-NOTFOUND`，构建直接失败。把 `nuget.exe` 放进 PATH 即可（本项目实测放在
  `~/.devtools/nuget.exe`，构建时前置到 PATH）

本机若配置了 HTTP 代理，`flutter test` / `flutter run` 可能因为 flutter_tester 的
localhost WebSocket 被代理拦截而报 `Invalid WebSocket upgrade request`。加环境变量即可：

```bash
NO_PROXY="localhost,127.0.0.1" flutter test
```

## 版本注意

| 组件 | 版本 |
| --- | --- |
| Flutter | 3.44.9（本机现有，可跑 Windows） |
| 鸿蒙必需 | 3.35.8-ohos，`flutter_inappwebview` 换 `br_v6.1.5_ohos` 分支 |

`pubspec.yaml` 的 SDK 约束写成 `>=3.9.0 <4.0.0`，两条版本线都能满足。切鸿蒙时按
`pubspec.yaml` 末尾注释替换 WebView 依赖即可。

## 目录

```
lib/
├── app/                  # App 入口、主题、全局 Provider
├── core/                 # 常量、平台判定、存储路径、媒体导出、日志、工具
└── features/
    ├── browser/          # WebView 与地址栏
    ├── sniffer/          # 分类器、捕获服务、CDP 通道、资源面板
    ├── downloader/       # 下载队列、单文件下载、HLS 子模块
    ├── transcoder/       # 转换队列与引擎抽象
    └── diagnostics/      # 日志与通道计数器页面
```

## 已知限制

- DRM（Widevine / FairPlay）内容无法处理
- YouTube、B 站这类签名 + MSE 拼流的站点抓不到原始分片
- `blob:` 资源直接过滤，不显示
- 鸿蒙适配版 `transparentBackground` 不生效、`onReceivedError` 有空指针问题，代码里已绕开
