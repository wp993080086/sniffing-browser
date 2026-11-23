import 'dart:io';

/// 分片先写临时名、再 rename 成 `.part`。
///
/// 直接写 `.part` 时，进程被杀或取消落在写盘窗口会留下截断文件；
/// 下次续传只看「存在且非空」，会把截断分片当完整分片合并，
/// 产出能打开但静默损坏的视频。同目录 rename 是原子的，
/// 要么看到完整分片，要么什么都没有。
Future<void> writeSegmentAtomically(File target, List<int> bytes) async {
  final File temp = File('${target.path}.writing');
  // 目标长度为 0 的残留也要先删，免得某些平台 rename 到已存在路径会失败。
  if (await target.exists()) await target.delete();
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(target.path);
}
