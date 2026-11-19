import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../features/sniffer/domain/media_type.dart';
import 'platform_info.dart';
import 'storage_paths.dart';

enum ExportStatus {
  /// 还没导出过。
  notExported,

  /// 成功写入系统媒体库（相册 / 音乐目录）或桌面下载目录。
  done,

  /// 目标平台不支持该类型（如把音频存进相册、把 ts 存进相册）。
  unsupported,

  /// 原生侧尚未实现。
  notImplemented,

  /// 执行出错。
  failed,
}

class ExportResult {
  const ExportResult(this.status, {this.targetPath, this.message});

  final ExportStatus status;
  final String? targetPath;
  final String? message;

  bool get isSuccess => status == ExportStatus.done;

  String get displayMessage {
    switch (status) {
      case ExportStatus.notExported:
        return '未导出';
      case ExportStatus.done:
        // 移动端 targetPath 是 content:// 的媒体库 URI，直接给用户看没有意义，
        // 由 MediaExporter 填好人类可读的目录名。
        final String? label = message;
        if (label != null && label.isNotEmpty) return label;
        return '已保存到${targetPath ?? '目标目录'}';
      case ExportStatus.unsupported:
        return message ?? '该类型不支持导出到此处';
      case ExportStatus.notImplemented:
        return '当前平台尚未实现导出，文件仍在下载目录';
      case ExportStatus.failed:
        return message ?? '导出失败';
    }
  }
}

/// 把已下载的文件写入系统媒体库。
///
/// 为什么不在下载时直接写相册：
/// 鸿蒙的 SaveButton 授权窗口只有 10 秒 / 1 分钟，边下边写必然超时。
/// 所以统一“先下到私有目录，完成后再导出”。
///
/// 各平台实现：
/// - Windows/macOS/Linux：纯 Dart 复制到下载目录，无需原生。
/// - Android：MethodChannel -> MediaStore + IS_PENDING。
/// - HarmonyOS：MethodChannel -> showAssetsCreationDialog。
class MediaExporter {
  const MediaExporter._();

  static const MethodChannel _channel = MethodChannel(
    'sniffing_browser/media_exporter',
  );

  /// 音频不进相册（两端相册都只认图片和视频），所以单独一个目标。
  static ExportTarget targetFor(MediaType type) {
    switch (type) {
      case MediaType.image:
      case MediaType.video:
      case MediaType.hls:
      case MediaType.dash:
        return ExportTarget.gallery;
      case MediaType.audio:
        return ExportTarget.music;
      case MediaType.other:
        return ExportTarget.file;
    }
  }

  static Future<ExportResult> export({
    required String filePath,
    required MediaType type,
    String? displayName,
  }) async {
    final File source = File(filePath);
    if (!await source.exists()) {
      return const ExportResult(ExportStatus.failed, message: '源文件不存在');
    }

    final ExportTarget target = targetFor(type);

    // TS 容器进不了相册，先明确拦掉，别让用户以为存成功了。
    if (target == ExportTarget.gallery &&
        p.extension(filePath).toLowerCase() == '.ts') {
      return const ExportResult(
        ExportStatus.unsupported,
        message: 'TS 格式无法存入相册，请先转为 MP4',
      );
    }

    if (PlatformInfo.isDesktop) {
      return _copyToDesktop(source, displayName ?? p.basename(filePath));
    }

    try {
      final Map<Object?, Object?>? result = await _channel
          .invokeMethod<Map<Object?, Object?>>('exportMedia', <String, Object?>{
            'path': filePath,
            'name': displayName ?? p.basename(filePath),
            'target': target.name,
            'mimeType': _mimeFor(type, filePath),
          });

      if (result == null) {
        return const ExportResult(ExportStatus.failed, message: '导出返回空结果');
      }

      final String status = (result['status'] as String?) ?? 'failed';
      switch (status) {
        case 'done':
          return ExportResult(
            ExportStatus.done,
            targetPath: result['uri'] as String?,
            message: '已保存到「${_libraryLabel(target, filePath)}」',
          );
        case 'unsupported':
          return ExportResult(
            ExportStatus.unsupported,
            message: result['message'] as String?,
          );
        case 'notImplemented':
          return const ExportResult(ExportStatus.notImplemented);
        default:
          return ExportResult(
            ExportStatus.failed,
            message: result['message'] as String? ?? '原生导出失败',
          );
      }
    } on MissingPluginException {
      return const ExportResult(ExportStatus.notImplemented);
    } on PlatformException catch (e) {
      return ExportResult(ExportStatus.failed, message: e.message ?? e.code);
    }
  }

  /// 用系统默认程序打开产物。
  ///
  /// [target] 可以是媒体库 URI（`content://`），也可以是本地绝对路径：
  /// Android 侧会把路径换成 FileProvider 的 `content://` 再带读授权交出去
  /// （见 `file_paths.xml`），所以没导出过的产物也能直接打开。
  /// 返回 false 表示没有可用的处理程序，调用方给一句提示即可。
  static Future<bool> openFile(String target) async {
    if (PlatformInfo.isDesktop) {
      try {
        final String exe = Platform.isWindows
            ? 'cmd'
            : (Platform.isMacOS ? 'open' : 'xdg-open');
        final List<String> args = Platform.isWindows
            ? <String>['/c', 'start', '', target]
            : <String>[target];
        await Process.start(exe, args, mode: ProcessStartMode.detached);
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'openMedia',
        <String, Object?>{'uri': target},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 调系统分享面板把产物发给别的应用。
  ///
  /// 只有 Android 有等价能力（`ACTION_SEND` + FileProvider 的 `content://`）；
  /// 桌面没有系统级分享面板，直接返回 false，由调用方决定是否隐藏入口。
  static Future<bool> shareFile(String path) async {
    if (PlatformInfo.isDesktop) return false;

    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'shareMedia',
        <String, Object?>{'path': path},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<ExportResult> _copyToDesktop(File source, String name) async {
    try {
      final File target = StoragePaths.uniqueFile(name);
      await source.copy(target.path);
      return ExportResult(ExportStatus.done, targetPath: target.path);
    } catch (e) {
      return ExportResult(ExportStatus.failed, message: e.toString());
    }
  }

  /// 媒体库里的落点，用用户能对照的目录名描述。
  ///
  /// 实际路径由原生侧拼成 `Music/SniffingBrowser` 这类形式
  /// （见 `MediaExporterHandler.kt` 的 `destination()`），Dart 侧没有
  /// 可靠的读取手段，所以这里只做文案映射，两边要保持一致。
  static String _libraryLabel(ExportTarget target, String filePath) {
    final String ext = p.extension(filePath).toLowerCase();
    switch (target) {
      case ExportTarget.music:
        return '音乐/SniffingBrowser';
      case ExportTarget.file:
        return '下载/SniffingBrowser';
      case ExportTarget.gallery:
        return const <String>[
              '.mp4',
              '.m4v',
              '.mov',
              '.mkv',
              '.webm',
              '.3gp',
            ].contains(ext)
            ? '视频/SniffingBrowser'
            : '相册/SniffingBrowser';
    }
  }

  static String _mimeFor(MediaType type, String path) {
    final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    switch (type) {
      case MediaType.image:
        return 'image/$ext';
      case MediaType.audio:
        if (ext == 'm4a') return 'audio/mp4';
        return 'audio/$ext';
      case MediaType.video:
      case MediaType.hls:
      case MediaType.dash:
        return 'video/$ext';
      case MediaType.other:
        return 'application/octet-stream';
    }
  }
}

/// 导出目标。
enum ExportTarget { gallery, music, file }
