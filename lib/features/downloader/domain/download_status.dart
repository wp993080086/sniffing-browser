/// 下载任务状态机。
///
/// pending -> running -> completed
///                   -> failed -> running（重试）
///                   -> canceled
///         running -> paused -> running（续传）
enum DownloadStatus {
  pending,
  running,
  paused,
  completed,
  failed,
  canceled;

  String get label {
    switch (this) {
      case DownloadStatus.pending:
        return '等待中';
      case DownloadStatus.running:
        return '下载中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '失败';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }

  /// 占用并发槽位的状态。
  bool get isActive => this == DownloadStatus.running;

  /// 已经结束、不会再自动推进的状态。
  bool get isFinished =>
      this == DownloadStatus.completed ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.canceled;

  bool get canRetry =>
      this == DownloadStatus.failed || this == DownloadStatus.canceled;
}
