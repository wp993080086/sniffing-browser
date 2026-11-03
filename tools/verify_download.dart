// 下载链路的端到端验证脚本。
//
// 不属于 test/ 目录：这里要发真实网络请求，跑得慢，也不适合放 CI。
// 用法：
//   dart run tools/verify_download.dart            # 全部
//   dart run tools/verify_download.dart file       # 单文件
//   dart run tools/verify_download.dart hls        # 普通 HLS
//   dart run tools/verify_download.dart aes        # AES-128 HLS
//
// 为什么用本地 HTTP 服务提供 playlist：真实测试流动辄 600 个分片，
// 一次下完要几分钟。本地服务可以只暴露 3 个分片，但分片本身仍来自
// 真实 CDN，所以解析、并发、解密、合并走的是完整生产代码路径。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/downloader/data/hls/hls_downloader.dart';

const String _tsBase = 'https://test-streams.mux.dev/x36xhzz/url_2';

/// 三个连续分片，240p，每个 10 秒约 200KB，够小又快。
const List<String> _segments = <String>[
  '$_tsBase/url_526/193039199_mp4_h264_aac_ld_7.ts',
  '$_tsBase/url_527/193039199_mp4_h264_aac_ld_7.ts',
  '$_tsBase/url_528/193039199_mp4_h264_aac_ld_7.ts',
];

int _passed = 0;
int _failed = 0;

void _ok(String name, [String detail = '']) {
  _passed++;
  stdout.writeln('  [PASS] $name${detail.isEmpty ? '' : ' — $detail'}');
}

void _fail(String name, String reason) {
  _failed++;
  stdout.writeln('  [FAIL] $name — $reason');
}

Future<void> main(List<String> args) async {
  final String mode = args.isEmpty ? 'all' : args.first;
  final Directory work = Directory('${Directory.systemTemp.path}/sniffing-verify');
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);

  stdout.writeln('工作目录: ${work.path}\n');

  final HttpServer server = await _startServer();
  final String base = 'http://127.0.0.1:${server.port}';
  stdout.writeln('本地测试服务: $base\n');

  try {
    if (mode == 'all' || mode == 'file') {
      await _testSingleFile(work);
    }
    if (mode == 'all' || mode == 'hls') {
      await _testHls(work, '$base/plain.m3u8');
    }
    if (mode == 'all' || mode == 'aes') {
      await _testAes(work, '$base/encrypted.m3u8');
    }
  } finally {
    await server.close(force: true);
  }

  stdout.writeln('\n结果: $_passed 通过, $_failed 失败');
  exit(_failed == 0 ? 0 : 1);
}

/// 单文件下载：走 FileDownloader.download，检查 .part 是否清理、大小是否对得上。
Future<void> _testSingleFile(Directory work) async {
  stdout.writeln('[1] 单文件下载');
  final File target = File('${work.path}/single.ts');
  int lastReceived = 0;
  int progressCalls = 0;

  try {
    final File result = await FileDownloader().download(
      url: _segments.first,
      target: target,
      onProgress: (int received, int total) {
        lastReceived = received;
        progressCalls++;
      },
    );

    final int size = await result.length();
    if (size < 50 * 1024) {
      _fail('文件大小', '只有 $size 字节，不像一个 10 秒分片');
    } else {
      _ok('文件落盘', '${(size / 1024).toStringAsFixed(0)} KB');
    }

    final Uint8List head = await _readAt(result, 0, 1);
    if (head.isNotEmpty && head[0] == 0x47) {
      _ok('TS 同步字节', '0x47 正确');
    } else {
      _fail('TS 同步字节', '首字节是 0x${head.isEmpty ? "空" : head[0].toRadixString(16)}');
    }

    if (await File('${target.path}.part').exists()) {
      _fail('.part 清理', '临时文件残留');
    } else {
      _ok('.part 清理', '无残留');
    }

    if (progressCalls > 0 && lastReceived > 0) {
      _ok('进度回调', '$progressCalls 次, 末次 $lastReceived 字节');
    } else {
      _fail('进度回调', '没有收到进度');
    }
  } catch (e) {
    _fail('单文件下载', '$e');
  }
  stdout.writeln('');
}

