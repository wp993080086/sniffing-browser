import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/constants/app_constants.dart';

void main() {
  test('AppConstants.version 与 pubspec.yaml 的 version 一致', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml 里找不到 version');
    expect(
      AppConstants.version,
      match!.group(1),
      reason:
          '改了 pubspec 的版本号就要同步 AppConstants.version，'
          '否则导出日志里的版本是错的',
    );
  });
}
