import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffingbrowser/features/transcoder/domain/transcode_job.dart';

/// Android 原生转码桥接的协议测试。
///
/// 这里不跑真 FFmpeg，只验证 Dart 侧如何解读原生 `startTranscode` 的回复：
/// 状态映射错了，真机上就会把「取消」显示成「失败」、把「无音轨」显示成
/// ffmpeg 的英文原文。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('sniffing_browser/transcoder');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> run(
    NativeTranscodeEngine engine,
    void Function(double) onProgress,
  ) {
    return engine.run(
      inputPath: '/tmp/in.mp4',
      outputPath: '/tmp/out.mp3',
      kind: TranscodeKind.audioToMp3,
      onProgress: onProgress,
      isCancelled: () => false,
    );
  }

  void mock({
    required Object? startReply,
    bool available = true,
    void Function(MethodCall call)? onCall,
  }) {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      onCall?.call(call);
      if (call.method == 'isAvailable') return available;
      return startReply;
    });
  }

  test('done：按契约传参并把进度推到 100%', () async {
    MethodCall? captured;
    mock(
      startReply: <String, Object?>{'status': 'done'},
      onCall: (MethodCall call) {
        if (call.method == 'startTranscode') captured = call;
      },
    );

    final List<double> progress = <double>[];
    await run(NativeTranscodeEngine(), progress.add);

    expect(captured, isNotNull);
    final Map<dynamic, dynamic> args =
        captured!.arguments as Map<dynamic, dynamic>;
    expect(args['input'], '/tmp/in.mp4');
    expect(args['output'], '/tmp/out.mp3');
    expect(args['kind'], 'audioToMp3');
    expect(args['secondaryInput'], isNull);
    expect(progress, <double>[1.0]);
  });

  test('done + audioReencoded：Android 回退后的成功仍按完成处理', () async {
    mock(
      startReply: <String, Object?>{
        'status': 'done',
        'strategy': 'audioReencoded',
      },
    );
    final List<double> progress = <double>[];
    await run(NativeTranscodeEngine(), progress.add);
    expect(progress, <double>[1.0]);
  });

  test('canceled：抛 TranscodeCancelled，UI 才显示「已取消」', () async {
    mock(startReply: <String, Object?>{'status': 'canceled'});
    await expectLater(
      run(NativeTranscodeEngine(), (_) {}),
      throwsA(isA<TranscodeCancelled>()),
    );
  });

  test('unsupported：抛 TranscodeUnsupportedSource 且是中文结论', () async {
    mock(
      startReply: <String, Object?>{
        'status': 'unsupported',
        'message': '这个文件里没有音轨，无法提取 MP3',
      },
    );
    await expectLater(
      run(NativeTranscodeEngine(), (_) {}),
      throwsA(
        isA<TranscodeUnsupportedSource>().having(
          (TranscodeUnsupportedSource e) => e.toString(),
          'message',
          contains('没有音轨'),
        ),
      ),
    );
  });

  test('failed：把原生错误行透出来，不吞掉原因', () async {
    mock(
      startReply: <String, Object?>{
        'status': 'failed',
        'message': 'Invalid data found when processing input',
      },
    );
    await expectLater(
      run(NativeTranscodeEngine(), (_) {}),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('Invalid data'),
        ),
      ),
    );
  });

  test('引擎不可用时直接拒绝，不发 startTranscode', () async {
    final List<String> calls = <String>[];
    mock(
      available: false,
      startReply: <String, Object?>{'status': 'done'},
      onCall: (MethodCall call) => calls.add(call.method),
    );
    await expectLater(
      run(NativeTranscodeEngine(), (_) {}),
      throwsA(isA<UnsupportedError>()),
    );
    expect(calls, <String>['isAvailable']);
  });

  test('isAvailable 只缓存成功结论，偶发失败可以恢复', () async {
    int attempts = 0;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'isAvailable') {
        attempts++;
        return attempts >= 2;
      }
      return <String, Object?>{'status': 'done'};
    });

    final NativeTranscodeEngine engine = NativeTranscodeEngine();
    expect(await engine.isAvailable(), isFalse);
    expect(await engine.isAvailable(), isTrue);
  });

  test('cancel：调用 cancelTranscode 并带上 jobId', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'isAvailable') return true;
      captured = call;
      return null;
    });

    await NativeTranscodeEngine().cancel('job-42');
    expect(captured!.method, 'cancelTranscode');
    expect((captured!.arguments as Map<dynamic, dynamic>)['jobId'], 'job-42');
  });

  test('原生反向 onProgress 会推给当前任务的进度回调', () async {
    final Completer<Object?> startReply = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'isAvailable') return true;
      return startReply.future;
    });

    final List<double> progress = <double>[];
    final Future<void> pending = run(NativeTranscodeEngine(), progress.add);
    // 等 startTranscode 发出、静态 handler 装好之后，再模拟原生推一次进度。
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('onProgress', 0.42),
    );
    await messenger.handlePlatformMessage(channel.name, message, null);

    startReply.complete(<String, Object?>{'status': 'done'});
    await pending;

    expect(progress, <double>[0.42, 1.0]);
  });
}
