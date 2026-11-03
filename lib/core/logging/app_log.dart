import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/storage_paths.dart';

/// 日志级别。
enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  const LogLevel(this.tag);

  final String tag;
}

/// 一条日志。
@immutable
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  String get formatted {
    final String t = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
    return '$t ${level.tag}/$tag $message';
  }

  String get fileLine {
    final String d = '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
    return '$d $formatted';
  }

  @override
  String toString() => formatted;
}

/// 应用日志。
///
/// 设计约束，都是为了避免“排查工具本身成为卡顿来源”：
/// - 写文件全部异步且**从不 await**，调用方零阻塞。
/// - 内存只保留最近 [maxEntries] 条，长会话不会把内存吃满。
/// - 每 [flushInterval] 合并写一次，避免每个请求都开一次文件句柄。
///
/// 日志是排查“无响应”这类问题的唯一手段，所以宁可多留也要留。
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// 内存里保留的条数。诊断页只展示这些。
  static const int maxEntries = 800;

  /// 单文件上限，超过后滚动一次（app.log -> app.log.1）。
  static const int maxFileBytes = 2 * 1024 * 1024;

  static const Duration flushInterval = Duration(milliseconds: 400);

  final List<LogEntry> _entries = <LogEntry>[];

  /// 待写盘的内容，flush 时一次性写掉。
  final List<String> _pending = <String>[];

  File? _file;
  Timer? _flushTimer;
  bool _enabled = true;
  bool _installed = false;

  /// 累计计数，诊断页用来判断“到底有没有触发”。
  final Map<String, int> _counters = <String, int>{};

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  Map<String, int> get counters => Map<String, int>.unmodifiable(_counters);

  File? get logFile => _file;

  bool get enabled => _enabled;

  /// 安装全局错误捕获。必须在 runApp 之前调用。
  void install({bool enabled = true}) {
    _enabled = enabled;
    if (_installed) return;
    _installed = true;

    FlutterError.onError = (FlutterErrorDetails details) {
      // 先记日志再交回默认处理，保证崩溃信息一定落盘。
      error(
        'FlutterError',
        '${details.exceptionAsString()}\n${details.stack ?? ''}',
      );
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (Object err, StackTrace stack) {
      error('Uncaught', '$err\n$stack');
      // 返回 true 表示已处理。不要 return false，否则进程直接退出，
      // 用户拿到的是闪退而不是可上报的日志。
      return true;
    };
  }

  /// 绑定日志文件。存储初始化完成后调用；失败时退化为仅内存日志。
  Future<void> attachFile() async {
    try {
      final Directory dir = Directory(p.join(StoragePaths.root.path, 'logs'));
      await dir.create(recursive: true);
      final File f = File(p.join(dir.path, 'app.log'));
      if (await f.exists() && await f.length() > maxFileBytes) {
        final File old = File(p.join(dir.path, 'app.log.1'));
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      _file = f;
      info('Log', '日志文件: ${f.path}');
    } catch (e) {
      _file = null;
      warn('Log', '日志文件不可用，仅内存记录: $e');
    }
  }

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);

  void info(String tag, String message) => _add(LogLevel.info, tag, message);

  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);

  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  /// 计数器 +1。用来回答“这个回调到底有没有被调用过”。
  int bump(String name, {int delta = 1}) {
    final int value = (_counters[name] ?? 0) + delta;
    _counters[name] = value;
    return value;
  }

  void resetCounters() => _counters.clear();

  void _add(LogLevel level, String tag, String message) {
    if (!_enabled) return;

    final LogEntry entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );

    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }

    if (kDebugMode) {
      // ignore: avoid_print
      print(entry.formatted);
    }

    _pending.add(entry.fileLine);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(flushInterval, () {
      _flushTimer = null;
      _flush();
    });
  }

  void _flush() {
    if (_pending.isEmpty) return;
    final List<String> batch = List<String>.from(_pending);
    _pending.clear();

    final File? f = _file;
    if (f == null) return;

    // 刻意不 await：写盘失败不应该影响业务，更不应该阻塞 UI。
    unawaited(
      f
          .writeAsString('${batch.join('\n')}\n', mode: FileMode.append)
          .catchError((Object _) => f),
    );
  }

  /// 崩溃前强制落盘。只在真正的致命错误路径上调用。
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final List<String> batch = List<String>.from(_pending);
    _pending.clear();
    final File? f = _file;
    if (f == null || batch.isEmpty) return;
    try {
      await f.writeAsString('${batch.join('\n')}\n', mode: FileMode.append);
    } catch (_) {
      // 已经尽力了。
    }
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// 把当前全部日志导出成文本，供复制/分享。
  String export() => _entries.map((LogEntry e) => e.fileLine).join('\n');

  /// 诊断信息头，附在导出内容前面。
  String diagnosticsHeader() {
    final StringBuffer sb = StringBuffer()
      ..writeln('=== 环境 ===')
      ..writeln('平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Dart: ${Platform.version}')
      ..writeln('日志文件: ${_file?.path ?? "不可用"}')
      ..writeln()
      ..writeln('=== 计数器 ===');
    for (final MapEntry<String, int> e in _counters.entries) {
      sb.writeln('${e.key}: ${e.value}');
    }
    sb
      ..writeln()
      ..writeln('=== 日志 ===');
    return sb.toString();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _flush();
    super.dispose();
  }
}

/// 全局便捷入口。`AppLog.instance.info(...)` 太长，业务里到处写。
void logDebug(String tag, String message) => AppLog.instance.debug(tag, message);

void logInfo(String tag, String message) => AppLog.instance.info(tag, message);

void logWarn(String tag, String message) => AppLog.instance.warn(tag, message);

void logError(String tag, String message) => AppLog.instance.error(tag, message);
