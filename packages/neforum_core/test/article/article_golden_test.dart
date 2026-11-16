// Golden output of every article serializer for one fixed rich document
// (test/support/article_fixture.dart): the exact bytes each network gets,
// and the report of what it cannot carry. Run with NEFORUM_UPDATE_GOLDENS=1
// to write the files again after a deliberate change, then read the diff.
import 'dart:convert';
import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/article_fixture.dart';

String _show(Object output) => output is String ? output : const JsonEncoder.withIndent('  ').convert(output);

String _golden(ArticleRender<Object> r) => [
      _show(r.output),
      '',
      '---- report',
      for (final i in r.report.issues) '${i.outcome.name} ${i.code} ${i.blockId ?? i.field ?? '-'}: ${i.message}',
      '',
    ].join('\n');

void main() {
  final update = Platform.environment['NEFORUM_UPDATE_GOLDENS'] == '1';
  final cases = <String, ArticleRender<Object> Function()>{
    'wordpress_gutenberg': () => renderGutenberg(richArticle, richAssets()),
    'ghost_html': () => renderGhostHtml(richArticle, richAssets()),
    'emdash_portable_text': () => renderPortableText(richArticle, richAssets(remoteId: (i, m) => 'em-${m.id}'), keyPrefix: 'nfk'),
    'devto_markdown': () => renderMarkdown(richArticle, richAssets(), dialect: ArticleMarkdownDialect.devto, network: 'DEV Community'),
    'hashnode_markdown': () => renderMarkdown(richArticle, richAssets(), dialect: ArticleMarkdownDialect.hashnode, network: 'Hashnode'),
    'writefreely_markdown': () => renderMarkdown(richArticle, richAssets(),
        dialect: ArticleMarkdownDialect.writeFreely, network: 'Write.as / WriteFreely', tags: const ['dart', 'Open Source']),
    'micropub_html': () => renderSemanticHtml(richArticle, richAssets(), network: 'Micropub', fields: ArticleRenderer.micropubFields),
    'tumblr_npf': () => renderNpf(richArticle, richAssets(remoteId: (i, m) => 'media$i'), title: 'Rich title'),
    'x_article': () => renderXArticle(richArticle, richAssets(remoteId: (i, m) => '${1900000000000000000 + i}'), title: 'Rich title'),
    'handoff_html': () {
      final h = ArticleRenderer.handoff(richArticle, network: 'Substack', media: richMedia());
      return ArticleRender<Object>('${h.html}\n\n---- markdown\n${h.markdown}', h.report);
    },
  };
  for (final e in cases.entries) {
    test('golden: ${e.key}', () {
      final file = File('test/fixtures/article/${e.key}.golden');
      final actual = _golden(e.value());
      if (update || !file.existsSync()) {
        file
          ..createSync(recursive: true)
          ..writeAsStringSync(actual);
        if (!update) fail('${file.path} was missing and has been written; check it and run again');
      }
      expect(actual, file.readAsStringSync().replaceAll('\r\n', '\n'));
    });
  }
}
