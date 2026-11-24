/// 下载前可选的一条轨道。
///
/// HLS 的「清晰度」、DASH 的「视频轨 / 音轨」、HLS 的「字幕」在这里统一成
/// 一种东西：一条带 id 和展示名、能被用户点选的轨道。id 的含义由对应的下载器
/// 解释 —— HLS 是变体 playlist 的 URI（字幕则是字幕 playlist 的 URI），
/// DASH 是 Representation 的 id。
class TrackOption {
  const TrackOption({
    required this.id,
    required this.label,
    required this.group,
    this.tag,
  });

  final String id;
  final String label;
  final TrackGroup group;

  /// 写文件名用的短标记（如字幕的 `zh`）。只有字幕用得上。
  final String? tag;

  String get groupLabel => group.label;
}

enum TrackGroup {
  video,
  audio,
  subtitle;

  String get label => switch (this) {
    TrackGroup.video => '清晰度',
    TrackGroup.audio => '音轨',
    TrackGroup.subtitle => '字幕',
  };
}
