import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  group('a host part over 63 characters is not an address', () {
    test('ASCII, with a scheme', () {
      final long = 'a' * 64;
      expect(UrlDetector.find('https://$long.com/foo'), isEmpty);
      expect(UrlDetector.find('https://${'a' * 63}.com/foo').single.text, 'https://${'a' * 63}.com/foo');
    });

    test('a valid link beside it is still found', () {
      final found = UrlDetector.find('https://${'a' * 64}.com/foo https://validurl.com');
      expect(found.map((u) => u.text), ['https://validurl.com']);
    });

    test('a port, a user and a query do not count against the host', () {
      expect(UrlDetector.find('https://me@example.com:8443/${'p' * 100}?q=${'q' * 100}').length, 1);
    });

    test('non-ASCII parts are measured in their xn-- form', () {
      // The two sides of twitter-text's own boundary.
      const under = 'あいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあい';
      expect(UrlDetector.find('http://$under.com').length, 1);
      expect(UrlDetector.find('http://$underう.com'), isEmpty);
    });
  });

  test('Punycode lengths match RFC 3492 results', () {
    // "bücher" is xn--bcher-kva; "münchen" is xn--mnchen-3ya; "ليهمابتكلموشعربي؟"
    // is RFC 3492's sample A, egbpdaj6bu4bxfgehfvwxn.
    expect(UrlDetector.punycodeLength('bücher'), 'bcher-kva'.length);
    expect(UrlDetector.punycodeLength('münchen'), 'mnchen-3ya'.length);
    expect(UrlDetector.punycodeLength('ليهمابتكلموشعربي؟'), 'egbpdaj6bu4bxfgehfvwxn'.length);
  });

  test('a link ends at a direction mark', () {
    final found = UrlDetector.find('⁦‪http://foobar.example/‬⁩').single;
    expect(found.text, 'http://foobar.example/');
  });
}
