import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 摘要工具。主要用于生成稳定的 id 和临时目录名。
class HashUtil {
  const HashUtil._();

  /// 对字符串取 md5，取前 [length] 位。URL 直接当文件名会超长且含非法字符，
  /// 所以一律用摘要做 id。
  static String md5Short(String input, {int length = 16}) {
    final digest = md5.convert(utf8.encode(input)).toString();
    return length >= digest.length ? digest : digest.substring(0, length);
  }
}
