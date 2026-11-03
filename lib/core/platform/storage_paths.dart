import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'platform_info.dart';

/// 存储路径。
///
/// 全部落在“应用自己的目录”里，不碰公共存储：
/// - Android 用外部私有目录（`/sdcard/Android/data/<pkg>/files`），不需要任何权限，
///   卸载时随应用清理，但文件管理器里能看到。
/// - 鸿蒙用 filesDir。
/// - 桌面直接写用户下载目录，用户找得到。
///
/// 导出到相册/音乐目录是另一件事，见 [MediaExporter]。
class StoragePaths {
  const StoragePaths._();

  static Directory? _root;
  static Directory? _downloads;
  static Directory? _temp;

  static Future<void> init() async {
    final Directory root = await _resolveRoot();
    await root.create(recursive: true);
    _root = root;

    _downloads = Directory(p.join(root.path, 'downloads'));
    await _downloads!.create(recursive: true);

    _temp = Directory(p.join(root.path, 'tmp'));
    await _temp!.create(recursive: true);
  }

  static Future<Directory> _resolveRoot() async {
    // 桌面端放到「下载/SniffingBrowser」，用户下完就能直接看到。
    if (PlatformInfo.isDesktop) {
      Directory? downloads;
      try {
        downloads = await getDownloadsDirectory();
      } catch (_) {
        downloads = null;
      }
      downloads ??= await getApplicationDocumentsDirectory();
      return Directory(p.join(downloads.path, 'SniffingBrowser'));
    }

    // Android：优先外部私有目录，避免占用内部存储。
    if (PlatformInfo.current == AppPlatform.android) {
      try {
        final Directory? external = await getExternalStorageDirectory();
        if (external != null) {
          return Directory(p.join(external.path, 'SniffingBrowser'));
        }
      } catch (_) {
        // 部分定制 ROM 会抛异常，退回内部目录。
      }
    }

    final Directory support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'SniffingBrowser'));
  }

  static Directory get root {
    final Directory? dir = _root;
    if (dir == null) {
      throw StateError('StoragePaths.init() 未调用');
    }
    return dir;
  }

  static Directory get downloads {
    final Directory? dir = _downloads;
    if (dir == null) throw StateError('StoragePaths.init() 未调用');
    return dir;
  }

  static Directory get temp {
    final Directory? dir = _temp;
    if (dir == null) throw StateError('StoragePaths.init() 未调用');
    return dir;
  }

  /// 每个 HLS 任务一个独立临时目录，失败时整目录删除即可。
  static Directory tempDirFor(String taskId) =>
      Directory(p.join(temp.path, taskId));

  /// 目标文件路径。重名时自动加 `(1)`、`(2)`。
  static File uniqueFile(String fileName) {
    final String safeName = sanitizeFileName(fileName);
    File candidate = File(p.join(downloads.path, safeName));
    if (!candidate.existsSync()) return candidate;

    final String ext = p.extension(safeName);
    final String base = p.basenameWithoutExtension(safeName);
    int index = 1;
    while (candidate.existsSync()) {
      candidate = File(p.join(downloads.path, '$base ($index)$ext'));
      index++;
    }
    return candidate;
  }

  /// Windows 不允许 `\ / : * ? " < > |`；Android/鸿蒙不允许 `/` 和 NUL。
  /// 统一按最严的规则处理，省得分平台。
  static String sanitizeFileName(String name) {
    String result = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    if (result.isEmpty) result = 'unnamed';
    if (result.length > 120) {
      final String ext = p.extension(result);
      final String base = p.basenameWithoutExtension(result);
      final int keep = 120 - ext.length;
      result = '${base.substring(0, keep.clamp(1, base.length))}$ext';
    }
    // Windows 保留名
    const List<String> reserved = <String>[
      'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4',
      'LPT1', 'LPT2', 'LPT3',
    ];
    final String bare = p.basenameWithoutExtension(result).toUpperCase();
    if (reserved.contains(bare)) result = '_$result';
    return result;
  }

  /// 清理某个任务残留的临时目录。
  static Future<void> cleanTemp(String taskId) async {
    final Directory dir = tempDirFor(taskId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
