import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// HLS 的 AES-128 解密。
///
/// 只有 `METHOD=AES-128` 是能纯 Dart 处理的（CBC + PKCS7）。
/// `SAMPLE-AES` 需要完整的解密器，直接抛错比静默产出损坏文件好。
class AesDecryptor {
  const AesDecryptor._();

  static const int _blockSize = 16;

  /// [key] 必须是 16 字节，[iv] 必须是 16 字节。
  static Uint8List decrypt({
    required Uint8List data,
    required Uint8List key,
    required Uint8List iv,
  }) {
    if (key.length != _blockSize) {
      throw ArgumentError('AES-128 的 key 必须是 16 字节，实际 ${key.length}');
    }
    if (iv.length != _blockSize) {
      throw ArgumentError('IV 必须是 16 字节，实际 ${iv.length}');
    }
    if (data.isEmpty) return Uint8List(0);
    if (data.length % _blockSize != 0) {
      throw ArgumentError('密文长度 ${data.length} 不是 16 的整数倍，数据可能已损坏');
    }

    final CBCBlockCipher cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));

    final Uint8List output = Uint8List(data.length);
    for (int offset = 0; offset < data.length; offset += _blockSize) {
      cipher.processBlock(data, offset, output, offset);
    }

    return _stripPkcs7(output);
  }

  /// 去掉 PKCS7 填充。
  ///
  /// 有些站点的分片并不严格带填充（或者末块被截断），严格校验会整个任务失败。
  /// 这里只在“填充格式确实合法”时才裁剪，否则原样返回。
  static Uint8List _stripPkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final int padLength = data.last;
    if (padLength <= 0 || padLength > _blockSize || padLength > data.length) {
      return data;
    }
    for (int i = data.length - padLength; i < data.length; i++) {
      if (data[i] != padLength) return data;
    }
    return Uint8List.sublistView(data, 0, data.length - padLength);
  }

  /// 未显式给定 IV 时，按 RFC 8216：IV = 媒体序列号，16 字节大端，高位补零。
  ///
  /// 这一处写错会导致解密结果全是乱码，而且不会报错 —— 是最难排查的坑之一。
  static Uint8List ivFromSequence(int sequence) {
    final Uint8List iv = Uint8List(_blockSize);
    int value = sequence;
    for (int i = _blockSize - 1; i >= 0 && value > 0; i--) {
      iv[i] = value & 0xFF;
      value >>= 8;
    }
    return iv;
  }

  /// "0x00010203..." -> [0,1,2,3,...]
  static Uint8List hexToBytes(String hex) {
    String cleaned = hex.trim();
    if (cleaned.toLowerCase().startsWith('0x')) {
      cleaned = cleaned.substring(2);
    }
    if (cleaned.length.isOdd) cleaned = '0$cleaned';
    final Uint8List result = Uint8List(cleaned.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
