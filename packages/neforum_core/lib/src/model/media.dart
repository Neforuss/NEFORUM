import 'package:meta/meta.dart';

enum MediaKind { image, gif, video }

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

  MediaKind get kind {
    if (mimeType == 'image/gif') return MediaKind.gif;
    if (mimeType.startsWith('video/')) return MediaKind.video;
    return MediaKind.image;
  }

  bool get isVideo => kind == MediaKind.video;
  bool get isImage => kind != MediaKind.video;

  double? get aspectRatio =>
      (width != null && height != null && height! > 0) ? width! / height! : null;

  MediaAttachment copyWith({String? altText, bool clearAltText = false}) => MediaAttachment(
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
      };
}
