import 'package:flutter/foundation.dart';

import '../../sniffer/domain/media_type.dart';

/// 转换类型。目前只有两种需求，不做过早抽象。
enum TranscodeKind {
  /// TS -> MP4，无损转封装。视频站点绝大多数是这条路。
  tsToMp4,

  /// 任意音频 -> MP3，有损重编码。
  audioToMp3;

  String get label {
    switch (this) {
      case TranscodeKind.tsToMp4:
        return '转为 MP4';
      case TranscodeKind.audioToMp3:
        return '转为 MP3';
    }
  }

  /// 输出容器扩展名。
  String get extension {
    switch (this) {
      case TranscodeKind.tsToMp4:
        return 'mp4';
      case TranscodeKind.audioToMp3:
        return 'mp3';
    }
  }

  /// 是否无损。无损转封装秒级完成，有损重编码要跑满 CPU。
  bool get isLossless => this == TranscodeKind.tsToMp4;

  /// 该媒体类型是否适用。
  bool appliesTo(MediaType type, String filePath) {
    final String ext = filePath.toLowerCase();
    switch (this) {
      case TranscodeKind.tsToMp4:
        return ext.endsWith('.ts') || ext.endsWith('.m2ts');
      case TranscodeKind.audioToMp3:
        if (ext.endsWith('.mp3')) return false; // 已经是目标格式
        return type == MediaType.audio ||
            ext.endsWith('.m4a') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.flac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.opus');
    }
  }
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
    this.sourceTaskId,
    this.displayName,
  });

  final String id;
  final String sourcePath;
  final String outputPath;
  final TranscodeKind kind;
  final DateTime createdAt;

  /// 关联的下载任务，用于在下载列表里回显“已转换”。
  final String? sourceTaskId;
  final String? displayName;

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<TranscodeStatus> statusNotifier =
      ValueNotifier<TranscodeStatus>(TranscodeStatus.pending);

  TranscodeStatus _status = TranscodeStatus.pending;
  TranscodeStatus get status => _status;

  String? error;

  void setStatus(TranscodeStatus next) {
    if (_status == next) return;
    _status = next;
    statusNotifier.value = next;
  }

  void dispose() {
    progress.dispose();
    statusNotifier.dispose();
  }
}
