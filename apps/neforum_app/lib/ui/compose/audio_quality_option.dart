import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../media/audio_plan.dart';
import '../../state/audio_renditions.dart';
import '../../state/composer.dart';
import '../../theme/tokens.dart';
import '../accounts/guide_sheet.dart';

/// "Audio quality" for a post with a sound file: Standard (one MP3 for every
/// network) or Lossless (the original file where a network takes it).
/// Lossless is only offered for a lossless file.
class AudioQualityOption extends ConsumerWidget {
  const AudioQualityOption({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final c = ref.watch(composerProvider);
    final sound = c.audio;
    if (sound == null) return const SizedBox.shrink();
    final formats = ref.watch(audioOutputFormatsProvider).value;
    final quality = effectiveAudioQuality(c.audioQuality, sound);
    final canLossless = sound.isLosslessAudio;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.graphic_eq_rounded, size: 18, color: nf.textMuted),
          const SizedBox(width: Space.xs),
          Text('Audio quality', style: context.text.labelMedium?.copyWith(color: nf.textMuted)),
        ]),
        SegmentedButton<AudioQuality>(
          segments: [
            const ButtonSegment(
              value: AudioQuality.standard,
              label: Text('Standard (MP3)'),
              tooltip: 'One compressed file that every network plays',
            ),
            ButtonSegment(
              value: AudioQuality.lossless,
              label: const Text('Lossless (original file)'),
              tooltip: canLossless ? 'Your ${audioFormatLabel(sound)} file as it is' : 'Needs a WAV, FLAC, AIFF or Apple Lossless file',
              enabled: canLossless,
            ),
          ],
          selected: {quality},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onSelectionChanged: (s) => ref.read(composerProvider.notifier).setAudioQuality(s.single),
        ),
        TextButton(onPressed: () => showGuideSheet(context, 'audio', asset: 'audio.md'), child: const Text('How it works')),
      ]),
      const SizedBox(height: Space.xs),
      Text(audioQualityExplanation(sound, quality, formats), style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
    ]);
  }
}

/// What the chosen [quality] does with [source] on this device ([formats]:
/// what it can write, null while unknown).
String audioQualityExplanation(MediaAttachment source, AudioQuality quality, List<String>? formats) {
  final label = audioFormatLabel(source);
  if (quality == AudioQuality.lossless) {
    return 'Networks that take $label files get your original. Telegram, Discord, Matrix, Misskey, WordPress, Ghost and '
        'Odysee keep it byte for byte; Mastodon makes its own copy to play. The others get the Standard copy.';
  }
  final lossy = source.isLosslessAudio ? '' : ' Lossless needs a WAV, FLAC, AIFF or Apple Lossless file; this $label file is already compressed.';
  if (!standardNeedsCopy(source)) return 'Your MP3 goes as it is to every network that takes sound.$lossy';
  if (formats == null) return 'NEFORUM converts your $label file once when you save.$lossy';
  return switch (standardAudioFormat(formats)) {
    'mp3' => 'NEFORUM makes one MP3 (256 kbit/s) from your $label file when you save, for every network.$lossy',
    'm4a' => 'NEFORUM makes one M4A (AAC, 256 kbit/s) from your $label file when you save. Phones and Macs have no MP3 '
        'encoder, so they make M4A, which the networks that take sound play just the same.$lossy',
    _ => 'This device cannot convert sound, so networks that take $label files get the original.$lossy',
  };
}
