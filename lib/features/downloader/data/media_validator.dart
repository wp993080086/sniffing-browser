import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../sniffer/domain/media_type.dart';

/// 下载产物的内容校验。
///
/// 为什么必须有这一层：把首页当 404 兜底返回，是**极常见**的部署方式
/// （Nuxt/Vue 的 history 回退、Nginx 的 `try_files $uri /index.html`、
/// COS/EdgeOne 的 index 文档重写）。这种情况下请求一个根本不存在的
/// `banner.xxx.mp4`，拿到的是 **200 + text/html** 的一整页 HTML，
/// 扩展名照样是 `.mp4`，大小也像模像样（几十 KB），
/// 存下来双击就是"此文件无法播放 / 文件已损坏"。
///
/// 光看 URL、状态码、甚至 Content-Length 都分辨不出来，只能看**内容**。
///
/// 判定策略刻意保守：只拦"绝不可能是媒体"的文本载荷与空文件，
/// 不做容器格式的严格校验。mp4 / mov / ts 这类容器的变体太多
/// （首个 box 不一定是 ftyp），硬校验会把能播的文件也拦下来。
class MediaValidator {
  const MediaValidator._();

  /// 只读文件头这么多字节就够判断了。
  static const int _headBytes = 512;

  /// 校验文件。返回 `null` 表示通过，否则返回可直接展示给用户的原因。
  ///
  /// [contentType] 是响应的 `Content-Type`，能拿到就一起判断 ——
  /// 服务器自己声明 `text/html` 的"视频"没有任何悬念。
  static Future<String?> validate(
    File file, {
    required MediaType type,
    String? contentType,
  }) async {
    if (!await file.exists()) {
      return '下载完成但文件不存在';
    }

    final int length = await file.length();
    if (length == 0) {
      return '下载到的文件是空的（0 字节），服务器没有返回内容';
    }

    final String label = type.label;

    // 服务器自己说是网页 —— 直接判死，连字节都不用看。
    if (contentType != null &&
        contentType.toLowerCase().contains('text/html')) {
      return '服务器返回的是网页（Content-Type: text/html），不是$label文件；'
          '这个地址多半不存在，站点用首页顶替了 404';
    }

    final Uint8List head = await _readHead(file, length);
    final MediaPayload payload = _classifyPayload(head);

    switch (payload) {
      case MediaPayload.empty:
        return '下载到的文件是空的，服务器没有返回内容';
      case MediaPayload.html:
        return '服务器返回的是网页而不是$label文件；'
            '这个地址多半不存在，站点用首页顶替了 404（常见于 SPA 路由回退）';
      case MediaPayload.xml:
        return '服务器返回的是 XML（多半是错误响应），不是$label文件';
      case MediaPayload.json:
        return '服务器返回的是 JSON 数据（多半是错误提示或被防盗链拦截），'
            '不是$label文件';
      case MediaPayload.text:
        return '服务器返回的是文本内容，不是$label文件';
      case MediaPayload.binary:
        return null;
    }
  }

  /// 读文件头。[length] 小于阈值时按实际长度读，避免越界。
  static Future<Uint8List> _readHead(File file, int length) async {
    final int size = length < _headBytes ? length : _headBytes;
    final RandomAccessFile raf = await file.open();
    try {
      return await raf.read(size);
    } finally {
      await raf.close();
    }
  }

  /// 判定文件头属于哪一类载荷。
  static MediaPayload _classifyPayload(Uint8List head) {
    if (head.isEmpty) return MediaPayload.empty;

    // 跳过 UTF-8 BOM 与前导空白（有的错误页前面会带几个空行）。
    int i = 0;
    if (head.length >= 3 &&
        head[0] == 0xEF &&
        head[1] == 0xBB &&
        head[2] == 0xBF) {
      i = 3;
    }
    while (i < head.length && _isSpace(head[i])) {
      i++;
    }
    if (i >= head.length) return MediaPayload.text;

    final String start = latin1
        .decode(head.sublist(i, i + (head.length - i < 64 ? head.length - i : 64)))
        .toLowerCase();

    if (start.startsWith('<!doctype') ||
        start.startsWith('<html') ||
        start.startsWith('<head') ||
        start.startsWith('<body') ||
        start.startsWith('<meta') ||
        start.startsWith('<!doctype html')) {
      return MediaPayload.html;
    }
    if (start.startsWith('<?xml') || start.startsWith('<error')) {
      return MediaPayload.xml;
    }
    if (start.startsWith('{') || start.startsWith('[')) {
      return MediaPayload.json;
    }

    // 兜底：文件头几乎全是可打印字符 = 纯文本。
    // 二进制容器（mp4 的 ftyp、png 的 \x89PNG、jpg 的 \xFF\xD8）里
    // 一定夹杂大量控制字符，真媒体不会被判成文本。
    if (_looksLikePlainText(head)) return MediaPayload.text;

    return MediaPayload.binary;
  }

  static bool _isSpace(int byte) =>
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;

  static bool _looksLikePlainText(Uint8List head) {
    int printable = 0;
    for (final int byte in head) {
      if (byte == 0) return false; // 二进制里的 NUL 是最可靠的信号
      if (byte >= 0x20 && byte < 0x7F) {
        printable++;
      } else if (byte == 0x09 || byte == 0x0A || byte == 0x0D) {
        printable++;
      } else if (byte >= 0x80) {
        // UTF-8 中文等高位字节，按文本算
        printable++;
      }
    }
    return printable == head.length;
  }
}

/// 文件头的载荷分类。
enum MediaPayload { empty, html, xml, json, text, binary }
