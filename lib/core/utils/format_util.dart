/// 展示层的格式化。不引 intl，避免为一个字节数格式化拖一个包进来。
class FormatUtil {
  const FormatUtil._();

  static const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB'];

  /// 1536 -> "1.5 KB"
  static String bytes(int? value) {
    if (value == null || value <= 0) return '未知大小';
    double size = value.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < _units.length - 1) {
      size /= 1024;
      unit++;
    }
    final String text = unit == 0
        ? size.toStringAsFixed(0)
        : size.toStringAsFixed(size >= 100 ? 0 : 1);
    return '$text ${_units[unit]}';
  }

  /// 下载速度。
  static String speed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '—';
    return '${bytes(bytesPerSecond.round())}/s';
  }

  /// 剩余时间。
  static String eta(int remainingBytes, double bytesPerSecond) {
    if (bytesPerSecond <= 0 || remainingBytes <= 0) return '—';
    final int seconds = (remainingBytes / bytesPerSecond).ceil();
    return duration(Duration(seconds: seconds));
  }

  /// 3725s -> "1:02:05"；65s -> "1:05"
  static String duration(Duration d) {
    final int total = d.inSeconds;
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  /// 中间省略，保留扩展名。长 URL 在窄屏上直接截断会把后缀吃掉，
  /// 用户就分不出是 mp4 还是 m3u8。
  static String middleEllipsis(String input, int maxChars) {
    if (input.length <= maxChars) return input;
    if (maxChars <= 6) return input.substring(0, maxChars);
    final int head = (maxChars - 3) ~/ 2;
    final int tail = maxChars - 3 - head;
    return '${input.substring(0, head)}...${input.substring(input.length - tail)}';
  }

  /// 时间戳 -> "10:24"
  static String clock(DateTime time) {
    final String h = time.hour.toString().padLeft(2, '0');
    final String m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
