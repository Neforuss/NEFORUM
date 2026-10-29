import 'dart:typed_data';

import 'background_images_web.dart' if (dart.library.io) 'background_images_io.dart' as impl;

/// Background pictures (Settings > Appearance > Background). Each is a copy
/// in its own folder under NEFORUM's data folder (`AppStorage.dataDir`), not
/// in the media library, whose clean-up deletes files no post mentions.
///
/// None on web: the preview keeps no files.

/// Whether this build can keep a background picture in [dataDir].
bool backgroundImagesSupported(String? dataDir) => impl.backgroundImagesSupported(dataDir);

/// Copies [bytes] (a JPEG, PNG, WebP...) into the background folder under
/// [dataDir] and returns the copy's path, a new name every time.
Future<String?> saveBackgroundImage(String? dataDir, Uint8List bytes, String extension) =>
    impl.saveBackgroundImage(dataDir, bytes, extension);

/// The picture at [path], or null when it is gone.
Future<Uint8List?> readBackgroundImage(String path) => impl.readBackgroundImage(path);

/// Deletes [path] when it is in the background folder under [dataDir]
/// (never anything else).
Future<void> deleteBackgroundImage(String? dataDir, String path) => impl.deleteBackgroundImage(dataDir, path);
