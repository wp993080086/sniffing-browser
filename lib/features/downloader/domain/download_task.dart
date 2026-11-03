import 'package:flutter/foundation.dart';

import '../../../core/platform/media_exporter.dart';
import '../../sniffer/domain/media_type.dart';
import 'download_status.dart';

/// 一个下载任务。
///
/// 设计上的一个关键取舍：进度用独立的 [ValueNotifier] 承载，而不是靠队列整体
/// 通知。否则每 100ms 推进度就会触发整个列表重建，低端机必然掉帧。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.mediaId,
    required this.url,
    required this.type,
    required this.fileName,
    required this.createdAt,
    this.pageUrl,
    this.headers = const <String, String>{},
    this.isStream = false,
    this.totalSegments,
    DownloadStatus status = DownloadStatus.pending,
  }) : _status = status;

  final String id;
  final String mediaId;
  final String url;
  final MediaType type;
  final String fileName;
  final DateTime createdAt;
  final String? pageUrl;
  final Map<String, String> headers;

  /// HLS / DASH 任务，进度按分片计而不是按字节。
  final bool isStream;
  final int? totalSegments;

  DownloadStatus _status;
  DownloadStatus get status => _status;

  int receivedBytes = 0;
  int? totalBytes;
  int segmentDone = 0;
  String? error;
  String? savedPath;
  String? container; // ts / mp4 / mp3 ...
  bool needsRemux = false;

  ExportStatus exportStatus = ExportStatus.notExported;

  /// 0.0 ~ 1.0。未知总大小时保持 0，UI 用不确定进度条。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  /// 瞬时速度，字节/秒。
  final ValueNotifier<double> speed = ValueNotifier<double>(0);

  final ValueNotifier<DownloadStatus> statusNotifier =
      ValueNotifier<DownloadStatus>(DownloadStatus.pending);

  void setStatus(DownloadStatus next) {
    if (_status == next) return;
    _status = next;
    statusNotifier.value = next;
  }

  void updateBytes(int received, int? total) {
    receivedBytes = received;
    totalBytes = total ?? totalBytes;
    if (totalBytes != null && totalBytes! > 0) {
      progress.value = (received / totalBytes!).clamp(0.0, 1.0);
    }
  }

  void updateSegments(int done, int total) {
    segmentDone = done;
    if (total <= 0) return;
    progress.value = (done / total).clamp(0.0, 1.0);
  }

  void fail(String message) {
    error = message;
    setStatus(DownloadStatus.failed);
    speed.value = 0;
  }

  void complete(String path, {String? containerExt}) {
    savedPath = path;
    container = containerExt;
    progress.value = 1;
    speed.value = 0;
    setStatus(DownloadStatus.completed);
  }

  void dispose() {
    progress.dispose();
    speed.dispose();
    statusNotifier.dispose();
  }
}
