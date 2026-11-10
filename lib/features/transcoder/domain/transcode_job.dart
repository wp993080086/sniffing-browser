import 'package:flutter/foundation.dart';

import '../../sniffer/domain/media_type.dart';

/// 转换类型。目前只有三种需求，不做过早抽象。
enum TranscodeKind {
  /// TS -> MP4，无损转封装。视频站点绝大多数是这条路。
  tsToMp4,

  /// 任意音频 -> MP3，有损重编码。
  audioToMp3,

  /// 视频轨 + 音频轨 -> 带声音的 MP4。DASH 站点（B 站等）专用。
  ///
  /// 和 [tsToMp4] 一样是纯流拷贝，几百 MB 也是秒级完成。
  /// 区别是它需要**两路输入**，所以不会出现在普通转码菜单里。
  dashMerge;

  String get label {
    switch (this) {
      case TranscodeKind.tsToMp4:
        return '转为 MP4';
      case TranscodeKind.audioToMp3:
        return '转为 MP3';
      case TranscodeKind.dashMerge:
        return '合并音视频';
    }
  }

  /// 输出容器扩展名。
  String get extension {
    switch (this) {
      case TranscodeKind.tsToMp4:
        return 'mp4';
      case TranscodeKind.audioToMp3:
        return 'mp3';
      case TranscodeKind.dashMerge:
        return 'mp4';
    }
  }

  /// 是否无损。无损转封装秒级完成，有损重编码要跑满 CPU。
  bool get isLossless => this != TranscodeKind.audioToMp3;

  /// 是否需要第二路输入。
  ///
  /// 需要第二路输入的任务由下载队列自动排期，不给用户手动入口
  /// —— 单独点一条音轨去「合并」必然因为缺另一路而失败。
  bool get needsSecondaryInput => this == TranscodeKind.dashMerge;

  /// 该媒体类型是否适用（手动转码入口用）。
  ///
  /// [hasAudio] 表示「这个文件确认带音轨吗」：
  /// - `true`：已知有（DASH 合并产物），视频容器也放行抽音频
  /// - `false`：已知没有（纯视频轨 m4s），不放行，免得点了必然失败
  /// - `null`：不知道，只有普通视频容器放行 —— 那种文件绝大多数自带音轨，
  ///   真碰上无声的会在转换时给出「文件里没有音轨」的明确结论
  bool appliesTo(MediaType type, String filePath, {bool? hasAudio}) {
    final String ext = filePath.toLowerCase();
    switch (this) {
      case TranscodeKind.tsToMp4:
        return ext.endsWith('.ts') ||
            ext.endsWith('.m2ts') ||
            // B 站的 `.m4s` 就是 fMP4 分片，流拷贝一下就变成能播的 mp4
            // （几百 MB 的视频也是秒级完成，不重编码）
            ext.endsWith('.m4s');
      case TranscodeKind.audioToMp3:
        if (ext.endsWith('.mp3')) return false; // 已经是目标格式
        if (type == MediaType.audio) return true;
        if (_audioExtensions.any(ext.endsWith)) return true;
        // `.m4s` 是 DASH 分片，单看后缀分不出音视频轨，只有确认带音轨才放行。
        if (ext.endsWith('.m4s')) return hasAudio == true;
        if (_videoContainers.any(ext.endsWith)) return hasAudio != false;
        return false;
      case TranscodeKind.dashMerge:
        return false;
    }
  }

  /// 纯音频容器。这些文件抽 MP3 是本职，不需要额外判断。
  static const List<String> _audioExtensions = <String>[
    '.m4a',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.opus',
    '.wma',
    '.amr',
  ];

  /// 视频容器。可能带音轨也可能不带，得看 [hasAudio]。
  static const List<String> _videoContainers = <String>[
    '.mp4',
    '.m4v',
    '.mov',
    '.mkv',
    '.webm',
    '.flv',
    '.avi',
    '.wmv',
    '.3gp',
    '.ts',
    '.m2ts',
  ];
}

enum TranscodeStatus {
  pending,
  running,
  completed,
  failed,
  canceled;

  String get label {
    switch (this) {
      case TranscodeStatus.pending:
        return '等待中';
      case TranscodeStatus.running:
        return '转换中';
      case TranscodeStatus.completed:
        return '已完成';
      case TranscodeStatus.failed:
        return '失败';
      case TranscodeStatus.canceled:
        return '已取消';
    }
  }

  bool get isFinished =>
      this == TranscodeStatus.completed ||
      this == TranscodeStatus.failed ||
      this == TranscodeStatus.canceled;
}

/// 一个转换任务。
///
/// 进度同样用独立 [ValueNotifier]，理由和 DownloadTask 一致。
class TranscodeJob {
  TranscodeJob({
    required this.id,
    required this.sourcePath,
    required this.outputPath,
    required this.kind,
    required this.createdAt,
    this.secondarySourcePath,
    this.sourceTaskId,
    this.displayName,
    this.replaceSource = false,
    this.onFinished,
  });

  final String id;
  final String sourcePath;
  final String outputPath;
  final TranscodeKind kind;
  final DateTime createdAt;

  /// 第二路输入，只有 [TranscodeKind.dashMerge] 用。
  final String? secondarySourcePath;

  /// 完成后用输出覆盖 [sourcePath] 并删掉中间文件。
  ///
  /// DASH 合并产出的 mp4 和源视频轨是「同一个作品的两个版本」，
  /// 留着两份会让用户看到两个同名文件，分不清哪个有声音。
  /// 覆盖比另存安全：下载任务持有的路径不变，导出、重试都不用改。
  final bool replaceSource;

  /// 结束（成功 / 失败 / 取消）时回调。队列在内部状态落定后调用，
  /// 让上层（下载队列）能跟着收尾，而不必去监听整个队列。
  final void Function(TranscodeStatus status)? onFinished;

  /// 关联的下载任务，用于在下载列表里回显“已转换”。
  final String? sourceTaskId;
  final String? displayName;

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<TranscodeStatus> statusNotifier =
      ValueNotifier<TranscodeStatus>(TranscodeStatus.pending);

  TranscodeStatus _status = TranscodeStatus.pending;
  TranscodeStatus get status => _status;

  String? error;

  /// 同 [DownloadTask]：进程还没退出时界面可能已经关掉，之后回调要静音。
  bool _disposed = false;

  void setStatus(TranscodeStatus next) {
    if (_disposed || _status == next) return;
    _status = next;
    statusNotifier.value = next;
  }

  void setProgress(double value) {
    if (_disposed) return;
    progress.value = value.clamp(0.0, 1.0);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    progress.dispose();
    statusNotifier.dispose();
  }
}
