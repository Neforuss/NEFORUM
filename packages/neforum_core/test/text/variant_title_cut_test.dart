// B5: a title cut to a network's limit never ends in half an emoji.
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

bool hasLoneSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 >= s.length) return true;
      final v = s.codeUnitAt(i + 1);
      if (v < 0xDC00 || v > 0xDFFF) return true;
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

void main() {
  PlatformDescriptor titled({bool threads = false, int max = 11}) => PlatformDescriptor(
        id: 'titled',
        name: 'Titled',
        tiers: const {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(maxLength: threads ? 10 : 10000, supportsThreads: threads, titleSupported: true, titleRequired: true, titleMax: max),
        media: const MediaRules(),
        accountRequirements: '',
        apiCostSummary: '',
      );

  PostVariant resolve(String text, PlatformDescriptor d, {String? title}) {
    final post = Post(id: 'p', text: text, title: title, createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'acct-1')]);
    return const VariantResolver().resolve(post, post.targets.single, d, account: fakeAccount(d.id));
  }

  test('a derived title cut at an emoji stays whole', () {
    // UTF-16 unit 10 falls inside the emoji: substring would keep half of it.
    final v = resolve('123456789\u{1F600}abc', titled());
    expect(hasLoneSurrogate(v.title!), isFalse);
    expect(v.title, '123456789…');
    expect(v.title!.length, lessThanOrEqualTo(11));
  });

  test('a family is not cut apart', () {
    final v = resolve('12345678\u{1F468}‍\u{1F469}‍\u{1F467}', titled());
    expect(v.title, '12345678…');
  });

  test('a title that fits is left alone', () {
    expect(resolve('1234\u{1F600}', titled()).title, '1234\u{1F600}');
  });

  test('a numbered title cut at an emoji stays whole', () {
    // A long text splits into a series, each post with its number in the title.
    final d = titled(threads: true, max: 14);
    final v = resolve('one two three four five six seven eight nine ten', d, title: '12345\u{1F600}\u{1F600}\u{1F600}');
    final titles = [v.title, ...v.threadParts.map((_) => v.title)];
    for (final t in titles) {
      if (t != null) expect(hasLoneSurrogate(t), isFalse, reason: t);
    }
  });
}
