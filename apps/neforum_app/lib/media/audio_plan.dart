import 'package:neforum_core/neforum_core.dart';

/// Bitrate of the Standard copy (MP3, or AAC in M4A).
const int kStandardAudioBitsPerSecond = 256000;

/// What one network receives for a post's sound file. A network that takes
/// sound only as a link gets a link to the original or the Standard copy.
enum AudioRoute {
  /// The file the user attached, as it is.
  original,

  /// The one MP3 (or M4A) NEFORUM makes from it for Standard quality.
  standardCopy,

  /// A video of one still picture for the track's length (video-only
  /// networks).
  video,

  /// Nothing: the network takes no sound; the track is left out.
  none,
}

/// The format the Standard copy is made in, from what this device can write
/// ([VideoCompositor.audioOutputFormats]): MP3 where the system has an MP3
/// encoder (Windows), else M4A AAC (phones and Macs). Null when the device
/// cannot convert sound at all.
String? standardAudioFormat(List<String> formats) => formats.contains('mp3')
    ? 'mp3'
    : formats.contains('m4a')
        ? 'm4a'
        : null;

/// The canonical MIME type of a [standardAudioFormat] result.
String? standardAudioMimeType(String? format) => switch (format) {
      'mp3' => AudioMimeTypes.mp3,
      'm4a' => AudioMimeTypes.m4a,
      _ => null,
    };

/// The quality that really applies to [source]: Lossless only for a lossless
/// file. An MP3 or AAC file made into WAV would only be bigger, never better,
/// so it is never offered as lossless.
AudioQuality effectiveAudioQuality(AudioQuality chosen, MediaAttachment source) =>
    chosen == AudioQuality.lossless && source.isLosslessAudio ? AudioQuality.lossless : AudioQuality.standard;

/// Whether Standard quality sends a converted copy of [source]: everything
/// but an MP3 is converted once.
bool standardNeedsCopy(MediaAttachment source) => !source.isMp3;

/// What a network with [rules] receives for [source] at [quality].
/// [standardMimeType] is the type of the Standard copy this device makes
/// ([standardAudioMimeType]); null when it cannot convert, and the original
/// then goes wherever it is taken (the checks say where it is not).
AudioRoute audioRouteFor(MediaRules rules, MediaAttachment source, AudioQuality quality, {String? standardMimeType}) {
  final lossless = effectiveAudioQuality(quality, source) == AudioQuality.lossless;
  if (rules.supportsAudio) {
    final takesOriginal = rules.audioMimeTypes.contains(source.mimeType);
    if (takesOriginal && (lossless || source.isMp3)) return AudioRoute.original;
    if (standardMimeType != null && rules.audioMimeTypes.contains(standardMimeType)) return AudioRoute.standardCopy;
    return AudioRoute.original;
  }
  if (rules.audioAsVideo) return AudioRoute.video;
  if (rules.audioAsLink) {
    if (lossless || source.isMp3 || standardMimeType == null) return AudioRoute.original;
    return AudioRoute.standardCopy;
  }
  return AudioRoute.none;
}

/// Path prefix of the composer's stand-ins for renditions made on save.
const String kAudioStandIn = 'audio-stand-in:';

