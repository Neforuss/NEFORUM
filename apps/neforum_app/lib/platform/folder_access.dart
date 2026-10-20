import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// Keeps access to a folder the user picked across restarts. Only the Mac
/// needs this: its app sandbox forgets a picked folder when NEFORUM quits
/// unless it saved a security-scoped bookmark (MainFlutterWindow.swift).
abstract final class FolderAccess {
  static const _channel = MethodChannel('neforum/bookmarks');

  /// A bookmark for [path], right after the user picked it; `null` where
  /// none is needed (or the Mac refused).
  static Future<String?> remember(String path) async {
    if (!Env.isMacOS) return null;
    try {
      return await _channel.invokeMethod<String>('save', {'path': path});
    } on Object catch (e) {
      debugPrint('Could not bookmark $path: $e');
      return null;
    }
  }

  /// Opens the folder saved with [remember] again; returns its current path
  /// (it may have moved), or `null` when the bookmark no longer works.
  static Future<String?> reopen(String bookmark) async {
    if (!Env.isMacOS) return null;
    try {
      return await _channel.invokeMethod<String>('open', {'bookmark': bookmark});
    } on Object catch (e) {
      debugPrint('Could not reopen the sync folder: $e');
      return null;
    }
  }
}
