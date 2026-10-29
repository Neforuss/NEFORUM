import 'package:meta/meta.dart';

import 'audio.dart' show AudioCodecs;
import 'audio_tags.dart';
import 'photo_fit.dart' show PhotoFit;

enum MediaKind { image, gif, video, audio }

/// A media file attached to a post. The bytes live on disk at [path]; NEFORUM
/// never copies media into its database.
@immutable
class MediaAttachment {
  const MediaAttachment({
    required this.id,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
    this.altText,
    this.fileName,
    this.generated = false,
    this.derivedFrom,
    this.fitKey,
    this.renderParameters,
    this.audioCodec,
    this.audioTags,
  });

  factory MediaAttachment.fromJson(Map<String, dynamic> json) => MediaAttachment(
        id: json['id'] as String,
        path: json['path'] as String,
        mimeType: json['mimeType'] as String,
        sizeBytes: json['sizeBytes'] as int,
        width: json['width'] as int?,
        height: json['height'] as int?,
        durationMs: json['durationMs'] as int?,
        altText: json['altText'] as String?,
        fileName: json['fileName'] as String?,
        generated: json['generated'] as bool? ?? false,
        derivedFrom: json['derivedFrom'] as String?,
        fitKey: json['fitKey'] as String?,
        renderParameters: json['renderParameters'] == null
            ? null
            : Map<String, dynamic>.from(json['renderParameters'] as Map),
        audioCodec: json['audioCodec'] as String?,
        audioTags: json['audioTags'] == null ? null : AudioTags.fromJson(Map<String, dynamic>.from(json['audioTags'] as Map)),
      );

  final String id;
  final String path;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? altText;
  final String? fileName;

  /// Made by NEFORUM, not picked by the user: the text card for platforms
  /// that require an image. Generated media only reaches the targets that
  /// list it in [PostOverrides.mediaIds]; everyone else ignores it.
  final bool generated;

  /// For a photo NEFORUM fitted to a platform's rules (also [generated]): the
  /// id of the photo it was made from. Null for anything else.
  final String? derivedFrom;

  /// For a fitted photo: the rules and mode it was made for
  /// ([PhotoFit.keyFor]), so it can be reused.
  final String? fitKey;

  /// For generated media: the settings it was rendered with (text card
  /// style, caption style, background photo and blur...), so it can be
  /// rendered again or reused. JSON values only. Null for user files.
  final Map<String, dynamic>? renderParameters;

  /// For a sound file: the codec inside it ([AudioCodecs]), read when it was
  /// imported; null when unknown. It tells Apple Lossless from AAC in an M4A
  /// file.
  final String? audioCodec;

  /// For a sound file: the tags it carries (title, artist, album, year,
  /// cover...), read when it was imported; null when it has none.
  final AudioTags? audioTags;

  /// A NEFORUM text card (generated, not made from a photo).
  bool get isTextCard => generated && derivedFrom == null;

  MediaKind get kind {
    if (mimeType == 'image/gif') return MediaKind.gif;
    if (mimeType.startsWith('video/')) return MediaKind.video;
    if (mimeType.startsWith('audio/')) return MediaKind.audio;
    return MediaKind.image;
  }

  bool get isVideo => kind == MediaKind.video;
  bool get isAudio => kind == MediaKind.audio;
  bool get isImage => kind == MediaKind.image || kind == MediaKind.gif;

  double? get aspectRatio =>
      (width != null && height != null && height! > 0) ? width! / height! : null;

  MediaAttachment copyWith({String? altText, bool clearAltText = false, AudioTags? audioTags, bool clearAudioTags = false}) => MediaAttachment(
        id: id,
        path: path,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        width: width,
        height: height,
        durationMs: durationMs,
        altText: clearAltText ? null : (altText ?? this.altText),
        fileName: fileName,
        generated: generated,
        derivedFrom: derivedFrom,
        fitKey: fitKey,
        renderParameters: renderParameters,
        audioCodec: audioCodec,
        audioTags: clearAudioTags ? null : (audioTags ?? this.audioTags),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (durationMs != null) 'durationMs': durationMs,
        if (altText != null) 'altText': altText,
        if (fileName != null) 'fileName': fileName,
        if (generated) 'generated': true,
        if (derivedFrom != null) 'derivedFrom': derivedFrom,
        if (fitKey != null) 'fitKey': fitKey,
        if (renderParameters != null) 'renderParameters': renderParameters,
        if (audioCodec != null) 'audioCodec': audioCodec,
        if (audioTags != null) 'audioTags': audioTags!.toJson(),
      };
}
