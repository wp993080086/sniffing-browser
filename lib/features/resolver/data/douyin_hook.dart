/// 抖音网页版的注入脚本与链接识别。
///
/// 为什么是「注入脚本读页面」而不是「自己请求接口」：
///
/// 抖音的 `/aweme/v1/web/aweme/detail/` 要求 `a_bogus` + `msToken` + `verifyFp`
/// 三个签名参数，算法在 `webmssdk.js` 里，隔一阵就换。但**页面自己每次都会
/// 带着合法签名去请求**，我们只需要在它拿到响应时读一眼，签名归它管。
///
/// 拿到的 `video.play_addr.url_list[0]` 是完整 mp4 直链（`mime_type=video_mp4`），
/// 不是 DASH 分片，所以直接喂给现有的分片下载器就能 Range 续传。
///
/// 三条通道并行，任一命中即可：
///
/// | 通道 | 命中场景 |
/// | --- | --- |
/// | `fetch` / `XMLHttpRequest` | PC 网页版，详情接口的 JSON 响应 |
/// | `window._ROUTER_DATA` 等 | 分享页（`iesdouyin.com/share/video/...`）的内联 SSR 数据 |
/// | 页面内对象遍历 | 兜底，应对字段被挪到别的全局对象里 |
class DouyinHook {
  const DouyinHook._();

  /// JS -> Dart 的回调通道名，注册在解析页的 WebView 上。
  static const String channel = 'sb_douyin';

  /// 从分享文案里挑链接的规则。
  ///
  /// 分享出来的是一整段话（`7.42 复制打开抖音，看看【...】 https://v.douyin.com/xxx/
  /// 复制此链接...`），所以不能整段当 URL。这里按「非空白、非中文、非中文标点」
  /// 截取，中文部分自然断开。
  static final RegExp _urlPattern = RegExp(
    r'''https?://[^\s\u4e00-\u9fa5，。、；：！？（）【】《》“”‘’"']+''',
    caseSensitive: false,
  );

  /// 链接尾部常粘着 `)` `,` `.` 这类英文标点，要剥掉。
  static final RegExp _trailingJunk = RegExp(r'''[)\].,;:!?"']+$''');

  /// 未带协议的裸域名，例如用户手动输入的 `v.douyin.com/iRxxxx/`。
  static final RegExp _bareDouyin = RegExp(
    r'^(?:[a-z0-9-]+\.)*(?:douyin|iesdouyin)\.com/\S*$',
    caseSensitive: false,
  );

  /// 视频 id。`/video/` 和图文 `/note/` 都算。
  static final RegExp _idPattern = RegExp(r'/(?:video|note|slides)/(\d{8,})');

  /// 从一段文本里取出可用的抖音链接。取不到返回 null。
  ///
  /// 只认抖音域名：粘个 B 站链接进来也能提取出 URL，但后面必然解析失败，
  /// 不如在这里就判掉，界面能直接说「没找到抖音链接」。
  static String? extractUrl(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;

    for (final RegExpMatch match in _urlPattern.allMatches(text)) {
      final String url = match.group(0)!.replaceAll(_trailingJunk, '');
      if (isDouyinUrl(url)) return url;
    }

    if (_bareDouyin.hasMatch(text)) return 'https://$text';
    return null;
  }

