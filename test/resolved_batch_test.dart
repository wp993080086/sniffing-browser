import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/resolver/domain/resolved_batch.dart';
import 'package:sniffing_browser/features/resolver/domain/resolved_video.dart';

ResolvedVideo _video(String id, {String? url}) => ResolvedVideo(
  url: url ?? 'https://v.douyin.com/$id.mp4',
  title: '标题 $id',
  videoId: id,
);

void main() {
  test('同 videoId 只收一条，默认勾选', () {
    final ResolvedBatch batch = ResolvedBatch();

    expect(batch.add(_video('1')), isTrue);
    expect(batch.add(_video('1', url: 'https://other.mp4')), isFalse);
    expect(batch.videos.length, 1);
    expect(batch.selected.length, 1);
    expect(batch.isSelectedAll, isTrue);
  });

  test('无 videoId 时按 url 去重', () {
    final ResolvedBatch batch = ResolvedBatch();
    final ResolvedVideo a = ResolvedVideo(
      url: 'https://v.douyin.com/a.mp4',
      title: 'a',
    );

    expect(batch.add(a), isTrue);
    expect(batch.add(a), isFalse);
    expect(batch.videos.length, 1);
  });

  test('不可用直链不入集合', () {
    final ResolvedBatch batch = ResolvedBatch();

    expect(batch.add(ResolvedVideo(url: '', title: '空链')), isFalse);
    expect(batch.add(ResolvedVideo(url: 'relative/path.mp4', title: '相对')), isFalse);
    expect(batch.isEmpty, isTrue);
  });

  test('取消勾选后 selected 不含它，全选/清空生效', () {
    final ResolvedBatch batch = ResolvedBatch()
      ..add(_video('1'))
      ..add(_video('2'));
    final ResolvedVideo first = batch.videos.first;

    batch.toggle(first);
    expect(batch.isSelected(first), isFalse);
    expect(batch.selected.length, 1);
    expect(batch.isSelectedAll, isFalse);

    batch.selectAll(true);
    expect(batch.selected.length, 2);
    batch.selectAll(false);
    expect(batch.selected, isEmpty);

    batch.clear();
    expect(batch.isEmpty, isTrue);
  });
}
