import '../../../core/utils/site.dart';

/// 一次顶层导航的处置结论。
enum NavVerdict {
  /// 正常导航，当前页跳过去。
  allow,

  /// 该跳的地方，但不在当前页开 —— 后台新开一个页签，当前页原地不动。
  ///
  /// 用来替代「拦下」：拦截会让用户点了没反应；隔离既不打断当前页
  /// （滚动位置、播放进度都还在），也不给广告站改掉来源页的机会。
  isolate,
}

/// 顶层导航该不该在当前页放行。
///
/// 单看 `NavigationAction.hasGesture` 不够：Android 上「点链接→脚本中转→
/// 跳转」是常态（搜索结果页全是这种），这条链路里 `hasGesture` 是 `false`，
/// 照它判会把正常点击一起隔离掉。所以要结合页面自己上报的点击：
///
/// - 页面记录了点击，且点的是链接、目标与那个链接同站 → 用户想去，放行；
/// - 页面记录了点击，但点的是按钮 / div（没有链接）→ 给**一次**机会，
///   正常站点的 `button + JS 跳转` 能过，popunder 的第二跳被隔离；
/// - 页面记录了点击，目标是别的站 → 劫持，隔离；
/// - 完全没有点击（定时器、`window.location`、`meta refresh`）且跨站 → 隔离；
/// - 同站的弹窗中转页（`/pop?url=<外站>`）→ 隔离，否则当前页被顶成空壳。
class NavGuard {
  /// 点击之后多久内算「这次点击引起的导航」。
  static const Duration gestureWindow = Duration(milliseconds: 1500);

  String _tappedHref = '';
  int _tappedAtMs = 0;

  /// 本次点击的「一跳机会」是否已经用掉。
  bool _hopUsed = true;

  /// 记一次页面内的真实点击。[href] 为空表示点的不是链接。
  void noteTap({required String href, required int atMs}) {
    _tappedHref = href;
    _tappedAtMs = atMs;
    _hopUsed = false;
  }

  NavVerdict decide({
    required String url,
    required String? currentUrl,
    required bool hasUserGesture,
    required bool enabled,
    required int nowMs,
  }) {
    // 关掉隔离：全部在当前页放行。服务器重定向（302）由调用方提前放行，
    // 不进这里 —— 跳到哪儿是站点自己的决定，重新判定只会把登录 / 短链拆坏。
    if (!enabled) return NavVerdict.allow;

    // 弹窗中转页在站内判定的分支之前：它跟当前页同站，走不到后面。
    if (_isPopupBridge(url)) return NavVerdict.isolate;

    // 站内跳转一律放行。任何一方解析不出主机名时 isSameSite 也返回 true。
    if (isSameSite(url, currentUrl ?? '')) return NavVerdict.allow;

    final int delta = nowMs - _tappedAtMs;
    final bool recentTap =
        _tappedAtMs > 0 && delta >= 0 && delta <= gestureWindow.inMilliseconds;

    // 原生说有点击，页面却没上报（脚本还没注入 / 点了视频控件）：
    // 拿不准就放行，误隔离比漏隔离难收拾。
    if (hasUserGesture && !recentTap) return NavVerdict.allow;

    if (!recentTap) return NavVerdict.isolate;

    if (_tappedHref.isNotEmpty) {
      // 点的就是链接：目标跟它同站才认。
      if (isSameSite(url, _tappedHref)) {
        _hopUsed = true;
        return NavVerdict.allow;
      }
      return NavVerdict.isolate;
    }

    // 点的不是链接，只能给一跳的机会。
    if (!_hopUsed) {
      _hopUsed = true;
      return NavVerdict.allow;
    }
    return NavVerdict.isolate;
  }

  /// 同站的「弹窗中转页」：路径带 pop，查询串里的 `url` 指向别的站。
  ///
  /// 视频站的做法是脚本把当前页跳到 `/pop?url=<广告地址>`，再由那一页
  /// 跳广告。只看站点关系这里是「站内跳转」，放行就等于把当前页送出去。
  bool _isPopupBridge(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!uri.path.toLowerCase().contains('pop')) return false;
    final String? target = uri.queryParameters['url'];
    if (target == null || target.isEmpty) return false;
    return !isSameSite(target, url);
  }
}
