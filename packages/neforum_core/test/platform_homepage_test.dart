// NEFORUM 1.4.2: the platform gallery (Accounts > Add account) links each
// platform's own site, so someone without an account there can make one
// first. Every descriptor must name it.
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  final descriptors = builtinRegistry().descriptors;

  test('every platform names its site, as an https address with a host', () {
    final missing = [for (final d in descriptors) if (d.homepage == null) d.id];
    expect(missing, isEmpty, reason: 'no homepage: $missing');
    for (final d in descriptors) {
      final u = Uri.parse(d.homepage!);
      expect(u.scheme, 'https', reason: d.id);
      expect(u.host, isNotEmpty, reason: d.id);
      expect(u.userInfo, isEmpty, reason: d.id);
      expect(u.hasQuery, isFalse, reason: '${d.id}: a plain address, no tracking or query');
    }
  });

  test('the site is where a person makes an account, not a developer page', () {
    final byId = {for (final d in descriptors) d.id: Uri.parse(d.homepage!)};
    for (final d in descriptors) {
      final host = byId[d.id]!.host;
      expect(host, isNot(anyOf(startsWith('developer'), startsWith('developers'), startsWith('api.'), startsWith('docs.'))), reason: d.id);
    }
    // The ones the user named, and the hosted service of the two-name platforms.
    expect(byId['tumblr']!.host, 'www.tumblr.com');
    expect(byId['facebook']!.host, 'www.facebook.com');
    expect(byId['writefreely']!.host, 'write.as');
    expect(byId['wordpress']!.host, 'wordpress.com');
  });
}
