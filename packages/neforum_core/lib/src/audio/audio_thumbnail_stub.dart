import 'dart:typed_data';

import 'audio_publishing.dart';

/// Without isolates (the web), the thumbnail is made right here.
Future<Uint8List?> runAudioThumbnail(Uint8List cover, int maxSide, int maxBytes) async =>
    audioThumbnailJpegSync(cover, maxSide, maxBytes);
