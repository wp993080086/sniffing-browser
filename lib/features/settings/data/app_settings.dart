import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/proxy_rule.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/json_file.dart';
import 'site_rule.dart';

/// 下载完成后自动做的事。
///
/// 只给「几乎总要做」的几种，不做脚本化：用户点一次就到位的动作，比配置项
/// 堆一屏更有用。
enum AfterDownload {
  /// 只记录，用户自己决定下一步。
  nothing,

  /// 导出到系统媒体库（移动端）；桌面端文件本来就在下载目录，选了也是白拷一份。
  export,

  /// 转成 MP4。TS / m4s 才有意义，其余类型会自动跳过。
  toMp4,

  /// 抽成 MP3。没有音轨的文件会自动跳过。
  toMp3;

  String get label => switch (this) {
    AfterDownload.nothing => '不做任何操作',
    AfterDownload.export => '导出到系统媒体库',
    AfterDownload.toMp4 => '转为 MP4',
    AfterDownload.toMp3 => '提取为 MP3',
  };
}

/// 应用设置。
///
/// 落盘在应用私有根目录的 `settings.json`，和任务记录同级 —— 那是唯一不会被
/// 「清除缓存」顺手端掉的地方（见 `.agents/rules/02`）。
class AppSettings extends ChangeNotifier {
  AppSettings({File? file}) : _fileOverride = file;

  /// 测试用：直接指定文件，绕开 [StoragePaths] 的初始化要求。
  final File? _fileOverride;

  /// 分片并发的取值范围。
  ///
  /// 上限 12：再多收益很小，被 CDN 限流的概率反而明显上升；
  /// 下限 1：串行，给「一直被限流」的站点留一条能走通的路。
  static const int minSegmentConcurrency = 1;
  static const int maxSegmentConcurrency = 12;
  static const int defaultSegmentConcurrency = 6;

  File get file =>
      _fileOverride ?? File(p.join(StoragePaths.root.path, 'settings.json'));

  /// 启动时读一次环境变量：桌面端 `HTTP_PROXY` 之类的配置不该被忽略。
  final ProxyRule _envRule = ProxyRule.fromEnvironment();

  int _segmentConcurrency = defaultSegmentConcurrency;
  String _proxy = '';
  List<SiteRule> _siteRules = <SiteRule>[];
  AfterDownload _afterDownload = AfterDownload.nothing;
  bool _autoResume = true;
  bool _loaded = false;

  int get segmentConcurrency => _segmentConcurrency;

  /// 下载完成后自动做什么。
  AfterDownload get afterDownload => _afterDownload;

  /// 启动时自动继续上次没下完的任务。
  ///
  /// 默认开：用户按下下载就是希望文件到手，重启后还要勾一次纯属折腾。
  /// 关掉的意义在于不想在移动网络下被签名过期的任务刷一屏错误时能安静。
  bool get autoResume => _autoResume;

  /// 站点规则。按域名覆盖下载请求头，绝大多数站点不需要配。
  List<SiteRule> get siteRules => List<SiteRule>.unmodifiable(_siteRules);

  /// 手动代理，形如 `127.0.0.1:7890`。空表示不手动设。
  String get proxy => _proxy;

  /// 环境变量里读到的代理，设置页用它做提示。
  ProxyRule get envProxyRule => _envRule;

  /// 实际生效的代理：手动设置优先，其次环境变量。
  ProxyRule get proxyRule => _proxy.isEmpty
      ? _envRule
      : ProxyRule(proxy: _proxy, noProxy: _envRule.noProxy);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    final Map<String, Object?>? raw = await JsonFile.read(file, 'Settings');
    if (raw != null) {
      final Object? concurrency = raw['segmentConcurrency'];
      if (concurrency is int) {
        _segmentConcurrency = concurrency.clamp(
          minSegmentConcurrency,
          maxSegmentConcurrency,
        );
      }
      final Object? proxy = raw['proxy'];
      if (proxy is String) _proxy = proxy.trim();
      final Object? after = raw['afterDownload'];
      if (after is String) {
        for (final AfterDownload value in AfterDownload.values) {
          if (value.name == after) {
            _afterDownload = value;
            break;
          }
        }
      }
      final Object? resume = raw['autoResume'];
      if (resume is bool) _autoResume = resume;
      final Object? rules = raw['siteRules'];
      if (rules is List) {
        _siteRules = rules
            .whereType<Map<String, Object?>>()
            .map(SiteRule.fromJson)
            .where((SiteRule rule) => rule.isValid)
            .toList();
      }
    }

    final String effective = proxyRule.proxy;
    logInfo(
      'Settings',
      '分片并发 $_segmentConcurrency，'
          '代理 ${effective.isEmpty ? "直连" : effective}'
          '${effective.isNotEmpty && _proxy.isEmpty ? "（来自环境变量）" : ""}',
    );
    notifyListeners();
  }

  Future<void> setSegmentConcurrency(int value) async {
    final int next = value.clamp(minSegmentConcurrency, maxSegmentConcurrency);
    if (next == _segmentConcurrency) return;
    _segmentConcurrency = next;
    logInfo('Settings', '分片并发改为 $next');
    notifyListeners();
    await _save();
  }

  Future<void> setProxy(String value) async {
    final String next = value.trim();
    if (next == _proxy) return;
    _proxy = next;
    logInfo('Settings', '代理改为 ${next.isEmpty ? "直连" : next}');
    notifyListeners();
    await _save();
  }

  Future<void> setAfterDownload(AfterDownload value) async {
    if (value == _afterDownload) return;
    _afterDownload = value;
    logInfo('Settings', '完成后动作改为 ${value.label}');
    notifyListeners();
    await _save();
  }

  Future<void> setAutoResume(bool value) async {
    if (value == _autoResume) return;
    _autoResume = value;
    logInfo('Settings', '重启自动续传${value ? "开启" : "关闭"}');
    notifyListeners();
    await _save();
  }

  Future<void> setSiteRules(List<SiteRule> rules) async {
    _siteRules = rules
        .where((SiteRule rule) => rule.isValid)
        .map(
          (SiteRule rule) => SiteRule(
            domain: rule.domain.trim().toLowerCase(),
            userAgent: rule.userAgent.trim(),
            referer: rule.referer.trim(),
            headers: Map<String, String>.from(rule.headers),
          ),
        )
        .toList();
    logInfo('Settings', '站点规则改为 ${_siteRules.length} 条');
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await JsonFile.write(file, <String, Object?>{
      'version': 1,
      'segmentConcurrency': _segmentConcurrency,
      'proxy': _proxy,
      'afterDownload': _afterDownload.name,
      'autoResume': _autoResume,
      'siteRules': _siteRules.map((SiteRule r) => r.toJson()).toList(),
    }, 'Settings');
  }
}
