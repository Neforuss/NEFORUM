import 'dart:typed_data';

import '../media_hosts/media_host.dart';
import '../model/audio.dart';
import '../model/media.dart';
import '../model/post_variant.dart';
import '../model/publish_result.dart';
import 'adapter_context.dart';
import 'platform_adapter.dart';

/// [variant] without its sound files and with a link to each at the end of
/// its text (of the last part of a thread), for networks that take sound
/// only as a link ([MediaRules.audioAsLink]). Each file goes on the user's
/// media host first, unchanged. A post keeps its links, so a host that only
/// makes temporary ones is refused. [markdown] writes `[name (FLAC)](url)`
/// instead of the bare link. Returns [variant] as it is when it has no sound
/// file.
///
/// Throws [AdapterException] when there is no media host or the upload fails.
Future<PostVariant> withAudioLinks(PostVariant variant, AdapterContext ctx,
    {required String platform, bool markdown = false}) async {
  final sound = [for (final m in variant.media) if (m.isAudio) m];
  if (sound.isEmpty) return variant;
  final host = ctx.mediaHost;
  if (host == null) {
    throw AdapterException(PublishError.configuration(
        '$platform takes a sound file only as a link, so the file must be on a media host first. '
        'Set one up in Settings > Media hosting.'));
  }
  final links = <String>[];
  for (var i = 0; i < sound.length; i++) {
    final m = sound[i];
    ctx.progress('Uploading sound file ${i + 1} of ${sound.length} to ${host.name}');
    final Uint8List bytes;
    try {
      bytes = await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}; re-attach it and try again ($e)'));
    }
    final url = await _hostPermanently(host, m, bytes, platform, ctx);
    links.add(markdown ? '[${audioLinkLabel(m)}]($url)' : url);
  }
  final addition = links.join('\n');
  String withLinks(String text) => text.trim().isEmpty ? addition : '${text.trimRight()}\n\n$addition';
  // The photos and videos stay in the parts they go with.
  final rest = variant.withoutMedia((m) => m.isAudio);
  if (variant.isThread) {
    final parts = [...variant.threadParts];
    parts[parts.length - 1] = withLinks(parts.last);
    return rest.copyWith(text: parts.first, threadParts: parts);
  }
  return rest.copyWith(text: withLinks(variant.text));
}

/// The words of a link to a sound file: its name and type, "Demo (FLAC)".
String audioLinkLabel(MediaAttachment m) {
  final name = (m.fileName ?? '').trim();
  final dot = name.lastIndexOf('.');
  final title = (dot > 0 ? name.substring(0, dot) : name).replaceAll(RegExp(r'[\[\]]'), '');
  final format = audioFormatLabel(m);
  return title.isEmpty ? 'Listen ($format)' : '$title ($format)';
}

Future<String> _hostPermanently(MediaHost host, MediaAttachment m, Uint8List bytes, String platform, AdapterContext ctx) async {
  final max = host.maxBytes;
  if (max != null && bytes.length > max) {
    throw AdapterException(PublishError.validation('${m.fileName ?? 'The sound file'} is larger than ${host.name} accepts.'));
  }
  final HostedMedia hosted;
  try {
    hosted = await host.upload(m, bytes);
  } on MediaHostException catch (e) {
    throw AdapterException(e.toPublishError());
  }
  if (hosted.expiresAt != null) {
    try {
      await host.delete(hosted);
    } on Object catch (e) {
      ctx.log.warn('Could not delete the temporary copy on ${host.name}: $e');
    }
    throw AdapterException(PublishError.configuration(
        '${host.name} only makes temporary links, but the link in a $platform post stays. '
        'Choose a media host with lasting links in Settings > Media hosting.'));
  }
  return hosted.url.toString();
}
