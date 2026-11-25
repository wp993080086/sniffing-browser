import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/downloader/data/file_downloader.dart';

void main() {
  test('只有 CookieManager 那份时原样搬过来', () {
    expect(mergeCookies(null, 'a=1; b=2'), <String, String>{
      'a': '1',
      'b': '2',
    });
  });

  test('同名以嗅探到的为准', () {
    final Map<String, String> merged = mergeCookies(
      'token=new',
      'token=old; sid=x',
    );

    expect(merged['token'], 'new');
    expect(merged['sid'], 'x');
  });

  test('两份各有独有项时都保留', () {
    expect(mergeCookies('token=new', 'sid=x'), <String, String>{
      'sid': 'x',
      'token': 'new',
    });
  });

  test('空值与非法片段被丢掉，不影响合法项', () {
    expect(mergeCookies(null, ''), isEmpty);
    expect(mergeCookies(null, 'bad; =v; ok=1'), <String, String>{'ok': '1'});
  });

  test('值里带等号不会被截断', () {
    expect(mergeCookies(null, 'sig=ab=cd')['sig'], 'ab=cd');
  });
}
