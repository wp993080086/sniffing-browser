import 'dart:convert';
import 'dart:io';

import '../logging/app_log.dart';

/// 应用私有目录里的小 JSON 文件读写。
///
/// 历史、收藏这类记录都是「一个版本号 + 一个数组」，各写一遍原子写和容错
/// 只会让四个文件里的错误处理慢慢长歪，所以在这里收一次。
///
/// 读失败一律返回 null（调用方按空处理），写失败只记日志不抛——这些记录
/// 丢了不影响主流程，崩掉整个应用才是问题。
class JsonFile {
  const JsonFile._();

  /// 读一个 JSON 对象。文件不存在、内容损坏、格式不对都返回 null。
  static Future<Map<String, Object?>?> read(File file, String tag) async {
    if (!await file.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        logWarn(tag, '记录格式异常，按空处理');
        return null;
      }
      return decoded;
    } catch (e) {
      logWarn(tag, '读取记录失败，按空处理: $e');
      return null;
    }
  }

  /// 原子写：先写 `.tmp` 再 rename。
  ///
  /// 写到一半被系统杀掉时，不会留下半个 JSON 让下次启动解析失败。
  static Future<void> write(
    File file,
    Map<String, Object?> payload,
    String tag,
  ) async {
    final File temp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(file.path);
    } catch (e) {
      logWarn(tag, '写入记录失败: $e');
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 清不掉临时文件不影响主流程。
      }
    }
  }
}