/// 普通 HLS：3 个分片，验证合并结果能按 TS 包边界对上。
Future<void> _testHls(Directory work, String url) async {
  stdout.writeln('[2] HLS 下载与合并');
  final Directory hlsWork = Directory('${work.path}/hls-work');
  final File output = File('${work.path}/hls-out.ts');
  final List<double> progress = <double>[];

  try {
    final HlsDownloadResult result = await HlsDownloader().download(
      playlistUrl: url,
      workDir: hlsWork,
      output: output,
      onProgress: (HlsProgress p) => progress.add(p.fraction),
    );

    final int size = await output.length();
    if (size < 100 * 1024) {
      _fail('合并输出', '只有 $size 字节');
    } else {
      _ok(
        '合并输出',
        '${(size / 1024).toStringAsFixed(0)} KB, 容器 ${result.container}, '
        '${result.isFmp4 ? "fMP4" : "TS"}',
      );
    }

    if (result.needsRemux) {
      _ok('需要转封装', 'TS 容器，后续可 remux 成 mp4');
    } else {
      _ok('无需转封装', 'fMP4 拼接后已是 mp4');
    }

    if (size % 188 == 0) {
      _ok('TS 包对齐', '$size / 188 = ${size ~/ 188} 个包');
    } else {
      _fail('TS 包对齐', '$size 不是 188 的整数倍，说明拼接有错位');
    }

    if (progress.length > 1 && progress.last >= 1.0) {
      _ok('进度递增', '${progress.length} 次回调, 末值 ${progress.last.toStringAsFixed(2)}');
    } else {
      _fail('进度递增', '回调 ${progress.length} 次, 末值 ${progress.isEmpty ? "-" : progress.last}');
    }

    // 合并结果的开头必须是 TS 包起点；结尾要检查最后一个 188 字节包的起始字节，
    // 而不是文件的最后一个字节——TS 包内任意位置都可能不是 0x47。
    final Uint8List head = await _readAt(output, 0, 1);
    final Uint8List lastPacket = await _readAt(output, size - 188, 1);
    if (head.isNotEmpty && head[0] == 0x47 &&
        lastPacket.isNotEmpty && lastPacket[0] == 0x47) {
      _ok('首尾对齐', '首包和末包都从 0x47 开始');
    } else {
      _fail(
        '首尾对齐',
        '首 0x${head.isEmpty ? "-" : head[0].toRadixString(16)} '
        '末包 0x${lastPacket.isEmpty ? "-" : lastPacket[0].toRadixString(16)}',
      );
    }
  } catch (e) {
    _fail('HLS 下载', '$e');
  }
  stdout.writeln('');
}

/// AES-128：本地把真实分片加密后再提供，验证解密结果与原文逐字节一致。
///
/// 刻意不给 `#EXT-X-KEY` 写 IV，而是靠 `#EXT-X-MEDIA-SEQUENCE` 推导。
/// 这是 RFC 8216 里最容易实现错的一处：IV 写错时解密不报错，只是产出乱码。
Future<void> _testAes(Directory work, String url) async {
  stdout.writeln('[3] HLS + AES-128 解密（IV 由媒体序列号推导）');
  final Directory hlsWork = Directory('${work.path}/aes-work');
  final File output = File('${work.path}/aes-out.ts');

  try {
    await HlsDownloader().download(
      playlistUrl: url,
      workDir: hlsWork,
      output: output,
    );

    final Uint8List actual = await output.readAsBytes();
    final List<Uint8List> plains = await _plainSegments();
    final Uint8List expected = Uint8List.fromList(
      plains.expand((Uint8List p) => p).toList(),
    );

    if (actual.length == expected.length) {
      _ok('解密后长度', '${actual.length} 字节, 与明文一致');
    } else {
      _fail('解密后长度', '期望 ${expected.length}, 实际 ${actual.length}');
    }

    if (actual.length == expected.length && _bytesEqual(actual, expected)) {
      _ok('解密内容', '${plains.length} 个分片逐字节相同');
    } else {
      final int at = _firstDiff(actual, expected);
      _fail('解密内容', '首个差异在偏移 $at，IV 或填充处理有误');
    }

    if (actual.isNotEmpty && actual[0] == 0x47) {
      _ok('解密后 TS 头', '0x47，说明密钥和 IV 都正确');
    } else {
      _fail('解密后 TS 头', '首字节 0x${actual.isEmpty ? "-" : actual[0].toRadixString(16)}，解密结果不是 TS');
    }
  } catch (e) {
    _fail('AES-128 下载', '$e');
  }
  stdout.writeln('');
}

