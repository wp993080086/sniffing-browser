import 'm3u8_models.dart';

/// 解析失败时抛出，带上出错的行号，方便定位是哪个站点的不规范写法。
class M3u8ParseException implements Exception {
  M3u8ParseException(this.message, {this.line});

  final String message;
  final int? line;

  @override
  String toString() =>
      line == null ? 'M3u8ParseException: $message' : 'M3u8ParseException(line $line): $message';
}

/// m3u8 解析器。
///
/// 关键点（都是踩过的坑）：
/// 1. 相对路径基于 **playlist 自身 URL** 解析，不是页面 URL。
/// 2. `#EXT-X-KEY` 是“作用于其后所有分片”的，不是单条。
/// 3. `#EXT-X-MAP` 的初始化段必须排在合并结果最前面，否则 fMP4 打不开。
/// 4. `#EXT-X-MEDIA-SEQUENCE` 是第一个分片的序号，未给 IV 时用它算 IV。
class M3u8Parser {
  const M3u8Parser();

  /// [content] 是 playlist 文本，[baseUri] 是 playlist 的地址。
  M3u8Playlist parse(String content, Uri baseUri) {
    if (!content.contains('#EXTM3U')) {
      throw M3u8ParseException('内容不是合法的 m3u8（缺少 #EXTM3U）');
    }

    final List<String> lines = const LineSplitter()
        .convert(content)
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();

    final List<M3u8Variant> variants = <M3u8Variant>[];
    final List<M3u8Segment> segments = <M3u8Segment>[];

    int mediaSequence = 0;
    bool isEndList = false;
    double? targetDuration;
    String? initSegmentUrl;
    bool isFmp4 = false;

    M3u8Key? currentKey;
    double pendingDuration = 0;
    int? pendingByteRangeLength;
    int? pendingByteRangeOffset;
    int segmentIndex = 0;
    Map<String, String> pendingVariantAttrs = <String, String>{};

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final int lineNo = i + 1;

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(line.substring(22).trim()) ?? 0;
        continue;
      }

      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.tryParse(line.substring(22).trim());
        continue;
      }

      if (line.startsWith('#EXT-X-ENDLIST')) {
        isEndList = true;
        continue;
      }

      if (line.startsWith('#EXT-X-KEY:')) {
        currentKey = _parseKey(line.substring(11), baseUri, lineNo);
        continue;
      }

      if (line.startsWith('#EXT-X-MAP:')) {
        final String attrs = line.substring(11);
        final Map<String, String> map = _parseAttributes(attrs);
        final String? uriValue = map['URI'];
        if (uriValue != null && uriValue.isNotEmpty) {
          final Uri resolved = baseUri.resolve(uriValue);
          // 第一个 MAP 就是全局初始化段；后续 MAP 变化意味着分片结构变了，
          // 那种情况不是单文件能拼的，这里只记录第一个。
          initSegmentUrl ??= resolved.toString();
          if (resolved.path.toLowerCase().endsWith('.m4s') ||
              resolved.path.toLowerCase().endsWith('.mp4')) {
            isFmp4 = true;
          }
        }
        continue;
      }

      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final String value = line.substring(17).trim();
        final List<String> parts = value.split('@');
        pendingByteRangeLength = int.tryParse(parts[0]);
        if (parts.length > 1) {
          pendingByteRangeOffset = int.tryParse(parts[1]);
        }
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        final String value = line.substring(8);
        final String durationPart = value.split(',').first.trim();
        pendingDuration = double.tryParse(durationPart) ?? 0;
        continue;
      }

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingVariantAttrs = _parseAttributes(line.substring(18));
        continue;
      }

      if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        // I-frame 流是快进预览用的，不参与下载。
        pendingVariantAttrs = <String, String>{};
        continue;
      }

      if (line.startsWith('#')) {
        continue;
      }

      // 非 # 开头 → 是一个 URI。
      final Uri resolved = baseUri.resolve(line);

      if (pendingVariantAttrs.isNotEmpty) {
        variants.add(
          M3u8Variant(
            uri: resolved,
            bandwidth: int.tryParse(pendingVariantAttrs['BANDWIDTH'] ?? ''),
            resolution: pendingVariantAttrs['RESOLUTION'],
            codecs: pendingVariantAttrs['CODECS'],
            name: pendingVariantAttrs['NAME'],
          ),
        );
        pendingVariantAttrs = <String, String>{};
        continue;
      }

      final String lowerPath = resolved.path.toLowerCase();
      if (lowerPath.endsWith('.m4s') || lowerPath.endsWith('.mp4')) {
        isFmp4 = true;
      } else if (lowerPath.endsWith('.m4a')) {
        isFmp4 = true;
      }

      segments.add(
        M3u8Segment(
          uri: resolved,
          sequence: mediaSequence + segmentIndex,
          duration: pendingDuration,
          key: currentKey,
          byteRange: pendingByteRangeLength == null
              ? null
              : M3u8ByteRange(
                  length: pendingByteRangeLength,
                  offset: pendingByteRangeOffset,
                ),
        ),
      );
      segmentIndex++;
      pendingDuration = 0;
      pendingByteRangeLength = null;
      pendingByteRangeOffset = null;
    }

    if (variants.isEmpty && segments.isEmpty) {
      throw M3u8ParseException('playlist 里既没有变体也没有分片');
    }

    // master playlist 的 init 段信息在子 playlist 里，这里清掉避免误用。
    if (variants.isNotEmpty) {
      return M3u8Playlist(
        baseUri: baseUri,
        variants: variants,
        mediaSequence: mediaSequence,
        isEndList: isEndList,
        targetDuration: targetDuration,
      );
    }

    return M3u8Playlist(
      baseUri: baseUri,
      segments: segments,
      mediaSequence: mediaSequence,
      isEndList: isEndList,
      initSegmentUrl: initSegmentUrl,
      isFmp4: isFmp4,
      targetDuration: targetDuration,
    );
  }

  /// 从 master playlist 里挑码率最高的一路。
  /// 分辨率相同的情况下按带宽兜底排序。
  M3u8Variant pickBestVariant(M3u8Playlist master) {
    if (master.variants.isEmpty) {
      throw M3u8ParseException('master playlist 没有变体');
    }
    final List<M3u8Variant> sorted = List<M3u8Variant>.from(master.variants)
      ..sort((M3u8Variant a, M3u8Variant b) {
        final int areaA = _resolutionArea(a.resolution);
        final int areaB = _resolutionArea(b.resolution);
        if (areaA != areaB) return areaB.compareTo(areaA);
        return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
    return sorted.first;
  }

  int _resolutionArea(String? resolution) {
    if (resolution == null) return 0;
    final List<String> parts = resolution.split('x');
    if (parts.length != 2) return 0;
    final int w = int.tryParse(parts[0]) ?? 0;
    final int h = int.tryParse(parts[1]) ?? 0;
    return w * h;
  }

  M3u8Key? _parseKey(String attrs, Uri baseUri, int lineNo) {
    final Map<String, String> map = _parseAttributes(attrs);
    final String? method = map['METHOD'];
    if (method == null) {
      throw M3u8ParseException('EXT-X-KEY 缺少 METHOD', line: lineNo);
    }
    if (method.toUpperCase() == 'NONE') {
      return M3u8Key(method: method);
    }

    final String? uriValue = map['URI'];
    final Uri? keyUri = uriValue == null ? null : baseUri.resolve(uriValue);

    List<int>? iv;
    final String? ivHex = map['IV'];
    if (ivHex != null && ivHex.isNotEmpty) {
      iv = _parseIv(ivHex, lineNo);
    }

    return M3u8Key(
      method: method,
      uri: keyUri,
      iv: iv,
      keyFormat: map['KEYFORMAT'],
    );
  }

  List<int> _parseIv(String hex, int lineNo) {
    String cleaned = hex.trim();
    if (cleaned.toLowerCase().startsWith('0x')) {
      cleaned = cleaned.substring(2);
    }
    if (cleaned.length % 2 != 0) {
      cleaned = '0$cleaned';
    }
    if (cleaned.length > 32) {
      // 超过 16 字节的 IV 取低 128 位
      cleaned = cleaned.substring(cleaned.length - 32);
    }
    // 不足 16 字节左补零
    cleaned = cleaned.padLeft(32, '0');

    final List<int> bytes = <int>[];
    for (int i = 0; i < cleaned.length; i += 2) {
      final int? value = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (value == null) {
        throw M3u8ParseException('IV 不是合法十六进制: $hex', line: lineNo);
      }
      bytes.add(value);
    }
    return bytes;
  }

  /// 解析 `KEY=VALUE,KEY="VA,LUE"` 形式的属性列表。
  /// 值里可能有逗号（CODECS 常见），所以不能直接 split(',')。
  Map<String, String> _parseAttributes(String input) {
    final Map<String, String> result = <String, String>{};
    final StringBuffer keyBuffer = StringBuffer();
    final StringBuffer valueBuffer = StringBuffer();
    bool inQuotes = false;
    bool inValue = false;

    void flush() {
      final String key = keyBuffer.toString().trim();
      final String value = valueBuffer.toString().trim();
      if (key.isNotEmpty) result[key.toUpperCase()] = value;
      keyBuffer.clear();
      valueBuffer.clear();
      inValue = false;
    }

    for (int i = 0; i < input.length; i++) {
      final String ch = input[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (ch == '=' && !inQuotes && !inValue) {
        inValue = true;
        continue;
      }
      if (ch == ',' && !inQuotes) {
        flush();
        continue;
      }
      if (inValue) {
        valueBuffer.write(ch);
      } else {
        keyBuffer.write(ch);
      }
    }
    flush();
    return result;
  }
}

/// 单独抽出来，避免额外依赖 dart:convert 的整包导入。
class LineSplitter {
  const LineSplitter();

  List<String> convert(String input) => input.split(RegExp(r'\r\n|\r|\n'));
}
