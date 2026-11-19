import 'dart:async';

/// 串行闸门：同一时刻只让一个任务跑，其余排队。
///
/// 给视频抽帧用。桌面每次抽帧都要起一个 ffmpeg 进程，Android 每次都要打开
/// 媒体源读头；资源列表里几十个 mp4 同时进来会把 CPU 打满，反而让整个列表卡住。
/// 串行只影响抽帧自己（晚一点出图），不影响列表滚动。
///
/// 关键点是**异常不能把队伍卡死**：前一个任务抛错，后一个照样要能跑。
class SerialGate {
  SerialGate();

  Future<void> _tail = Future<void>.value();

  /// 未完成的任务数（含正在跑的那个），测试与诊断用。
  int _waiting = 0;
  int get waiting => _waiting;

  Future<T> run<T>(Future<T> Function() task) {
    _waiting++;
    final Future<T> result = _tail.then((_) => task());
    // 接链条的时候把错误吞掉，否则一次失败会让后面所有任务跟着报错。
    _tail = result.then<void>(
      (_) => _waiting--,
      onError: (Object _) => _waiting--,
    );
    return result;
  }
}
