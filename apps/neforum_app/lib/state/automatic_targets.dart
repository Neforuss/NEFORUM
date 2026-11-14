import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import 'artwork_targets.dart';

// "Automatic only" in the composer's "Post to" picks the accounts that post
// automatically and whose rules take the post as it is: a words-only post
// leaves out YouTube videos and Odysee, which need a video. The targets then
// follow the post: adding a video adds the accounts that take it now, and
// removing it takes away again the ones NEFORUM added. What the user ticks or
// unticks by hand in that post stays as they left it (ComposerNotifier).

/// How an account came to be in or out of a post whose targets follow the
/// post (Automatic only), by account id in `ComposerState.targetChoices`.
enum TargetChoice {
  /// NEFORUM added it because its rules take the post, and takes it away
  /// again when they no longer do.
  automatic,

  /// The user ticked it: it stays, whatever the post holds.
  ticked,

  /// The user unticked it: NEFORUM does not add it back.
  unticked,
}

/// The accounts "Automatic only" chooses from: enabled, posting automatically
/// (not by hand-off), and the art sites in artwork mode ([artwork]), the
/// other accounts otherwise. The same accounts the picker's quick choices
/// act on.
Iterable<ConnectedAccount> automaticTargetCandidates(List<ConnectedAccount> accounts, AdapterRegistry registry, {required bool artwork}) =>
    accounts.where((a) => a.enabled && a.tier != PlatformTier.handoff && isArtAccount(registry, a) == artwork);

/// Why [d] cannot take a post with [media] (and words, when [hasWords]),
/// in the few words its cell shows ("Needs a video"); null when it can.
///
/// The same rule as the "needs a photo or video" the preview shows, read
/// from the network's media rules ([MediaRules.requiresMedia], the kinds of
/// file it takes): a network that needs a photo or video has one it takes,
/// or gets the post's words as a text card ([textCards], Settings > Text
/// cards) when the post has words and no files. A video site
/// ([PlatformDescriptor.isVideoPlatform]) needs a video, or a sound file it
/// takes; a photo or a card of words is not what it is for. Files NEFORUM
/// made itself ([MediaAttachment.generated]) do not count.
String? automaticSkipReason(PlatformDescriptor d, {required Iterable<MediaAttachment> media, required bool hasWords, required bool textCards}) {
  final rules = d.media;
  final own = media.where((m) => !m.generated).toList();
  bool takes(MediaAttachment m) => m.isVideo
      ? rules.maxVideos > 0
      : m.isAudio
          ? rules.maxAudios > 0 || rules.audioAsVideo
          : rules.maxImages > 0;
  if (d.isVideoPlatform) {
    return own.any((m) => !m.isImage && takes(m)) ? null : 'Needs a video';
  }
  if (!rules.requiresMedia || own.any(takes)) return null;
  if (own.isEmpty && hasWords && textCards && acceptsTextCardImages(d)) return null;
  if (rules.maxImages == 0) return 'Needs a video';
  if (rules.maxVideos == 0) return 'Needs a photo';
  return 'Needs a photo or video';
}
