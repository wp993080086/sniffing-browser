import '../../sniffer/data/sniffer_service.dart';
import 'browser_provider.dart';

/// 一个页签：独立的网页状态 + 独立的嗅探结果。
///
/// 嗅探列表跟着页签走，不是全局一份 —— 在 A 页抓到的资源，切到 B 再切回来
/// 还在。代价是每个页签一份 [SnifferService]，但它只存 URL 和请求头
/// （上限 800 条），相比一个 WebView 实例的内存可以忽略。
class BrowserTab {
  BrowserTab({
    required this.id,
    String? url,
    this.spawnedInBackground = false,
    this.pinned = false,
  }) : pendingUrl = url {
    if (url != null && url.isNotEmpty) {
      page.markExternal(url);
    }
  }

  /// 稳定标识，同时用作 `IndexedStack` 子节点的 key。
  final String id;

  /// 常驻起始页。
  ///
  /// 内容和普通页签不同 —— 它是 Flutter 画的，底下没有 WebView，也不需要
  /// `pendingUrl`。不能被关闭，访问地址时也不会被就地替换：地址进的是新建的
  /// 普通页签，起始页留在原地。
  final bool pinned;

  /// 这个页签的网页状态（URL / 标题 / 前进后退 / 加载态）。
  final BrowserController page = BrowserController();

  /// 这个页签的嗅探结果。
  final SnifferService sniffer = SnifferService();

  /// WebView 创建时加载的地址。
  ///
  /// 新建页签时是外部传进来的 URL；页签休眠（WebView 被回收）时记下当前地址，
  /// 重新激活后用它恢复现场。为空表示自写首页。
  String? pendingUrl;

  /// 最近一次成为活跃页签的时间，用于 LRU 淘汰。
  DateTime lastActive = DateTime.now();

  /// 这个页签是被「弹窗隔离」自动开出来的（用户没主动点）。
  ///
  /// 用来自我抑制：广告落地页自己还会继续跳，如果那边也开新页签，
  /// 一次点击能裂变出十几个后台页签。后台页签里的可疑跳转直接丢弃。
  final bool spawnedInBackground;

  /// 卡片和地址栏上显示的名字。没标题就退回域名。
  String get displayTitle {
    final String title = page.title.trim();
    if (title.isNotEmpty) return title;
    final String host = displayHost;
    return host.isEmpty ? '新页签' : host;
  }

  String get displayHost {
    final String url = page.currentUrl;
    if (url.isEmpty) return '';
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return '';
    return uri.host.isEmpty ? url : uri.host;
  }
}
