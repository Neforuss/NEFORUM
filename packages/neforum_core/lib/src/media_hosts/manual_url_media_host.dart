import 'dart:typed_data';

import '../model/media.dart';
import 'media_host.dart';
import 'media_host_support.dart';

/// "I host my files myself": NEFORUM uploads nothing.
///
/// The link of a file comes from [urls] (per media id, for callers that
/// collect links per post) or else from [urlTemplate], a pattern such as
/// `https://example.com/media/{name}` where `{name}` is the attachment's file
/// name. Any media without a link makes [upload] throw a
/// [MediaHostException] that tells the user what to fill in.
class ManualUrlMediaHost implements MediaHost, DescribesVerify {
  const ManualUrlMediaHost({this.urls = const {}, this.urlTemplate});

  /// Builds the host from the settings form ([manualFields]).
  factory ManualUrlMediaHost.fromConfig(Map<String, String> config) {
    final template = configValue(config, 'urlTemplate');
    if (template != null) {
      final probe = Uri.tryParse(template.replaceAll('{name}', 'x.jpg'));
      if (!template.contains('{name}') || probe == null || probe.scheme != 'https' || probe.host.isEmpty) {
        throw MediaHostException(
            '"Link pattern" must be an https:// address containing {name}, e.g. https://example.com/media/{name} '
            '(got "$template")',
            hostId: manualHostId);
      }
    }
    return ManualUrlMediaHost(urlTemplate: template);
  }

  /// Public https link per [MediaAttachment.id].
  final Map<String, String> urls;

  /// `https://…/{name}`; `{name}` becomes the URL-encoded file name.
  final String? urlTemplate;

  @override
  String get id => manualHostId;
  @override
  String get name => 'My own links';
  @override
  String get description => manualDescription;
  @override
  List<MediaHostField> get fields => manualFields;
  @override
  int? get maxBytes => null;

  /// The link [urlTemplate] gives for [media], or `null` without a template.
  String? templateUrlFor(MediaAttachment media) {
    final template = urlTemplate;
    if (template == null) return null;
    final given = media.fileName?.trim() ?? '';
    final name = given.isNotEmpty ? given : media.path.split(RegExp(r'[\\/]')).last;
    return template.replaceAll('{name}', Uri.encodeComponent(name));
  }

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    final raw = urls[media.id]?.trim() ?? templateUrlFor(media);
    final url = raw == null ? null : Uri.tryParse(raw);
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      final label = media.fileName ?? media.id;
      throw MediaHostException(
          raw == null
              ? 'No public link for "$label": your media host is "My own links", so NEFORUM does not upload files. '
                  'Set a link pattern such as https://example.com/media/{name} in the media host settings'
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

  @override
  String get verifiedMessage => '${urlTemplate == null ? 'Nothing to test' : 'The link pattern is valid'}: NEFORUM '
      'uploads nothing here, so open one of your links in a browser to check it.';
}

/// Registry id of [ManualUrlMediaHost].
const String manualHostId = 'manual';

/// Settings-screen description of [ManualUrlMediaHost].
const String manualDescription =
    'You put each photo or video online yourself, under its own file name, and tell NEFORUM the link pattern. '
    'The link must open the file directly (no web page, no login, no redirect).';

/// Form fields of [ManualUrlMediaHost].
const List<MediaHostField> manualFields = [
  MediaHostField(
    key: 'urlTemplate',
    label: 'Link pattern',
    placeholder: 'https://example.com/media/{name}',
    help: 'Where your files are online, with {name} where the file name goes (the name the file has on this '
        'device, e.g. IMG_1234.jpg).',
  ),
];
