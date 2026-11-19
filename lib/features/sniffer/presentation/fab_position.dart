import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 嗅探悬浮按钮的位置。
///
/// **只存内存**：用户要求「杀掉应用就回默认右下角」，所以刻意不落盘。
/// 记的是按钮左上角在网页区域内的坐标；null 表示还没拖过，用默认位置。
class SniffFabPosition extends ChangeNotifier {
  Offset? _offset;

  Offset? get offset => _offset;

  void update(Offset value) {
    if (_offset == value) return;
    _offset = value;
    notifyListeners();
  }

  /// 旋转屏幕 / 窗口缩放后原坐标可能跑到区域外，复位回默认更省事。
  void reset() {
    if (_offset == null) return;
    _offset = null;
    notifyListeners();
  }
}

final ChangeNotifierProvider<SniffFabPosition> sniffFabPositionProvider =
    ChangeNotifierProvider<SniffFabPosition>(
        (Ref ref) => SniffFabPosition());
