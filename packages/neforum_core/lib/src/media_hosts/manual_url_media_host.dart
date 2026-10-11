import 'dart:typed_data';

import '../model/media.dart';
import 'media_host.dart';

/// "I host my files myself": NEFORUM uploads nothing.
///
/// Links can be supplied per media id through [urls] (for example from a
/// post variant's extras); any media without a link makes [upload] throw a
/// [MediaHostException] that tells the user to paste one.
class ManualUrlMediaHost implements MediaHost {
  const ManualUrlMediaHost({this.urls = const {}});

  /// Public https link per [MediaAttachment.id].
  final Map<String, String> urls;

  @override
  String get id => manualHostId;
  @override
  String get name => 'My own links';
  @override
  String get description => manualDescription;
  @override
  List<MediaHostField> get fields => const [];
  @override
  int? get maxBytes => null;

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    final raw = urls[media.id]?.trim();
    final url = raw == null ? null : Uri.tryParse(raw);
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      final label = media.fileName ?? media.id;
      throw MediaHostException(
          raw == null
              ? 'Paste a public https link for "$label": your media host is set to "My own links", so NEFORUM does not upload files'
              : 'The link for "$label" must be a public https address (got "$raw")',
          hostId: id);
    }
    return HostedMedia(hostId: id, url: url);
  }

  /// Nothing to delete: the user owns the files.
  @override
  Future<void> delete(HostedMedia hosted) async {}

  @override
  Future<void> verify() async {}
}

/// Registry id of [ManualUrlMediaHost].
const String manualHostId = 'manual';

/// Settings-screen description of [ManualUrlMediaHost].
const String manualDescription =
    'You put each photo or video online yourself and paste its public link. The link must open the file directly '
    '(no web page, no login, no redirect).';
