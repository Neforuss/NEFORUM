import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../widgets/layout.dart';

/// Puts [post] in the composer, for editing. The caller then goes to the
/// Compose page. A post already open there keeps the changes made to it.
void openPostInComposer(BuildContext context, WidgetRef ref, Post post) {
  if (ref.read(composerProvider).editingPostId == post.id) return;
  _replaceComposer(context, ref, 'Replaced what you were writing', (composer) => composer.load(post));
}

/// Empties the composer for a new post, with its targets kept.
void startNewPostInComposer(BuildContext context, WidgetRef ref) {
  _replaceComposer(context, ref, 'Cleared what you were writing', (composer) => composer.reset());
}

/// Puts a copy of [post] in the composer, as a new post.
void duplicatePostInComposer(BuildContext context, WidgetRef ref, Post post) {
  _replaceComposer(context, ref, 'Replaced what you were writing', (composer) => composer.duplicate(post));
}

/// Runs [change]. Words that were in the composer can come back: a toast with
/// Undo stays until the composer changes again, which is when an undo would
/// overwrite newer words (see [ComposerNotifier.undoClearPost]).
void _replaceComposer(BuildContext context, WidgetRef ref, String message, void Function(ComposerNotifier composer) change) {
  final composer = ref.read(composerProvider.notifier);
  final before = ref.read(composerProvider);
  change(composer);
  if (!before.hasContent) return;
  final after = ref.read(composerProvider);
  final container = ProviderScope.containerOf(context, listen: false);
  late final ProviderSubscription<ComposerState> watch;
  final toast = showToast(context, message, icon: Icons.edit_note_rounded, actionLabel: 'Undo', onAction: () {
    watch.close();
    composer.undoClearPost(before, after);
  });
  if (toast == null) return;
  watch = container.listen<ComposerState>(composerProvider, (_, next) {
    if (!identical(next, after)) toast.close();
  });
  toast.closed.whenComplete(watch.close);
}