/// What a network's preview and checks see for [source] in [media] before
/// the post is saved ([attachAudioRenditions] makes the real files then):
/// a stand-in for the Standard copy or the still-picture video (whose
/// picture, the first photo, leaves the list), and notes that say what the
/// network gets. [standardFormat] is [standardAudioFormat] for this device;
/// without [canRenderVideo] the track stays and the checks explain.
({List<MediaAttachment> media, List<ValidationIssue> notes}) previewAudio(
    List<MediaAttachment> media, MediaAttachment source, PlatformDescriptor d, AudioQuality quality,
    {String? standardFormat, bool canRenderVideo = false}) {
  final standardMime = standardAudioMimeType(standardFormat);
  final route = audioRouteFor(d.media, source, quality, standardMimeType: standardMime);
  final label = audioFormatLabel(source);
  final lossless = effectiveAudioQuality(quality, source) == AudioQuality.lossless;
  List<MediaAttachment> replaced(MediaAttachment standIn, {bool dropPicture = false}) {
    final picture = dropPicture ? media.where((m) => m.kind == MediaKind.image && !m.isTextCard).firstOrNull : null;
    return [
      for (final m in media)
        if (m.id == source.id) standIn else if (!identical(m, picture)) m,
    ];
  }

  switch (route) {
    case AudioRoute.original:
      final ValidationIssue? note;
      if (lossless) {
        note = d.media.keepsAudioBytes
            ? ValidationIssue.info('media.audio_original', '${d.name} gets your original $label file, unchanged', field: 'media')
            : ValidationIssue.info('media.audio_original', '${d.name} gets your original $label file and makes its own copy to play', field: 'media');
      } else if (standardNeedsCopy(source) && standardMime == null) {
        note = ValidationIssue.warning(
            'media.audio_no_convert', 'This device cannot convert sound, so ${d.name} gets the original $label file', field: 'media');
      } else {
        note = null;
      }
      return (media: media, notes: [?note]);
    case AudioRoute.standardCopy:
      final format = standardFormat!;
      final ms = source.durationMs;
      final standIn = MediaAttachment(
        id: 'audio-standard-${source.id}',
        path: '${kAudioStandIn}standard',
        mimeType: standardMime!,
        sizeBytes: ms == null ? source.sizeBytes : (ms * kStandardAudioBitsPerSecond / 8000).round(),
        durationMs: ms,
        fileName: '${audioTrackTitle(source)}.$format',
        generated: true,
        derivedFrom: source.id,
        audioCodec: format == 'mp3' ? AudioCodecs.mp3 : AudioCodecs.aac,
      );
      return (
        media: replaced(standIn),
        notes: [ValidationIssue.info('media.audio_standard', '${d.name} gets the ${format.toUpperCase()} NEFORUM makes when you save', field: 'media')],
      );
    case AudioRoute.video:
      if (!canRenderVideo) return (media: media, notes: const []);
      final (width, height) = audioVideoFrame(d.id);
      final ms = source.durationMs;
      final hasPicture = media.any((m) => m.kind == MediaKind.image && !m.isTextCard);
      final standIn = MediaAttachment(
        id: 'audio-video-${source.id}',
        path: '${kAudioStandIn}video',
        mimeType: 'video/mp4',
        // About 256 kbit/s of sound and a little for the still picture.
        sizeBytes: ms == null ? source.sizeBytes : (ms * 320000 / 8000).round(),
        width: width,
        height: height,
        durationMs: ms,
        fileName: '${audioTrackTitle(source)} (video).mp4',
        generated: true,
        derivedFrom: source.id,
      );
      return (
        media: replaced(standIn, dropPicture: true),
        notes: [
          ValidationIssue.info(
              'media.audio_video',
              '${d.name} takes sound only as a video: NEFORUM makes one with '
                  '${hasPicture ? 'your first photo' : 'a card of the track title'} when you save',
              field: 'media'),
        ],
      );
    case AudioRoute.none:
      return (media: media, notes: const []);
  }
}

/// Pixel size of the video a track becomes on [platformId]: full-screen 9:16
/// where videos play that way (TikTok, Instagram Reels), 16:9 on YouTube
/// (a square or upright video would be a Short), square elsewhere.
(int, int) audioVideoFrame(String platformId) => switch (platformId) {
      'tiktok' || 'instagram' => (1080, 1920),
      'youtube' => (1920, 1080),
      _ => (1080, 1080),
    };

/// "3:04", "1:02:03": a track's length for people.
String formatAudioDuration(int ms) {
  final total = (ms / 1000).round();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The track's title: the post's title, else "Artist – Title" from its
/// track details ([tags]), else the file name without its extension.
String audioTrackTitle(MediaAttachment source, {String? postTitle, AudioTags? tags}) {
  final t = postTitle?.trim() ?? '';
  if (t.isNotEmpty) return t;
  final tagged = tags?.artistAndTitle;
  if (tagged != null) return tagged;
  final name = (source.fileName ?? '').trim();
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.isEmpty ? 'Untitled track' : base;
}
