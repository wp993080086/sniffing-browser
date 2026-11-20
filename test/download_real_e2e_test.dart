import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/verify_download.dart';

/// 真实 CDN 的下载链路回归。
///
/// 原来只有 `tools/verify_download.dart` 一个入口，而它 `dart run` 跑不起来
/// （下载链路依赖 flutter/foundation，`dart run` 没有 dart:ui），等于 W1 这条
/// 验证没有可执行入口。现在挂到 test 下，借 flutter test 的运行环境。
///
/// 默认跳过：要下几十 MB 真实分片，网络慢时几分钟起步，不适合跟着全量测试跑。
/// 需要时显式打开：
///
/// ```bash
/// SNIFF_E2E=1 flutter test test/download_real_e2e_test.dart
/// SNIFF_E2E=1 SNIFF_VERIFY=hls flutter test test/download_real_e2e_test.dart
/// ```
void main() {
  final bool enabled = Platform.environment['SNIFF_E2E'] == '1';

  test(
    '下载链路端到端（单文件 / HLS / AES）',
    () async {
      final int failed = await run(
        mode: Platform.environment['SNIFF_VERIFY'] ?? 'all',
      );
      expect(failed, 0, reason: '有 $failed 项失败，往上翻 [FAIL] 行看具体是哪一项');
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: enabled
        ? null
        : '需要真实网络：SNIFF_E2E=1 flutter test test/download_real_e2e_test.dart',
  );
}
