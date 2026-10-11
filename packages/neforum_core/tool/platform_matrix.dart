// Generates docs/platforms.md from the adapter registry so the support
// matrix never drifts from the code.
//
//   dart run tool/platform_matrix.dart > ../../docs/platforms.md

import 'dart:io';

import 'package:neforum_core/neforum_core.dart';

void main(List<String> args) {
  final date = args.isNotEmpty ? args.first : DateTime.now().toIso8601String().substring(0, 10);
  final r = builtinRegistry();
  final out = StringBuffer()
    ..writeln('# Platform support')
    ..writeln()
    ..writeln('NEFORUM reaches every platform in one of three ways. Each account you connect uses one of them, and you can connect the same platform more than one way.')
    ..writeln()
    ..writeln('- **Auto** (open API): posts automatically. No developer keys, no fees, no review.')
    ..writeln('- **Your keys** (official API with your own developer app): posts automatically within the platform\'s quota. You create a free (or, for X, pay-per-use) developer app once.')
    ..writeln('- **Hand-off**: NEFORUM prepares the post, copies the text and opens the platform\'s app or website; you tap Post. Works with any personal account, even where the API is closed to normal users.')
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
    };
    return '${t.maxLength} $rule${t.supportsThreads ? ', threads' : ''}';
  }

  String media(MediaRules m) {
    if (!m.supportsAnyMedia) return 'Text only';
    final parts = <String>[
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

  for (final d in r.descriptors) {
    final personal = d.personalAccountOk ? 'Yes' : (d.supportsTier(PlatformTier.handoff) ? 'Hand-off only' : 'No');
    final guide = d.setupGuide == null ? '-' : '[${d.id}.md](${d.setupGuide!.replaceFirst('docs/', '')})';
    out.writeln('| ${d.name} | ${tiers(d)} | $personal | ${text(d.text)} | ${media(d.media)} | ${quotas(d)} | ${d.serverSideScheduling ? 'Yes' : '-'} | $guide |');
  }

  out
    ..writeln()
    ..writeln('## Cost and account notes')
    ..writeln();
  for (final d in r.descriptors) {
    out
      ..writeln('### ${d.name}')
      ..writeln()
      ..writeln('- **Account:** ${d.accountRequirements}')
      ..writeln('- **Cost and limits:** ${d.apiCostSummary}')
      ..writeln();
  }
  stdout.write(out.toString());
}
