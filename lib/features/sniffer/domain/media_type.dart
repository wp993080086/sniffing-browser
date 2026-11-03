/// 媒体类型。只保留这个项目真正会处理的东西，其余一律归到 [other]。
enum MediaType {
  image,
  audio,
  video,
  hls,
  dash,
  other;

  String get label {
    switch (this) {
      case MediaType.image:
        return '图片';
      case MediaType.audio:
        return '音频';
      case MediaType.video:
        return '视频';
      case MediaType.hls:
        return 'HLS 流';
      case MediaType.dash:
        return 'DASH 流';
      case MediaType.other:
        return '其他';
    }
  }

  /// 是否是需要二次请求的流媒体（playlist 而非单文件）。
  bool get isStream => this == MediaType.hls || this == MediaType.dash;

  /// 是否可下载。
  bool get isDownloadable => this != MediaType.other;

  /// 默认导出容器扩展名。
  String get defaultExtension {
    switch (this) {
      case MediaType.image:
        return 'jpg';
      case MediaType.audio:
        return 'mp3';
      case MediaType.video:
        return 'mp4';
      case MediaType.hls:
        // HLS 合并后的默认容器。TS 源会额外提供转 MP4 入口。
        return 'ts';
      case MediaType.dash:
        return 'mp4';
      case MediaType.other:
        return 'bin';
    }
  }
}