/// 三段互不相同的明文，用来同时验证解密和合并顺序。
/// 每段 188 × 16 字节，既是 TS 包整数倍也是 AES 块整数倍。
const int _plainSize = 188 * 16;
List<Uint8List>? _plainCache;

Future<List<Uint8List>> _plainSegments() async {
  final List<Uint8List>? cached = _plainCache;
  if (cached != null) return cached;
  final List<int> full = await FileDownloader().fetchBytes(
    url: _segments.first,
    headers: const <String, String>{},
  );
  final List<Uint8List> parts = <Uint8List>[
    for (int i = 0; i < 3; i++)
      Uint8List.fromList(full.sublist(i * _plainSize, (i + 1) * _plainSize)),
  ];
  _plainCache = parts;
  return parts;
}

/// 加密用的 IV：不给显式 IV 时，按 RFC 8216 用媒体序列号构造 16 字节大端。
/// 这里独立实现一遍，才能测出主代码是否也理解对了。
Uint8List _ivFromSequence(int sequence) {
  final Uint8List iv = Uint8List(16);
  int value = sequence;
  for (int i = 15; i >= 0 && value > 0; i--) {
    iv[i] = value & 0xFF;
    value >>= 8;
  }
  return iv;
}

/// AES-128-CBC 加密，无填充（HLS 要求分片长度为 16 的倍数）。
Uint8List _encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final CBCBlockCipher cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final Uint8List out = Uint8List(plain.length);
  for (int offset = 0; offset < plain.length; offset += 16) {
    cipher.processBlock(plain, offset, out, offset);
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _firstDiff(Uint8List a, Uint8List b) {
  final int n = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < n; i++) {
    if (a[i] != b[i]) return i;
  }
  return n;
}

Future<Uint8List> _readAt(File file, int offset, int length) async {
  final RandomAccessFile raf = await file.open();
  try {
    await raf.setPosition(offset);
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}

/// 提供三种 playlist：明文、加密、以及本地密钥和分片。
Future<HttpServer> _startServer() async {
  final Uint8List key = Uint8List.fromList(List<int>.generate(16, (int i) => i + 1));
  final List<Uint8List> plains = await _plainSegments();

  // 媒体序列号从 5 开始，三个分片分别是 5 / 6 / 7
  const int mediaSequence = 5;
  final List<Uint8List> encrypted = <Uint8List>[
    for (int i = 0; i < plains.length; i++)
      _encrypt(plains[i], key, _ivFromSequence(mediaSequence + i)),
  ];

  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final String local = 'http://127.0.0.1:${server.port}';

  server.listen((HttpRequest request) async {
    final String path = request.uri.path;
    final HttpResponse res = request.response;

    if (path == '/plain.m3u8') {
      res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      res.write(_buildPlaylist(segments: _segments));
    } else if (path == '/encrypted.m3u8') {
      res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      final StringBuffer sb = StringBuffer()
        ..writeln('#EXTM3U')
        ..writeln('#EXT-X-VERSION:3')
        ..writeln('#EXT-X-TARGETDURATION:10')
        ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
        ..writeln('#EXT-X-MEDIA-SEQUENCE:$mediaSequence')
        // 故意不写 IV：让下载器自己用序列号推导
        ..writeln('#EXT-X-KEY:METHOD=AES-128,URI="$local/key.bin"');
      for (int i = 0; i < plains.length; i++) {
        sb
          ..writeln('#EXTINF:10.0,')
          ..writeln('$local/seg$i.ts');
      }
      sb.writeln('#EXT-X-ENDLIST');
      res.write(sb.toString());
    } else if (path == '/key.bin') {
      res.headers.contentType = ContentType('application', 'octet-stream');
      res.add(key);
    } else if (path.startsWith('/seg') && path.endsWith('.ts')) {
      final int index = int.tryParse(path.substring(4, path.length - 3)) ?? -1;
      if (index < 0 || index >= encrypted.length) {
        res.statusCode = HttpStatus.notFound;
      } else {
        res.headers.contentType = ContentType('video', 'mp2t');
        res.add(encrypted[index]);
      }
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });

  return server;
}

String _buildPlaylist({required List<String> segments}) {
  final StringBuffer sb = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:10')
    ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
  for (final String url in segments) {
    sb
      ..writeln('#EXTINF:10.0,')
      ..writeln(url);
  }
  sb.writeln('#EXT-X-ENDLIST');
  return sb.toString();
}
