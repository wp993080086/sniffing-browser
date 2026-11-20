/// 下载任务状态机。
///
/// pending -> running -> completed
///                   -> failed -> running（重试）
///                   -> canceled
///                   -> waitingNetwork -> running（网络恢复后自动续传）
///         running -> paused -> running（续传）
enum DownloadStatus {
  pending,
  running,

  /// 网络断了，任务**没有失败**：队列在等网络恢复，然后从断点续传。
  ///
  /// 和 failed 的区别是「用户要不要动手」：这个状态不需要，等就行；
  /// 但界面上必须看得见，否则进度冻住会像卡死。
  waitingNetwork,
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
      case DownloadStatus.waitingNetwork:
        return '等待网络';
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

  /// 还没结束、可以取消。等待网络也算：用户随时可以放弃这条任务。
  bool get isRunningOrWaiting =>
      this == DownloadStatus.running ||
      this == DownloadStatus.waitingNetwork;

  /// 已经结束、不会再自动推进的状态。
  bool get isFinished =>
      this == DownloadStatus.completed ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.canceled;

  bool get canRetry =>
      this == DownloadStatus.failed || this == DownloadStatus.canceled;
}
