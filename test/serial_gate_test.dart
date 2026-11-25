import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/utils/serial_gate.dart';

void main() {
  test('任务按提交顺序串行执行', () async {
    final SerialGate gate = SerialGate();
    final List<int> order = <int>[];
    final List<Future<void>> tasks = <Future<void>>[
      gate.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add(1);
      }),
      gate.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        order.add(2);
      }),
      gate.run(() async {
        order.add(3);
      }),
    ];

    await Future.wait(tasks);

    // 第二个虽然更快，也必须等第一个跑完。
    expect(order, <int>[1, 2, 3]);
  });

  test('前一个任务抛错不会卡住后面的任务', () async {
    final SerialGate gate = SerialGate();
    final List<String> done = <String>[];

    final Future<void> failing = gate.run<void>(() async {
      throw StateError('boom');
    });
    final Future<void> next = gate.run<void>(() async {
      done.add('next');
    });

    await expectLater(failing, throwsStateError);
    await next;
    expect(done, <String>['next']);
  });

  test('waiting 反映未完成的任务数并最终归零', () async {
    final SerialGate gate = SerialGate();
    final Completer<void> hold = Completer<void>();

    final Future<void> first = gate.run<void>(() => hold.future);
    final Future<void> second = gate.run<void>(() async {});

    expect(gate.waiting, 2);

    hold.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(gate.waiting, 0);
  });

  test('错误任务的返回值也是 Future 的错误，不吞异常', () async {
    final SerialGate gate = SerialGate();
    final Future<int> result = gate.run<int>(() async => throw ArgumentError());

    await expectLater(result, throwsArgumentError);
    // 之后还能继续用。
    expect(await gate.run<int>(() async => 7), 7);
  });
}
