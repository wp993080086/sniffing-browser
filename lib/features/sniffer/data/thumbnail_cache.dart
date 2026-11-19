import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../../core/logging/app_log.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';

/// 缩略图加载函数。
///
/// 抽成函数类型是为了测试：缓存 / 去重 / 淘汰这些逻辑不该依赖网络和原生通道。
typedef ThumbnailLoader = Future<Uint8List?> Function(MediaItem item);

/// 嗅探列表的缩略图缓存。
///
/// 只放内存，不落盘：嗅探结果本身不持久化，重启后列表就空了，
/// 为一批「下次一定用不上」的图写磁盘得不偿失。
///
/// 三个约束都是为了避免列表滚动把网络和内存打爆：
/// - 同一 id 的请求合并成一个 Future，滚动回来不会重复发起；
/// - 并发上限 [maxConcurrent]，几十条资源不会一起冲出去；
/// - 失败结论也记下来（值是 null），滚回原处不再重试。
class ThumbnailCache {
  ThumbnailCache({
    required ThumbnailLoader loader,
    this.maxEntries = 120,
    this.maxConcurrent = 3,
    this.maxQueued = 8,
    this.timeout = const Duration(seconds: 12),
  }) : _loader = loader;

  final ThumbnailLoader _loader;

  /// 最多保留多少条结论（含失败）。一张 160px 的 PNG 大约 20~60 KB，
  /// 120 条的上限在手机上也就几 MB。
  final int maxEntries;
  final int maxConcurrent;

  /// 排队上限。快速滚动时会一下子入队几十条，超过就先不给图 ——
  /// 一路滚到底等于把整页原图全下下来，手机上这流量和内存都不划算。
  /// 跳过不算失败，下次重建还会再试。
  final int maxQueued;

  /// 单张图的等待上限。超时就当没有缩略图，不能让它一直占着并发额度。
  final Duration timeout;

  /// 值可能是 null —— null 表示「确认取不到」，和「还没加载」区分开。
  final LinkedHashMap<String, Uint8List?> _entries =
      LinkedHashMap<String, Uint8List?>();
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  final Queue<Completer<bool>> _waiters = Queue<Completer<bool>>();

  int _running = 0;

  /// 只有图片和视频有缩略图；音频、HLS、DASH 拿不到有意义的封面，保持类型图标。
  bool supports(MediaType type) =>
      type == MediaType.image || type == MediaType.video;

  /// 取一张缩略图。不可用的类型直接返回 null，调用方据此退回图标。
  Future<Uint8List?> get(MediaItem item) {
    if (!supports(item.type)) return Future<Uint8List?>.value(null);

    if (_entries.containsKey(item.id)) {
      final Uint8List? cached = _entries.remove(item.id);
      // 重新插到队尾，队首就是最久没被用到的。
      _entries[item.id] = cached;
      return Future<Uint8List?>.value(cached);
    }

    final Future<Uint8List?>? pending = _inFlight[item.id];
    if (pending != null) return pending;

    final Future<Uint8List?> task = _load(item);
    _inFlight[item.id] = task;
    return task;
  }

  /// 同步读已缓存的结论，拿不到就是 null。
  ///
  /// 给 `FutureBuilder` 当 initialData：滚回已加载过的条目时直接出图，
  /// 不闪一帧图标。
  Uint8List? peek(String id) => _entries[id];

  /// 当前缓存条数（含失败结论），测试用。
  int get cachedCount => _entries.length;

  Future<Uint8List?> _load(MediaItem item) async {
    final Stopwatch watch = Stopwatch()..start();
    final bool granted = await _acquire();
    if (!granted) {
      // 排队已满，这一轮先不给图。不留结论，滚回来还能再试。
      _inFlight.remove(item.id);
      logDebug('Thumb', '排队已满，跳过 ${_describe(item)}');
      return null;
    }

    Uint8List? bytes;
    try {
      bytes = await _loader(item).timeout(timeout);
    } on TimeoutException {
      logWarn('Thumb', '缩略图超时 ${_describe(item)}');
      bytes = null;
    } catch (e, s) {
      // 缩略图是锦上添花，失败不影响主流程，但日志要留下原因。
      logWarn('Thumb', '缩略图失败 ${_describe(item)}: $e\n$s');
      bytes = null;
    } finally {
      _release();
    }

    _remember(item.id, bytes);
    _inFlight.remove(item.id);
    if (bytes != null) {
      logDebug(
        'Thumb',
        '缩略图就绪 ${_describe(item)} '
            '${bytes.length}B ${watch.elapsedMilliseconds}ms',
      );
    }
    return bytes;
  }

  void _remember(String id, Uint8List? bytes) {
    _entries.remove(id);
    _entries[id] = bytes;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  Future<bool> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return true;
    }
    if (_waiters.length >= maxQueued) return false;
    final Completer<bool> waiter = Completer<bool>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // 名额直接转交，_running 不变。
      _waiters.removeFirst().complete(true);
      return;
    }
    _running--;
  }

  String _describe(MediaItem item) {
    final String name = item.fileName ?? item.url;
    return name.length > 80 ? '${name.substring(0, 80)}…' : name;
  }
}
