import 'dart:io';
import 'dart:typed_data';

/// 分片合并。
///
/// 纯二进制拼接，不做转封装：
/// - TS 分片拼出来是 `.ts`，VLC / PotPlayer / IINA 都能直接播
/// - fMP4 分片（先写 `#EXT-X-MAP` 的 init 段）拼出来就是标准 mp4
///
/// 必须流式写入。数 GB 的流一次性读进内存会直接 OOM。
class SegmentMerger {
  const SegmentMerger._();

  /// 返回写出的字节数。
  static Future<int> merge({
    required List<File> segments,
    required File output,
    File? initSegment,
    void Function(int written, int total)? onProgress,
  }) async {
    final int totalBytes = _totalSize(segments, initSegment);
    int written = 0;

    if (await output.exists()) {
      await output.delete();
    }
    await output.parent.create(recursive: true);

    final IOSink sink = output.openWrite();
    try {
      if (initSegment != null && await initSegment.exists()) {
        written += await _appendFile(sink, initSegment, written, totalBytes, onProgress);
      }
      for (final File segment in segments) {
        if (!await segment.exists()) {
          throw FileSystemException('分片缺失', segment.path);
        }
        written += await _appendFile(sink, segment, written, totalBytes, onProgress);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    return written;
  }

  static Future<int> _appendFile(
    IOSink sink,
    File file,
    int alreadyWritten,
    int totalBytes,
    void Function(int written, int total)? onProgress,
  ) async {
    int written = 0;
    await for (final List<int> chunk in file.openRead()) {
      sink.add(chunk);
      written += chunk.length;
      onProgress?.call(alreadyWritten + written, totalBytes);
    }
    return written;
  }

  static int _totalSize(List<File> segments, File? initSegment) {
    int total = 0;
    if (initSegment != null && initSegment.existsSync()) {
      total += initSegment.lengthSync();
    }
    for (final File file in segments) {
      if (file.existsSync()) total += file.lengthSync();
    }
    return total;
  }

  /// 只拼前两个字节做格式嗅探，判断是 TS（0x47 同步字节）还是 fMP4。
  /// 用于校验用户选的容器和实际分片是否匹配。
  static Future<bool> looksLikeTransportStream(File file) async {
    if (!await file.exists()) return false;
    final RandomAccessFile raf = await file.open();
    try {
      final Uint8List head = await raf.read(188);
      if (head.isEmpty) return false;
      // TS 每 188 字节一个 0x47
      if (head[0] != 0x47) return false;
      if (head.length >= 376 && head[188] != 0x47) return false;
      return true;
    } finally {
      await raf.close();
    }
  }
}
