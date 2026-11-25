import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/media_exporter.dart';
import 'package:sniffingbrowser/core/platform/storage_paths.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_type.dart';
import 'package:sniffingbrowser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffingbrowser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffingbrowser/features/transcoder/domain/transcode_job.dart';

/// 只负责「产出文件」的假引擎，不碰真实 ffmpeg。
class _FakeEngine extends TranscodeEngine {
  int runs = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double progress) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  }) async {
    runs++;
    onProgress(0.5);
    await File(outputPath).writeAsBytes(<int>[0, 1, 2, 3]);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  late Directory root;

  setUpAll(() async {
    root = Directory('${Directory.systemTemp.path}/sniffing-export-test');
    if (await root.exists()) await root.delete(recursive: true);
    await StoragePaths.initWithRoot(root);
  });

  Future<File> sourceFile(String name) async {
    final File file = File('${root.path}/$name');
    await file.writeAsBytes(<int>[9, 9, 9]);
    return file;
  }

  /// 入队并等到任务终态，返回任务本身。
  Future<TranscodeJob> runToEnd(
    TranscodeQueue queue,
    String path, {
    TranscodeKind kind = TranscodeKind.audioToMp3,
  }) async {
    final Completer<void> settled = Completer<void>();
    final TranscodeJob job = queue.enqueue(
      sourcePath: path,
      kind: kind,
      onFinished: (TranscodeStatus _) {
        // 重试会让同一个任务再触发一次回调，已完成的 Completer 不能重复 complete。
        if (!settled.isCompleted) settled.complete();
      },
    );
    await settled.future;
    return job;
  }

  test('移动端转换完成后把产物写进系统媒体库', () async {
    final File source = await sourceFile('movie.mp4');
    final List<String> calledWith = <String>[];
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async {
            calledWith.add('$type|$displayName');
            return const ExportResult(
              ExportStatus.done,
              targetPath: 'content://media/external/audio/media/7',
              message: '已保存到「音乐/SniffingBrowser」',
            );
          },
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(queue, source.path);

    expect(job.status, TranscodeStatus.completed);
    expect(calledWith, hasLength(1));
    // MP3 走音乐目录，文件名取自产物（源名 + .mp3）
    expect(calledWith.single, 'MediaType.audio|movie.mp3');
    expect(job.exported, isTrue);
    expect(job.exportMessage, '已保存到「音乐/SniffingBrowser」');
    // 入库 URI 留着给「打开产物」用
    expect(job.mediaUri, 'content://media/external/audio/media/7');
  });

  test('MP4 转封装入库按视频类型走', () async {
    final File source = await sourceFile('clip.ts');
    MediaType? seen;
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async {
            seen = type;
            return const ExportResult(
              ExportStatus.done,
              message: '已保存到「视频/SniffingBrowser」',
            );
          },
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(
      queue,
      source.path,
      kind: TranscodeKind.tsToMp4,
    );

    expect(seen, MediaType.video);
    expect(job.exportMessage, '已保存到「视频/SniffingBrowser」');
  });

  test('入库失败不把转换判成失败，只给出原因', () async {
    final File source = await sourceFile('song.m4a');
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async =>
              const ExportResult(ExportStatus.failed, message: '无法在媒体库创建条目'),
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(queue, source.path);

    // 产物本身是好的，只是没入库 —— 任务仍算完成
    expect(job.status, TranscodeStatus.completed);
    expect(job.error, isNull);
    expect(job.exported, isFalse);
    expect(job.exportMessage, contains('没能存入系统媒体库'));
    expect(job.exportMessage, contains('无法在媒体库创建条目'));
    // 没入库就没有可打开的媒体库地址，退回让用户从下载目录找
    expect(job.mediaUri, isNull);
  });

  test('入境器抛异常也被吞住，不影响任务终态', () async {
    final File source = await sourceFile('boom.m4a');
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async => throw const FileSystemException('磁盘满了'),
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(queue, source.path);

    expect(job.status, TranscodeStatus.completed);
    expect(job.exported, isFalse);
    expect(job.exportMessage, contains('保存到媒体库失败'));
  });

  test('桌面（不入库）不调用导出器', () async {
    final File source = await sourceFile('desktop.mp4');
    int calls = 0;
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: false,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async {
            calls++;
            return const ExportResult(ExportStatus.done);
          },
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(queue, source.path);

    expect(job.status, TranscodeStatus.completed);
    expect(calls, 0);
    expect(job.exportMessage, isNull);
  });

  test('DASH 合并产物覆盖源文件，不走入库', () async {
    final File video = await sourceFile('video.m4s');
    final File audio = await sourceFile('audio.m4s');
    final File produced = StoragePaths.uniqueFile('merged.mp4');
    int calls = 0;

    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async {
            calls++;
            return const ExportResult(ExportStatus.done);
          },
    );
    addTearDown(queue.dispose);

    final Completer<void> settled = Completer<void>();
    queue.enqueue(
      sourcePath: video.path,
      kind: TranscodeKind.dashMerge,
      secondarySourcePath: audio.path,
      outputPath: produced.path,
      replaceSource: true,
      onFinished: (TranscodeStatus _) => settled.complete(),
    );
    await settled.future;

    expect(calls, 0);
    // 成品被挪回源路径，中间音频轨删除
    expect(await File(video.path).readAsBytes(), <int>[0, 1, 2, 3]);
    expect(await audio.exists(), isFalse);
  });

  test('重试会清掉上一次的入库结论', () async {
    final File source = await sourceFile('retry.m4a');
    bool failFirst = true;
    final TranscodeQueue queue = TranscodeQueue(
      engine: _FakeEngine(),
      autoExportToLibrary: true,
      libraryExporter:
          ({
            required String filePath,
            required MediaType type,
            required String displayName,
          }) async {
            if (failFirst) {
              failFirst = false;
              return const ExportResult(ExportStatus.failed, message: '临时失败');
            }
            return const ExportResult(
              ExportStatus.done,
              message: '已保存到「音乐/SniffingBrowser」',
            );
          },
    );
    addTearDown(queue.dispose);

    final TranscodeJob job = await runToEnd(queue, source.path);
    expect(job.exported, isFalse);

    queue.retry(job.id);
    expect(job.exportMessage, isNull);

    // 第二次跑完，入库成功
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!job.exported && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(job.status, TranscodeStatus.completed);
    expect(job.exportMessage, '已保存到「音乐/SniffingBrowser」');
  });
}
