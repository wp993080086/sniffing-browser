import 'resolved_video.dart';

/// 一批解析结果。
///
/// 抖音的主页 / 图集接口会一次吐出多条 aweme，hook 逐条回传；这个集合负责
/// 去重和勾选状态。单独抽出来是为了不把「按 videoId 还是 url 去重」这类规则
/// 埋在 StatefulWidget 里 —— 那东西没法单测，改一次就要真机跑一次。
class ResolvedBatch {
  final List<ResolvedVideo> _videos = <ResolvedVideo>[];

  /// 勾选状态按 key 存，新增默认勾选。
  final Set<String> _selected = <String>{};

  static String keyOf(ResolvedVideo video) =>
      video.videoId.isNotEmpty ? video.videoId : video.url;

  List<ResolvedVideo> get videos => List<ResolvedVideo>.unmodifiable(_videos);

  List<ResolvedVideo> get selected => _videos
      .where((ResolvedVideo v) => _selected.contains(keyOf(v)))
      .toList();

  bool get isEmpty => _videos.isEmpty;
  bool get isSelectedAll =>
      _videos.isNotEmpty && _selected.length == _videos.length;

  /// 加入一条。已存在（同 videoId 或同 url）时返回 false，不重复展示。
  bool add(ResolvedVideo video) {
    if (!video.isUsable) return false;
    final String key = keyOf(video);
    if (_selected.contains(key) ||
        _videos.any((ResolvedVideo v) => keyOf(v) == key)) {
      return false;
    }
    _videos.add(video);
    _selected.add(key);
    return true;
  }

  bool isSelected(ResolvedVideo video) => _selected.contains(keyOf(video));

  void toggle(ResolvedVideo video) {
    final String key = keyOf(video);
    if (!_selected.remove(key)) _selected.add(key);
  }

  void selectAll(bool value) {
    if (value) {
      _selected.addAll(_videos.map(keyOf));
    } else {
      _selected.clear();
    }
  }

  void clear() {
    _videos.clear();
    _selected.clear();
  }
}
