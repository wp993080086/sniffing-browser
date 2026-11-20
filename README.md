# Sniffing Browser

跨端媒体嗅探下载器。内置浏览器打开网页，自动捕获页面里的图片、音频、视频和 HLS 流，支持下载、转码与导出到相册。

目标平台：Android、HarmonyOS NEXT、Windows。一套 Flutter/Dart 代码。

## 当前状态

**Windows 端核心链路已端到端实测**：嗅探 → 队列 → 下载 → 分片合并 → 转码成 mp4/mp3。
**Android 在 USB 真机上跑**：双回调嗅探 A2 已通过，MediaStore 导出与原生 FFmpegKit
转码已实现（2026-11-12），待真机验证导出与转 MP3。鸿蒙平台工程尚未生成，
原生导出 / 转码仍未接入。

详细方案见 [docs/tech-design.md](docs/tech-design.md)。

## 已实现

| 模块 | 内容 | 验证状态 |
| --- | --- | --- |
| 浏览器 | 两层顶栏：第一层前进后退 / 地址栏 / 刷新（加载中变停止），第二层搜索引擎 / 页签 / 下载 / 诊断；嗅探入口是可拖动的右下角毛玻璃悬浮按钮（56dp，位置只存内存） | Windows 实测 |
| 历史记录 | 页面加载完成自动记录（同地址只留一条并提到最前），按天分组的列表、单条删除、清空；落盘在应用私有目录，重启后还在 | 编译 + 单测覆盖，待真机 |
| 收藏夹 | 地址栏星标一键收藏 / 取消，列表按加入时间倒序、单条取消、清空；与历史分文件存储 | 编译 + 单测覆盖，待真机 |
| 性能 | 非活跃页签自动挂起 WebView 并暂停页面音视频；自动播放只拉视口内第一个，页面内媒体播放互斥；视频缩略图抽帧串行 | 编译 + 单测覆盖 SerialGate，待真机 |
| 多页签 | 每页签独立 WebView（同时最多 4 个，超出按最久未用回收），嗅探结果跟着页签走；`target=_blank` / `window.open` 自动开新页签；两栏卡片瀑布流切换器；返回手势先退网页再退应用 | 编译 + 单测覆盖，待真机 |
| 嗅探（移动端） | `onLoadResource` + `shouldInterceptRequest` 双通道，请求头缓存（Referer/Cookie） | 未实测 |
| 嗅探（Windows） | CDP `Network.responseReceived` / `requestWillBeSent` 事件推送，非阻塞 | Windows 实测 |
| 请求头补全 | 嗅探缓存头 + `pageUrl` 兜底 Referer + 按平台 UA + **按请求 URL 从 `CookieManager` 现取 Cookie**（Android） | 单测覆盖合并逻辑，待真机复验 403 站点 |
| 资源面板 | 类型分组筛选、缩略图（图片 + 视频首帧）、文件名/大小展示、一键入队 | 桌面 Windows 实测；Android 抽帧待真机复验 |
| 下载队列 | 并发 3、状态机、取消、重试、进度独立通知、单文件断流按 Range 续传 | 端到端测试 |
| 单文件下载 | `.part` 临时文件 + rename，中断不污染目标文件；断流后按 `Range` 续传，失败保留 `.part` | 端到端测试 |
| 后台保活 | Android 下载期间挂 `dataSync` 前台服务（常驻通知），切后台/锁屏不再被冻结断流 | 编译通过，待真机复验 |
| HLS | master 选最高码率、并发分片、AES-128 解密、fMP4 init 段处理、二进制合并、分片级续传 | 端到端测试 |
| 转码（桌面） | 调用系统 ffmpeg：TS→MP4 无损转封装、音频→MP3 重编码，进度解析、取消 | 端到端测试 |
| 日志与诊断 | 文件日志、全局错误捕获、通道计数器、诊断页 | Windows 实测 |
| 导出 | 桌面纯 Dart 复制；Android MediaStore（MediaStore + `IS_PENDING`） | 桌面可用；Android 真机已验证 mp4 入库 |
| 转码（Android） | 原生 `dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9`（LGPL）经 MethodChannel 桥接，完成后自动写进 MediaStore | 已实现，待真机复验 MP3 落库 |
| 转换页与持久化 | 独立「转换」页（入口在下载页 AppBar，带进行中角标）；任务落盘 `transcode_jobs.json`，重启后 pending 续跑、running 标中断；已完成项可「打开」产物 | 单元测试覆盖 |
| 产物打开 / 分享 | 下载项菜单「打开」全平台可用（Android 走 FileProvider 的 `content://`，无需先导出）；「分享」仅 Android，拉起系统分享面板 | 编译 + 单元测试覆盖，待真机 |
| 下载记录持久化 | `download_tasks.json`（私有 files 目录，不用 cache）；重启后历史还在，没下完的标「已中断，可重试」且不自动重跑 | 单元测试覆盖 |

