import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/settings/data/site_rule.dart';

void main() {
  group('域名匹配', () {
    const SiteRule rule = SiteRule(domain: 'example.com');

    test('主域与子域命中，其他域与相似域不命中', () {
      expect(ruleMatches(rule, 'https://example.com/v.mp4'), isTrue);
      expect(ruleMatches(rule, 'https://v.example.com/v.mp4'), isTrue);
      expect(ruleMatches(rule, 'https://a.b.example.com/x'), isTrue);
      expect(ruleMatches(rule, 'https://evil-example.com/x'), isFalse);
      expect(ruleMatches(rule, 'https://example.org/x'), isFalse);
      expect(ruleMatches(rule, 'not a url'), isFalse);
    });

    test('规则域名带大小写与空格时也命中', () {
      const SiteRule messy = SiteRule(domain: ' EXAMPLE.com ');
      expect(ruleMatches(messy, 'https://v.example.com/x'), isTrue);
    });

    test('规则域名为空时不命中', () {
      expect(ruleMatches(const SiteRule(domain: ''), 'https://example.com'), isFalse);
    });
  });

  group('请求头覆盖', () {
    test('命中的规则覆盖 UA、Referer 与同名头，未命中的规则不生效', () {
      const SiteRule target = SiteRule(
        domain: 'example.com',
        userAgent: 'CustomUA/1.0',
        referer: 'https://custom.example/',
        headers: <String, String>{
          'X-Token': 'abc',
          'referer': 'https://override.example/',
        },
      );
      const SiteRule other = SiteRule(
        domain: 'other.com',
        userAgent: 'ShouldNotApply',
      );

      final Map<String, String> result = applySiteRules(
        <String, String>{
          'User-Agent': 'Original',
          'Referer': 'https://original.example/',
          'X-Token': 'old',
          'Keep-Me': 'yes',
        },
        'https://v.example.com/video.mp4',
        const <SiteRule>[other, target],
      );

      expect(result['User-Agent'], 'CustomUA/1.0');
      // headers 里的 referer 是后套的，通过设置项删同名再加，最终只留一个。
      expect(result['referer'], 'https://override.example/');
      expect(
        result.keys.where((String k) => k.toLowerCase() == 'referer').length,
        1,
      );
      expect(result['X-Token'], 'abc');
      expect(result['Keep-Me'], 'yes');
    });

    test('空值项不覆盖原请求头', () {
      const SiteRule rule = SiteRule(domain: 'example.com');
      final Map<String, String> original = <String, String>{
        'User-Agent': 'Original',
        'Referer': 'https://original.example/',
      };

      final Map<String, String> result = applySiteRules(
        original,
        'https://example.com/x',
        const <SiteRule>[rule],
      );

      expect(result['User-Agent'], 'Original');
      expect(result['Referer'], 'https://original.example/');
      // 没真正改动时返回原实例，调用方可以据此跳过后续处理。
      expect(identical(result, original), isTrue);
    });
  });

  group('序列化', () {
    test('规则往返不丢字段', () {
      const SiteRule rule = SiteRule(
        domain: 'example.com',
        userAgent: 'UA',
        referer: 'https://ref.example/',
        headers: <String, String>{'X-Token': 'abc'},
      );

      final SiteRule restored = SiteRule.fromJson(rule.toJson());
      expect(restored.domain, rule.domain);
      expect(restored.userAgent, rule.userAgent);
      expect(restored.referer, rule.referer);
      expect(restored.headers, rule.headers);
    });
  });
}
