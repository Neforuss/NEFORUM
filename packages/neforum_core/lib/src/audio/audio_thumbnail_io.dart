import 'dart:isolate';
import 'dart:typed_data';

import 'audio_publishing.dart';

/// Runs [audioThumbnailJpegSync] in a new isolate. The closure is made in
/// this small function, so it carries nothing but the picture and the limits.
Future<Uint8List?> runAudioThumbnail(Uint8List cover, int maxSide, int maxBytes) =>
    Isolate.run(() => audioThumbnailJpegSync(cover, maxSide, maxBytes));
