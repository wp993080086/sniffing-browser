import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/browser/data/nav_guard.dart';

/// 判定用的时间基准。真实时间不影响结果，只关心差值。
const int _now = 1700000000000;

void main() {
  NavGuard guard() => NavGuard();

  NavVerdict run(
    NavGuard guard, {
    required String url,
    required String currentUrl,
    bool hasUserGesture = false,
    bool enabled = true,
    int now = _now,
  }) {
    return guard.decide(
      url: url,
      currentUrl: currentUrl,
      hasUserGesture: hasUserGesture,
      enabled: enabled,
      nowMs: now,
    );
  }

  group('NavGuard', () {
    test('站内跳转一律放行', () {
      expect(
        run(
          guard(),
          url: 'https://missav.live/cn/2',
          currentUrl: 'https://missav.live/cn/1',
        ),
        NavVerdict.allow,
      );
    });

    test('没有任何点击的跨站跳转隔离', () {
      // popunder / meta refresh / 定时器跳转的形态。
      expect(
        run(
          guard(),
          url: 'https://wheelroot.com/landing',
          currentUrl: 'https://missav.live/cn/1',
        ),
        NavVerdict.isolate,
      );
    });

    test('点了链接、目标与链接同站，放行', () {
      final NavGuard g = guard();
      g.noteTap(href: 'https://example.com/a', atMs: _now);
      expect(
        run(
          g,
          url: 'https://example.com/b',
          currentUrl: 'https://missav.live/cn/1',
        ),
        NavVerdict.allow,
      );
    });

    test('点了链接、目标却是别的站，隔离', () {
      // 点一次播放被顶到广告站，就是这个形态。
      final NavGuard g = guard();
      g.noteTap(href: 'https://missav.live/cn/1', atMs: _now);
      expect(
        run(
          g,
          url: 'https://wheelroot.com/landing',
          currentUrl: 'https://missav.live/cn/1',
        ),
        NavVerdict.isolate,
      );
    });

    test('点的是按钮（无链接）时给一跳机会，第二跳隔离', () {
      final NavGuard g = guard();
      g.noteTap(href: '', atMs: _now);
      expect(
        run(
          g,
          url: 'https://example.com/a',
          currentUrl: 'https://missav.live/cn/1',
        ),
        NavVerdict.allow,
      );
      expect(
        run(
          g,
          url: 'https://vendor.net/b',
          currentUrl: 'https://example.com/a',
        ),
        NavVerdict.isolate,
      );
    });

    test('点击超出时间窗后不再算作这次导航的起因', () {
      final NavGuard g = guard();
      g.noteTap(href: 'https://example.com/a', atMs: _now);
      expect(
        run(
          g,
          url: 'https://wheelroot.com/landing',
          currentUrl: 'https://missav.live/cn/1',
          now: _now + NavGuard.gestureWindow.inMilliseconds + 1,
        ),
        NavVerdict.isolate,
      );
    });

    test('原生声明有点击、页面没上报时不隔离', () {
      // 脚本还没注入、或点的是 video 控件，宁可放行。
      expect(
        run(
          guard(),
          url: 'https://example.com/a',
          currentUrl: 'https://missav.live/cn/1',
          hasUserGesture: true,
        ),
        NavVerdict.allow,
      );
    });

    test('关掉隔离后任何跨站都放行', () {
      expect(
        run(
          guard(),
          url: 'https://wheelroot.com/landing',
          currentUrl: 'https://missav.live/cn/1',
          enabled: false,
        ),
        NavVerdict.allow,
      );
    });

    test('新一次点击重置一跳机会', () {
      final NavGuard g = guard();
      g.noteTap(href: '', atMs: _now);
      run(g, url: 'https://example.com/a', currentUrl: 'https://missav.live/1');
      g.noteTap(href: '', atMs: _now + 100);
      expect(
        run(
          g,
          url: 'https://example.org/b',
          currentUrl: 'https://example.com/a',
          now: _now + 100,
        ),
        NavVerdict.allow,
      );
    });

    group('弹窗中转页', () {
      test('同站的 /pop?url=外站 也隔离', () {
        // 真机日志里的形态：正片页被脚本跳到 pop 页，再由那页跳广告。
        expect(
          run(
            guard(),
            url:
                'https://missav.ws/pop?url=https%3A%2F%2Ftsyndicate.com'
                '%2Fapi%2Fv1%2Fdirect%2Fc65c80b',
            currentUrl: 'https://missav.ws/snos-461',
          ),
          NavVerdict.isolate,
        );
      });

      test('url 参数指向本站时照常放行', () {
        expect(
          run(
            guard(),
            url: 'https://missav.ws/pop?url=https%3A%2F%2Fmissav.ws%2Fcn%2F2',
            currentUrl: 'https://missav.ws/cn/1',
          ),
          NavVerdict.allow,
        );
      });

      test('没有 url 参数的普通页面不误判', () {
        expect(
          run(
            guard(),
            url: 'https://missav.ws/popular',
            currentUrl: 'https://missav.ws/cn/1',
          ),
          NavVerdict.allow,
        );
      });
    });
  });
}
