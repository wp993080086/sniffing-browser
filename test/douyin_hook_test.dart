import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/resolver/data/douyin_hook.dart';
import 'package:sniffing_browser/features/resolver/domain/resolved_video.dart';

void main() {
  group('分享文案里挑链接', () {
    test('整段分享文案里取出短链', () {
      const String share =
          '7.42 复制打开抖音，看看【问心影视的作品】海氏与长柏的婚姻最大的功臣竟是孔嬷嬷 '
          'https://v.douyin.com/4KipZaBWnOk/ q@e.ba 07/28 ZzG:/ 复制此链接，打开抖音搜索';

      expect(DouyinHook.extractUrl(share), 'https://v.douyin.com/4KipZaBWnOk/');
    });

    test('纯链接原样返回', () {
      expect(
        DouyinHook.extractUrl('  https://www.douyin.com/video/7572924669025391222  '),
        'https://www.douyin.com/video/7572924669025391222',
      );
    });

    test('剥掉链接尾部的英文标点', () {
      expect(
        DouyinHook.extractUrl('看这个 https://v.douyin.com/abc/)。'),
        'https://v.douyin.com/abc/',
      );
    });

    test('一次粘多条时只认抖音那条', () {
      const String text =
          '先看这个 https://example.com/x 再看 https://www.iesdouyin.com/share/video/123456789/';
      expect(
        DouyinHook.extractUrl(text),
        'https://www.iesdouyin.com/share/video/123456789/',
      );
    });

    test('没带协议的裸域名也能识别', () {
      expect(DouyinHook.extractUrl('v.douyin.com/iRabc/'), 'https://v.douyin.com/iRabc/');
    });

    test('非抖音链接、空串、纯文字一律返回 null', () {
      expect(DouyinHook.extractUrl('https://www.bilibili.com/video/BV1xx'), isNull);
      expect(DouyinHook.extractUrl('   '), isNull);
      expect(DouyinHook.extractUrl('随便一句话没有链接'), isNull);
    });
  });

  group('域名与 id', () {
    test('抖音的几个域名都算', () {
      expect(DouyinHook.isDouyinUrl('https://www.douyin.com/video/1'), isTrue);
      expect(DouyinHook.isDouyinUrl('https://v.douyin.com/abc/'), isTrue);
      expect(DouyinHook.isDouyinUrl('https://www.iesdouyin.com/share/video/1/'), isTrue);
      expect(DouyinHook.isDouyinUrl('https://douyin.com.evil.cn/video/1'), isFalse);
      expect(DouyinHook.isDouyinUrl('not a url'), isFalse);
    });

    test('从视频页地址里抠出 aweme_id', () {
      expect(
        DouyinHook.awemeId('https://www.douyin.com/video/7572924669025391222?x=1'),
        '7572924669025391222',
      );
      // 短链里没有 id，解析前不应该瞎猜。
      expect(DouyinHook.awemeId('https://v.douyin.com/4KipZaBWnOk/'), isNull);
    });

    test('分享页地址按 id 拼出来', () {
      expect(
        DouyinHook.shareUrl('123456789'),
        'https://www.iesdouyin.com/share/video/123456789/',
      );
    });
  });

  group('解析结果', () {
    test('字段齐全时各项都对', () {
      final ResolvedVideo video = ResolvedVideo.fromJson(<String, Object?>{
        'url': 'https://v3-web.douyinvod.com/x/video.mp4',
        'title': '测试视频',
        'author': '某某',
        'cover': 'https://p3.douyinpic.com/cover.jpg',
        'size': 56023427,
        'duration': 356000,
        'id': '7572924669025391222',
      });

      expect(video.isUsable, isTrue);
      expect(video.displayName, '测试视频');
      expect(video.sizeLabel, '53.4 MB');
      expect(video.durationLabel, '5:56');
      expect(video.subtitle, '某某 · 5:56 · 53.4 MB');
      // 文件名带作者，下载目录里能直接认出来源。
      expect(video.fileName, contains('某某 - 测试视频'));
      expect(video.fileName, endsWith('.mp4'));
    });

    test('字段缺失或类型不对时退回默认值，不抛异常', () {
      final ResolvedVideo video = ResolvedVideo.fromJson(<String, Object?>{
        'url': 'https://x.example/v.mp4',
        'size': '0',
        'duration': null,
      });

      expect(video.isUsable, isTrue);
      expect(video.title, isEmpty);
      expect(video.displayName, '抖音视频');
      expect(video.sizeLabel, isEmpty);
      expect(video.subtitle, isEmpty);
      expect(video.fileName, '抖音视频.mp4');
    });

    test('没有 http 前缀的地址不算可用', () {
      expect(
        ResolvedVideo.fromJson(<String, Object?>{'url': 'video.mp4'}).isUsable,
        isFalse,
      );
    });

    test('超长标题按文件名规则截断', () {
      final ResolvedVideo video = ResolvedVideo.fromJson(<String, Object?>{
        'url': 'https://x.example/v.mp4',
        'title': '标题' * 200,
      });
      expect(video.fileName.length, lessThanOrEqualTo(120));
      expect(video.fileName, endsWith('.mp4'));
    });
  });
}
