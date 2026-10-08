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
      };
}
