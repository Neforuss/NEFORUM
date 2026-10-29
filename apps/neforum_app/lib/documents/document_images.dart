import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A picture in a type every network takes.
typedef PostableImage = ({Uint8List bytes, String mimeType});

/// The type of an encoded picture from its first bytes; null when it is not
/// PNG, JPEG, GIF or WebP.
String? sniffImageType(Uint8List b) {
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
  if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// [bytes] as a picture NEFORUM can post: PNG, JPEG, GIF and WebP as they
/// are, BMP and TIFF converted to PNG. Null for anything else (EMF and WMF
/// drawings from Word, SVG), which the reader reports as skipped.
PostableImage? postableImage(Uint8List bytes) {
  final type = sniffImageType(bytes);
  if (type != null) return (bytes: bytes, mimeType: type);
  try {
    final decoded = (_isBmp(bytes) ? img.BmpDecoder().decode(bytes) : null) ?? (_isTiff(bytes) ? img.TiffDecoder().decode(bytes) : null);
    if (decoded == null) return null;
    return (bytes: Uint8List.fromList(img.encodePng(decoded)), mimeType: 'image/png');
  } on Object {
    return null;
  }
}

bool _isBmp(Uint8List b) => b.length > 2 && b[0] == 0x42 && b[1] == 0x4D;

bool _isTiff(Uint8List b) => b.length > 4 && ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) || (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A));

/// The file extension for [mimeType].
String extensionForImageType(String mimeType) => switch (mimeType) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
