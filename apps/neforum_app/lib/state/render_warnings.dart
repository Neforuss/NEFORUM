import 'dart:async';

import 'package:flutter/foundation.dart';

/// Longest a single picture NEFORUM makes for a post (a text card, a caption
/// on a photo) may take. Past it the post goes on without that picture: the
/// plain photo, or no card.
const Duration kRenderTimeLimit = Duration(seconds: 20);

final StreamController<String> _renderWarnings = StreamController<String>.broadcast();

/// Messages about pictures that could not be made in time, for the app to
/// show wherever the user is.
Stream<String> get renderWarnings => _renderWarnings.stream;

/// Tells the user (through [renderWarnings]) that a picture was left out.
void reportRenderWarning(String message) {
  debugPrint(message);
  _renderWarnings.add(message);
}