Android 上转换产物会**自动**写进系统媒体库：MP3 落到 `音乐/SniffingBrowser`，
MP4 落到 `视频/SniffingBrowser`。原因见下——应用只能直接写私有目录，而
`Android/data` 在 Android 11+ 的文件管理器里进不去，不复制一份用户就找不到。

下载完成的任务在下载页菜单里可以直接**「打开」**（Android 通过 `FileProvider` 把
私有目录的文件换成带读授权的 `content://` 交给系统播放器，不必先保存到相册），
Android 还多一个**「分享」**拉起系统分享面板；桌面只给「打开」。

转换进度与任务列表在**「转换」页**（下载页右上角 `⇄` 图标，角标＝进行中数量）。
发起仍在下载项菜单里：点完「转为 MP3」后菜单项会消失（防重复入队），
所以 SnackBar 带一个「查看进度」直达转换页。转换页里已完成的任务可以点 ⋮ →「打开」，
直接交给系统播放器（Android 用入库的 `content://` URI 带读授权，桌面拉起默认程序）。

资源列表的缩略图只覆盖**图片和视频**：图片带 Referer/Cookie 重新取一次并降采样到 160px，
视频在 Android 用 `MediaMetadataRetriever`、桌面用本机 ffmpeg 抽第一帧；
音频 / HLS / DASH 没有便宜的封面来源，仍是类型图标。取不到图（403、超时、单图超过 3 MB）
一律静默退回图标，不转圈也不显示破图。并发和流量保护见 `docs/tech-design.md` 5.2.1。

## FFmpeg（桌面端）

桌面端直接调用本机 ffmpeg 进程，不引预编译包。查找顺序：

1. 环境变量 `SNIFF_FFMPEG_DIR` 指向的目录
2. 应用可执行文件同目录（或其 `bin/`、`ffmpeg/bin/` 子目录）—— 随应用分发时放这里
3. `~/.devtools/ffmpeg/bin/`（本机开发用的位置）
4. 系统 PATH

`ffmpeg` 和 `ffprobe` 都要有。ffprobe 只用于取总时长算进度百分比，缺了转换照样能跑，只是不显示百分比。

装到本机开发位置：

```bash
bash ~/.devtools/get-ffmpeg.sh
```

脚本从 npmmirror 拉静态构建，用 `gzip -t` 校验完整性并自动重试——这台机器到镜像的连接会中途断，一次拉不完。

## 验证脚本

除了常规单测，还有两套真实链路的端到端验证。默认跳过，需要显式开启：

```bash
# 下载链路：单文件 / HLS 合并 / AES-128 解密（12 项）
dart run tools/verify_download.dart

# 队列与转码：需要网络，ffmpeg 测试还需要本机有 ffmpeg
RUN_E2E=1 flutter test test/download_queue_e2e_test.dart
RUN_E2E=1 flutter test test/transcode_e2e_test.dart
```

`verify_download` 用本地 HTTP 服务提供 playlist，但分片是真实 CDN 的，所以解析、并发、解密、合并走的都是生产代码。AES 那组刻意不写 `IV`，逼着下载器按 RFC 8216 用媒体序列号推导——这处写错不会报错，只会产出乱码。

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
- Android：`/sdcard/Android/data/com.wp.sniffing_browser/files/SniffingBrowser/logs/app.log`
- HarmonyOS：应用 `filesDir/SniffingBrowser/logs/app.log`

