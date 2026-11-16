import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/article_mode.dart';
import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../accounts/guide_sheet.dart';

/// 1.4.4: articles. The names of the selected networks that take an article
/// ([takesArticle]: the blogs, Tumblr, Substack), one each, in the order of
/// the accounts. Article mode is offered while there is one.
final articleNetworksProvider = Provider<List<String>>((ref) {
  final selected = ref.watch(composerProvider.select((c) => c.selected));
  final registry = ref.watch(registryProvider);
  final names = <String>[];
  for (final a in ref.watch(accountListProvider)) {
    if (!selected.contains(a.id)) continue;
    final adapter = registry.byId(a.platformId);
    if (adapter == null) continue;
    final d = adapter.descriptorForAccount(a);
    if (takesArticle(d) && !names.contains(d.name)) names.add(d.name);
  }
  return names;
});

/// "Post" or "Article" above the composer: shown while a network that takes
/// articles is selected, or while the post is an article. Switching keeps
/// everything written (see [ComposerNotifier.enterArticleMode]).
class ArticleModeSwitch extends ConsumerWidget {
  const ArticleModeSwitch({super.key, this.underPost = false});

  /// Under the post's text fields instead of above them: where the account
  /// grid is open, the room between the grid and the text field is the
  /// field's, so the switch goes under the post (as Publishing order does).
  final bool underPost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final article = ref.watch(composerProvider.select((c) => c.isArticle));
    final networks = ref.watch(articleNetworksProvider);
    if (!article && networks.isEmpty) return const SizedBox.shrink();
    final notifier = ref.read(composerProvider.notifier);
    final names = networks.length <= 3 ? networks.join(', ') : '${networks.take(2).join(', ')} and ${networks.length - 2} more';
    return Padding(
      padding: underPost ? const EdgeInsets.only(top: Space.lg) : const EdgeInsets.only(bottom: Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<bool>(
            key: const ValueKey('article-mode-switch'),
            segments: const [
              ButtonSegment(value: false, label: Text('Post'), icon: Icon(Icons.short_text_rounded, size: 18)),
              ButtonSegment(value: true, label: Text('Article'), icon: Icon(Icons.article_outlined, size: 18)),
            ],
            selected: {article},
            showSelectedIcon: false,
            onSelectionChanged: (s) => s.first ? notifier.enterArticleMode() : notifier.leaveArticleMode(),
          ),
          TextButton.icon(
            key: const ValueKey('article-guide'),
            onPressed: () => showGuideSheet(context, 'articles', asset: 'articles.md'),
            icon: const Icon(Icons.help_outline_rounded, size: 16),
            label: const Text('How articles work'),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
          ),
        ]),
        const SizedBox(height: Space.xs + 2),
        Text(
          article
              ? networks.isEmpty
                  ? 'No selected network takes articles: every network gets the short version.'
                  : '$names ${networks.length == 1 ? 'gets' : 'get'} the article. The other networks get its short version.'
              : 'Write an article for $names: headings, photos between paragraphs, a cover and more.',
          style: context.text.bodySmall?.copyWith(color: nf.textMuted),
        ),
      ]),
    );
  }
}