  static bool isDouyinUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    final String host = uri.host.toLowerCase();
    return host == 'douyin.com' ||
        host.endsWith('.douyin.com') ||
        host == 'iesdouyin.com' ||
        host.endsWith('.iesdouyin.com');
  }

  /// 从链接里抠出视频 id。短链（`v.douyin.com/xxx`）没有 id，返回 null。
  static String? awemeId(String url) =>
      _idPattern.firstMatch(url)?.group(1);

  /// 分享页地址。详情接口要求登录 / 触发验证时，这条 SSR 路线往往还能走通。
  static String shareUrl(String awemeId) =>
      'https://www.iesdouyin.com/share/video/$awemeId/';

  /// 注入脚本。用 [UserScriptInjectionTime.AT_DOCUMENT_START] 注入：
  /// 晚于文档开始的话，首屏那次详情请求已经发出去了，hook 装不上。
  static const String script =
      '''
(function () {
  if (window.__sbDy) return 'skip';
  window.__sbDy = true;

  var seen = {};

  function report(o) {
    if (!o || !o.url) return;
    var key = o.id || o.url;
    if (seen[key]) return;
    seen[key] = 1;
    try {
      window.flutter_inappwebview.callHandler('sb_douyin', JSON.stringify(o));
    } catch (e) {}
  }

  function pick(a) {
    if (!a || !a.video) return null;
    var v = a.video;
    var play = (v.play_addr && v.play_addr.url_list) || [];
    var dl = (v.download_addr && v.download_addr.url_list) || [];
    var url = play[0] || dl[0];
    if (!url) return null;
    var cover = '';
    var c = v.cover || v.origin_cover || v.dynamic_cover;
    if (c && c.url_list && c.url_list.length) cover = c.url_list[0];
    return {
      url: url,
      title: a.desc ? String(a.desc) : '',
      author: (a.author && a.author.nickname) ? String(a.author.nickname) : '',
      cover: cover,
      size: (v.play_addr && v.play_addr.data_size) || 0,
      duration: v.duration || 0,
      id: a.aweme_id ? String(a.aweme_id) : ''
    };
  }

  function handle(data) {
    if (!data || typeof data !== 'object') return;
    if (data.aweme_detail) {
      var one = pick(data.aweme_detail);
      if (one) report(one);
    }
    var list = data.aweme_list;
    if (list && list.length) {
      for (var i = 0; i < list.length; i++) {
        var item = pick(list[i]);
        if (item) report(item);
      }
    }
  }

  var budget = 0;

  function scan(node, depth) {
    if (!node || budget <= 0 || depth > 8) return;
    if (typeof node !== 'object') return;
    budget--;
    if (node.aweme_detail) handle({ aweme_detail: node.aweme_detail });
    if (node.aweme_list) handle({ aweme_list: node.aweme_list });
    if (node.video && node.video.play_addr) {
      var one = pick(node);
      if (one) report(one);
    }
    for (var k in node) {
      if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
      var child = node[k];
      if (child && typeof child === 'object') scan(child, depth + 1);
    }
  }

  function scanGlobals() {
    var keys = ['_ROUTER_DATA', '_SSR_HYDRATED_DATA', 'RENDER_DATA', '__INITIAL_STATE__'];
    for (var i = 0; i < keys.length; i++) {
      var d = null;
      try { d = window[keys[i]]; } catch (e) { continue; }
      if (!d) continue;
      if (typeof d === 'string') {
        try { d = JSON.parse(decodeURIComponent(d)); } catch (e2) { continue; }
      }
      budget = 30000;
      scan(d, 0);
    }
    return 'ok';
  }

  window.__sbDyScan = scanGlobals;

  var rawFetch = window.fetch;
  if (rawFetch) {
    window.fetch = function (input) {
      var p = rawFetch.apply(this, arguments);
      var u = '';
      try {
        if (typeof input === 'string') u = input;
        else if (input && input.url) u = input.url;
      } catch (e) {}
      if (u && u.indexOf('/aweme/') >= 0) {
        p.then(function (res) {
          try { res.clone().json().then(handle).catch(function () {}); } catch (e) {}
        }).catch(function () {});
      }
      return p;
    };
  }

  var rawOpen = XMLHttpRequest.prototype.open;
  var rawSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__sbUrl = url;
    return rawOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    if (String(xhr.__sbUrl || '').indexOf('/aweme/') >= 0) {
      xhr.addEventListener('load', function () {
        try {
          if (xhr.responseType === 'json') handle(xhr.response);
          else if (!xhr.responseType || xhr.responseType === 'text') {
            handle(JSON.parse(xhr.responseText));
          }
        } catch (e) {}
      });
    }
    return rawSend.apply(this, arguments);
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      setTimeout(scanGlobals, 300);
    });
  } else {
    setTimeout(scanGlobals, 0);
  }
  window.addEventListener('load', function () { setTimeout(scanGlobals, 500); });
  setTimeout(scanGlobals, 1500);
  setTimeout(scanGlobals, 3500);

  return 'ok';
})();
''';

  /// 页面加载完成后补扫一次。有些站点的 SSR 数据在 hydration 之后才挂到 window。
  static const String rescan =
      r'window.__sbDyScan ? window.__sbDyScan() : null;';
}