全局错误捕获已装好（`FlutterError.onError`、`PlatformDispatcher.onError`、
`runZonedGuarded` 三重），崩溃信息会写进同一个文件。


## Android 原生能力（2026-11-12 新增）

`MainActivity.kt` 注册两个 MethodChannel，只在 Android 生效，桌面与鸿蒙不受影响：

| 通道 | 实现 | 能力 |
| --- | --- | --- |
| `sniffing_browser/media_exporter` | `MediaExporterHandler.kt` | API 29+ 走 MediaStore + `IS_PENDING` 写入相册 / 音乐 / 下载目录，无需存储权限；API ≤ 28 走公共目录 + 媒体扫描 |
| `sniffing_browser/transcoder` | `TranscodeBridge.kt` | FFmpegKit 执行 TS→MP4、抽 MP3、DASH 音视频合并，带进度与取消 |

转码依赖写在 `android/app/build.gradle.kts`：
`dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9`（LGPL、FFmpeg 8.1.2、
含 libmp3lame）。官方 `com.arthenica:ffmpeg-kit-*` 已于 2025-04 从 Maven Central 移除，
这里用社区维护的等价构建，**没有引入 Flutter pub 包**，所以 `pubspec.yaml` 不变。

AAR 只发布 `arm64-v8a` / `x86_64`，因此 `ndk.abiFilters` 也限定为这两个 ABI。
带 FFmpeg 的 debug APK 约 227MB（此前 184MB）。32 位设备需自行编译 AAR。

## 未实现

- `MediaExporter` 的 HarmonyOS（`showAssetsCreationDialog`）实现
- 鸿蒙侧 FFmpeg 接入（`@ohos/ffmpeg-kit` 或同等 ArkTS 桥接）
- `ohos/` 平台目录（需要 Flutter-OH SDK 与 DevEco Studio，本机尚未配置）
- Android TS→MP4 的「只重编音频」失败回退（桌面已有）
- DASH 分片重组（当前直接提示不支持）
- 代理支持：`dio` 默认不读 `HTTP_PROXY` 环境变量，需要走代理的网络环境目前直连

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

- 仍 403 的站点：请求头已经尽量补齐（含 CookieManager 现取 Cookie），但要求
  `Origin`、`Sec-Fetch-*`、动态签名或绑定客户端 TLS 指纹的站点仍可能拒绝
- DRM（Widevine / FairPlay）内容无法处理
- YouTube、B 站这类签名 + MSE 拼流的站点抓不到原始分片
- `blob:` 资源直接过滤，不显示
- 鸿蒙适配版 `transparentBackground` 不生效、`onReceivedError` 有空指针问题，代码里已绕开

## Windows 上的那个崩溃（已修复，记录备查）

`flutter_inappwebview_windows` 0.6.0 有个必崩的缺陷：
`PermissionRequestCallback` 的解码函数漏了 null 检查
（`webview_channel_delegate.cpp:57`）：

```cpp
return std::make_shared<PermissionResponse>(std::get<flutter::EncodableMap>(*value));
```

Dart 侧没提供 `onPermissionRequest` 时插件收到 null，`*value` 就是空指针，
`variant::index()` 读偏移 0x40 → `0xc0000005`，进程直接闪退。

**任何申请权限的网站都会崩**，`bing.com` 不申请所以看起来正常，`juejin.cn`
申请传感器权限就必崩。和嗅探通道无关——把 CDP 和错误回调全关掉仍然照崩。

规避方式：Dart 侧接管 `onPermissionRequest`，**永远返回有效的
`PermissionResponse`**（本项目一律 DENY），见 `webview_host.dart`。

### 原生崩溃怎么排查

Dart 侧的日志和错误捕获看不到原生崩溃。`windows/runner/main.cpp` 里装了
`SetUnhandledExceptionFilter` + `MiniDumpWriteDump`，崩溃时在 exe 同目录生成
`crash_<时间戳>.dmp`。

配合构建产物里的 `.pdb` 和 `llvm-symbolizer` 就能还原到源码行：

```bash
llvm-symbolizer --obj=flutter_inappwebview_windows_plugin.dll 0x18007a88b
# → std::_Variant_base<...>::index()  variant:763
```

