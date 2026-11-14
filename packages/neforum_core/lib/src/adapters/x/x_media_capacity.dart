import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../text/media_packer.dart';

/// What X answered the last time an account posted more photos and videos in
/// one post than the classic limit (4 photos or 1 video), kept in the
/// account's config under [XMediaCapacity.configKey].
class XLargeMediaRecord {
  const XLargeMediaRecord({required this.accepted, required this.at});

  final bool accepted;
  final DateTime at;

  static XLargeMediaRecord? fromConfig(ConnectedAccount account) {
    final raw = account.config[XMediaCapacity.configKey];
    if (raw is! Map) return null;
    final result = raw['result'];
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null || (result != 'accepted' && result != 'refused')) return null;
    return XLargeMediaRecord(accepted: result == 'accepted', at: at.toUtc());
  }

  Map<String, Object?> toConfig() => {'result': accepted ? 'accepted' : 'refused', 'at': at.toUtc().toIso8601String()};
}

/// How many photos and videos one X post carries: the one place that says
/// it, for packing ([PlatformDescriptor.media] of the X adapter), the checks,
/// the composer's preview and publishing.
///
/// X's create-post schema takes up to [largePostMax] media ids in one post, in
/// the order given, while its prose still says 4 photos, 1 GIF or 1 video.
/// Whether a given account gets the larger post is only known once X answers
/// one, so an API account starts on [large] and goes back to [classic] for
/// [retryAfter] after X refuses such a post ([XLargeMediaRecord]). A hand-off
/// fills X's own composer and stays on [classic].
class XMediaCapacity {
  XMediaCapacity._();

  /// Most photos and videos, of any mix, in one post.
  static const int largePostMax = 20;

  /// The classic limit: this many photos, or one video or GIF.
  static const int classicPhotos = 4;

  /// After X refuses a large post, the account posts the classic way for this
  /// long, then tries one large post again.
  static const Duration retryAfter = Duration(days: 7);

  /// Account config key of the [XLargeMediaRecord].
  static const String configKey = 'largeMediaPosts';

  static const int _gifMaxBytes = 15 * 1024 * 1024;
  static const String notes = 'Up to $largePostMax photos and videos in one post, mixed and in your order. If X refuses '
      'that for an account, NEFORUM sends the post as a thread of $classicPhotos photos or 1 video per post and tries '
      '$largePostMax again after 7 days. Hand-off: $classicPhotos photos or 1 video. Photos up to 5 MB, an animated GIF '
      '(15 MB) goes alone, videos MP4/MOV up to 20 minutes and 8 GB (longer with Premium). Alt text up to 1000 '
      'characters.';

  /// 4 photos, or 1 video, or 1 animated GIF, per post.
  static const MediaRules classic = MediaRules(
    // Sound goes as a video of one still picture, made by the app.
    audioAsVideo: true,
    maxImages: classicPhotos,
    maxVideos: 1,
    gifAlone: true,
    // GIFs are "images" in the generic check; photos are held to 5 MB in validate().
    imageMaxBytes: _gifMaxBytes,
    videoMaxBytes: 8 * 1024 * 1024 * 1024,
    videoMaxSeconds: 20 * 60,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
    videoMimeTypes: {'video/mp4', 'video/quicktime'},
    supportsAltText: true,
    mediaPerThreadPart: true,
    notes: notes,
  );

  /// Up to 20 photos and videos together per post; an animated GIF still alone.
  static const MediaRules large = MediaRules(
    audioAsVideo: true,
    maxImages: largePostMax,
    maxVideos: largePostMax,
    maxItems: largePostMax,
    allowsMixedImageVideo: true,
    gifAlone: true,
    imageMaxBytes: _gifMaxBytes,
    videoMaxBytes: 8 * 1024 * 1024 * 1024,
    videoMaxSeconds: 20 * 60,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
    videoMimeTypes: {'video/mp4', 'video/quicktime'},
    supportsAltText: true,
    mediaPerThreadPart: true,
    notes: notes,
  );

  /// Whether [account] gets [large] posts at [now]: an API account that X has
  /// not refused one within [retryAfter]. A refusal dated more than a day
  /// ahead of [now] (a device with a wrong clock) does not count.
  static bool usesLarge(ConnectedAccount account, DateTime now) {
    if (account.tier != PlatformTier.byokApi) return false;
    final record = XLargeMediaRecord.fromConfig(account);
    if (record == null || record.accepted) return true;
    return !_recent(record, now);
  }

  /// The rules [account] posts with at [now].
  static MediaRules rulesFor(ConnectedAccount account, DateTime now) => usesLarge(account, now) ? large : classic;

  /// Whole days until [account], refused at [now], tries a large post again;
  /// null when it is not waiting.
  static int? daysUntilRetry(ConnectedAccount account, DateTime now) {
    if (account.tier != PlatformTier.byokApi) return null;
    final record = XLargeMediaRecord.fromConfig(account);
    if (record == null || record.accepted || !_recent(record, now)) return null;
    final left = record.at.add(retryAfter).difference(now.toUtc());
    return (left.inMinutes / Duration.minutesPerDay).ceil().clamp(1, retryAfter.inDays);
  }

  static bool _recent(XLargeMediaRecord record, DateTime now) {
    final age = now.toUtc().difference(record.at);
    return age < retryAfter && age > const Duration(days: -1);
  }

  /// Whether [group] fits one post the [classic] way. A post that does not is
  /// a "large" post, the kind X may refuse.
  static bool fitsClassicPost(List<MediaAttachment> group) => packMediaIntoPosts(group, classic).length <= 1;

  /// Whether X's refusal [f] of a large post (more than 4 items, or photos and
  /// videos mixed) is about how many media, or which mix, it carries: a
  /// 400/403/413/422 that speaks of media, or a 400/413/422 rejection that
  /// names nothing else the request carried (its text, reply or poll). A
  /// duplicate is never one.
  static bool refusesLargePost(HttpFailure f) {
    final s = f.statusCode;
    if (s != 400 && s != 403 && s != 413 && s != 422) return false;
    final lower = f.body.toLowerCase();
    if (lower.contains('duplicate')) return false;
    if (RegExp(r'media|attachment').hasMatch(lower)) return true;
    if (s == 403) return false;
    if (RegExp(r'\btext\b|too long|length|characters|shorter|reply|poll|quote').hasMatch(lower)) return false;
    return RegExp(r'invalid|too many|at most|maxitems|max items').hasMatch(lower);
  }
}
