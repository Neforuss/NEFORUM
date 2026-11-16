// Generates docs/platforms.md from the adapter registry so the support
// matrix never drifts from the code. Run from packages/neforum_core:
//
//   dart run tool/platform_matrix.dart --write            (today's date)
//   dart run tool/platform_matrix.dart --write 2026-11-16 (a given date)
//
// Without --write it prints the page to stdout. --write writes
// ../../docs/platforms.md as UTF-8 with LF line ends (a PowerShell `>`
// would add a byte order mark). test/platform_matrix_test.dart fails when
// the committed page differs from this output, so regenerate after changing
// a descriptor, then run `dart run tool/sync_docs.dart` in apps/neforum_app.

import 'dart:io';

import 'package:neforum_core/neforum_core.dart';

/// Where `--write` puts the page, from packages/neforum_core.
const platformsDocPath = '../../docs/platforms.md';

/// The date in the page's "Generated from the code on ..." line, or null.
String? platformMatrixDate(String page) => RegExp(r'^Generated from the code on (\d{4}-\d{2}-\d{2})\.$', multiLine: true).firstMatch(page)?.group(1);

/// docs/platforms.md for the descriptors of [registry], dated [date].
String renderPlatformMatrix(AdapterRegistry registry, String date) {
  final descriptors = registry.descriptors;
  // Networks whose every post of a thread carries its own photos and videos:
  // media past one post's limit goes in further posts of the thread there.
  final threadMedia = [
    for (final d in descriptors)
      if (d.text.supportsThreads && d.media.mediaPerThreadPart) d.name,
  ];
  final out = StringBuffer()
    ..writeln('# Platform support')
    ..writeln()
    ..writeln('NEFORUM reaches every platform in one of three ways. Each account you connect uses one of them, and you can connect the same platform more than one way.')
    ..writeln()
    ..writeln('- **Auto** (open API): posts automatically. No developer keys, no fees, no review.')
    ..writeln('- **Your keys** (official API with your own developer app): posts automatically within the platform\'s quota. You create a free (or, for X, pay-per-use) developer app once.')
    ..writeln('- **Hand-off**: NEFORUM prepares the post, copies the text and opens the platform\'s app or website; you tap Post. Works with any personal account, even where the API is closed to normal users.')
    ..writeln()
    ..writeln('The **Media** column is what one post holds. More than that is never dropped through Auto and Your keys: '
        'the rest goes in further posts of a thread on ${_list(threadMedia)}, '
        'and in a numbered series of separate posts, one after the other, everywhere else. '
        'A hand-off is one post, and what does not fit is listed in its preview. '
        'An article is always one post with every file its network takes.')
    ..writeln()
    ..writeln('How long each connection lasts, and when you have to step in, is in [How long each sign-in lasts](sign-in-lifetimes.md).')
    ..writeln()
    ..writeln('Generated from the code on $date.')
    ..writeln()
    ..writeln('| Platform | Ways to post | Personal account OK | Text limit | Media | Quotas tracked | Server-side scheduling | Setup guide |')
    ..writeln('|---|---|---|---|---|---|---|---|');

  String tiers(PlatformDescriptor d) => [
        if (d.supportsTier(PlatformTier.openApi)) 'Auto',
        if (d.supportsTier(PlatformTier.byokApi)) 'Your keys',
        if (d.supportsTier(PlatformTier.handoff)) 'Hand-off',
        if (d.supportsTier(PlatformTier.webSession)) 'Web session',
      ].join(', ');

  String text(TextRules t) {
    if (t.maxLength == null) return 'No limit';
    final rule = switch (t.counting) {
      CountingRule.graphemes => 'characters',
      CountingRule.utf16 => 'characters',
      CountingRule.utf8Bytes => 'bytes',
      CountingRule.weightedX => 'weighted (links = 23)',
      CountingRule.codePointsWithUrlWeight => 'characters (links = ${t.urlWeight ?? 23})',
      CountingRule.codePoints => 'characters',
    };
    return '${t.maxLength} $rule${t.supportsThreads ? ', threads' : ''}';
  }

  String media(MediaRules m) {
    if (!m.supportsAnyMedia) return 'Text only';
    // One limit for both kinds together (Parler: 4 photos and videos).
    final together = m.allowsMixedImageVideo && m.maxImages > 0 && m.maxImages == m.maxVideos;
    final parts = together
        ? ['${m.maxImages} images and videos']
        : <String>[
            if (m.maxImages > 0) '${m.maxImages} image${m.maxImages == 1 ? '' : 's'}',
            if (m.maxVideos > 0) '${m.maxVideos} video${m.maxVideos == 1 ? '' : 's'}',
          ];
    return '${parts.join(' or ')}${m.requiresMedia ? ' (required)' : ''}${m.requiresPublicMediaUrl ? ', needs media host for API' : ''}';
  }

  String quotas(PlatformDescriptor d) {
    if (d.defaultQuotas.isEmpty) return '-';
    String window(Duration w) => w.inDays >= 28
        ? 'month'
        : w.inDays >= 1
            ? '${w.inDays == 1 ? '' : '${w.inDays} '}day${w.inDays == 1 ? '' : 's'}'
            : w.inHours >= 1
                ? '${w.inHours} h'
                : w.inMinutes >= 1
                    ? '${w.inMinutes} min'
                    : '${w.inSeconds} s';
    return d.defaultQuotas.map((q) => '${q.limit}/${window(q.window)}').join(', ');
  }

  for (final d in descriptors) {
    final personal = d.personalAccountOk ? 'Yes' : (d.supportsTier(PlatformTier.handoff) ? 'Hand-off only' : 'No');
    final guide = d.setupGuide == null ? '-' : '[${d.id}.md](${d.setupGuide!.replaceFirst('docs/', '')})';
    out.writeln('| ${d.name} | ${tiers(d)} | $personal | ${text(d.text)} | ${media(d.media)} | ${quotas(d)} | ${d.serverSideScheduling ? 'Yes' : '-'} | $guide |');
  }

  out
    ..writeln()
    ..writeln('## Cost and account notes')
    ..writeln();
  for (final d in descriptors) {
    out
      ..writeln('### ${d.name}')
      ..writeln()
      ..writeln('- **Account:** ${d.accountRequirements}')
      ..writeln('- **Cost and limits:** ${d.apiCostSummary}')
      ..writeln();
  }
  return out.toString();
}

/// "A, B, C and D".
String _list(List<String> names) => names.length < 2 ? names.join() : '${names.take(names.length - 1).join(', ')} and ${names.last}';

void main(List<String> args) {
  final write = args.contains('--write');
  final rest = args.where((a) => a != '--write').toList();
  final date = rest.isNotEmpty ? rest.first : DateTime.now().toIso8601String().substring(0, 10);
  final page = renderPlatformMatrix(builtinRegistry(), date);
  if (write) {
    File(platformsDocPath).writeAsStringSync(page);
    stdout.writeln('Wrote $platformsDocPath');
  } else {
    stdout.write(page);
  }
}
