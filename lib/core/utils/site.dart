/// 「是不是同一个站点」的判断。
///
/// 只做一件事：把主机名收敛到注册域再比较，用来区分「站内跳转」和
/// 「跳到第三方」。广告弹窗（popunder）一定跨站，正常的站内跳转基本不跨站，
/// 这是拦截自动跳转时唯一可靠的信号 —— 脚本发起的 `location.href` 拿不到
/// 用户手势，只看手势会把登录跳转也一起拦掉。
library;

/// 常见的两级公共后缀。不求完整（那需要一个 PSL 数据库），
/// 只覆盖中文站点常见的那几个，判错时的后果是「按站点不同处理」，不影响主流程。
const Set<String> _twoLevelSuffixes = <String>{
  'com.cn',
  'net.cn',
  'org.cn',
  'gov.cn',
  'edu.cn',
  'co.uk',
  'org.uk',
  'ac.uk',
  'co.jp',
  'ne.jp',
  'or.jp',
  'com.tw',
  'org.tw',
  'com.hk',
  'org.hk',
  'com.au',
  'net.au',
  'co.kr',
  'com.br',
  'com.sg',
};

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// 同一个站点的两个地址返回 true。
///
/// 任意一方解析不出主机名时返回 true —— 拿不准就不拦，比误拦好。
bool isSameSite(String a, String b) {
  final String? ka = _siteKey(a);
  final String? kb = _siteKey(b);
  if (ka == null || kb == null) return true;
  return ka == kb;
}

String? _siteKey(String url) {
  final String host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;

  // IP 直接整体比较，套「最后两段」会把 1.1 当成站名。
  if (_ipv4.hasMatch(host) || host.contains(':')) return host;

  final List<String> parts = host.split('.');
  if (parts.length <= 2) return host;

  final String lastTwo = parts.sublist(parts.length - 2).join('.');
  if (_twoLevelSuffixes.contains(lastTwo) && parts.length >= 3) {
    return parts.sublist(parts.length - 3).join('.');
  }
  return lastTwo;
}
