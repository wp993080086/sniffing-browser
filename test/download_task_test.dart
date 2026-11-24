import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

DownloadTask streamTask() => DownloadTask(
  id: 't1',
  mediaId: 'm1',
  url: 'https://example.com/video.m3u8',
  type: MediaType.hls,
  fileName: 'video.ts',
  createdAt: DateTime(2026, 11, 19),
  isStream: true,
);

void main() {
  group('分片进度', () {
    test('第一次回调就把总数记到任务上，列表才能显示 206/430', () {
      final DownloadTask task = streamTask();
      expect(task.totalSegments, isNull);

      task.updateSegments(206, 430);

      expect(task.segmentDone, 206);
      expect(task.totalSegments, 430);
      expect(task.progress.value, closeTo(206 / 430, 1e-9));
    });

    test('带字节时按已完成分片估算总大小', () {
      final DownloadTask task = streamTask();

      task.updateSegments(5, 10, bytes: 1024);

      expect(task.receivedBytes, 1024);
      expect(task.totalBytes, 2048);
      expect(task.progress.value, closeTo(0.5, 1e-9));
    });

    test('总数为 0 时只更新已完成数，不清掉已有总数', () {
      final DownloadTask task = streamTask()..updateSegments(10, 100);

      task.updateSegments(11, 0);

      expect(task.segmentDone, 11);
      expect(task.totalSegments, 100);
      expect(task.progress.value, closeTo(0.1, 1e-9));
    });

    test('dispose 之后的回调不抛异常也不改状态', () {
      final DownloadTask task = streamTask()..dispose();

      task.updateSegments(5, 10);

      expect(task.totalSegments, isNull);
      expect(task.segmentDone, 0);
    });
  });

  group('等待网络倒计时', () {
    test('按绝对死线反算剩余秒数，离开等待就清掉', () {
      final DownloadTask task = streamTask()
        ..waitForNetwork(const Duration(seconds: 10), reason: '站点拒绝访问');

      expect(task.status, DownloadStatus.waitingNetwork);
      expect(task.retryRemainingSeconds, inInclusiveRange(9, 10));
      expect(task.retryReason, '站点拒绝访问');

      task.setStatus(DownloadStatus.running);
      expect(task.retryAt, isNull);
      expect(task.retryReason, isNull);
      expect(task.retryRemainingSeconds, 0);
    });

    test('死线已过时剩余秒数为 0，不会出现负数', () {
      final DownloadTask task = streamTask()..waitForNetwork(Duration.zero);

      expect(task.retryRemainingSeconds, 0);
    });
  });
}
