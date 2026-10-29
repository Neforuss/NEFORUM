
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand/platform_brand.dart';
import '../../media/aligned_text.dart';
import '../../media/caption_fonts.dart';
import '../../media/caption_style.dart';
import '../../media/card_design.dart';
import '../../media/card_templates.dart' show cardTemplateLabel;
import '../../media/text_card.dart';
import '../../state/providers.dart';
import '../../state/settings.dart' show TextCardAlignment;
import '../../theme/tokens.dart';
import '../compose/caption_editor_sheet.dart';
import '../compose/card_designer_sheet.dart';
import '../compose/font_picker_sheet.dart';
import 'setting_row.dart';

class TextCardSettingsSection extends ConsumerWidget {
  const TextCardSettingsSection({super.key});

  static String _designLabel(Map<String, dynamic> json) {
    final d = CardDesign.tryParse(json);
    return d == null ? 'the classic card' : cardTemplateLabel(d);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    // 1.3.1: cards. The default font may be one installed or imported:
    // watching it loads it for the swatches.
    final customFont = s.textCardCustomFontChoice;
    ref.watch(captionFontReadyProvider(customFont));
    Widget swatch(
            {Key? key,
            required String label,
            required bool selected,
            required VoidCallback onTap,
            required TextCardTheme theme,
            required TextCardFont font,
            CaptionFont? custom}) =>
        Semantics(
          key: key,
          button: true,
          selected: selected,
          label: label,
          child: InkWell(
            borderRadius: Radii.rMd,
            onTap: s.textCards ? onTap : null,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedContainer(
                duration: Motion.fast,
                width: 132,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: Radii.rMd,
                  border: Border.all(color: selected ? nf.accent : nf.border, width: selected ? 2 : 1),
                ),
                child: ClipRRect(
                  borderRadius: Radii.rSm,
                  child: TextCardView(
                      text: 'One app, one message, every platform.',
                      theme: theme,
                      font: font,
                      customFont: custom,
                      aspect: 4 / 5,
                      byline: '@you',
                      alignment: s.textCardAlignment),
                ),
              ),
              const SizedBox(height: Space.xs + 2),
              Text(label, style: context.text.labelMedium?.copyWith(color: selected ? nf.text : nf.textMuted)),
            ]),
          ),
        );
    Widget option(TextCardTheme t) => swatch(
        label: t.label,
        selected: s.textCardTheme == t,
        onTap: () => n.update((x) => x.copyWith(textCardTheme: t)),
        theme: t,
        font: s.textCardFont,
        custom: customFont);
    Widget fontOption(TextCardFont f) => swatch(
        label: f.label,
        selected: customFont == null && s.textCardFont == f,
        onTap: () => n.update((x) => x.copyWith(textCardFont: f, textCardCustomFont: const {})),
        theme: s.textCardTheme,
        font: f);
    // Any installed or imported font, from the same picker as the caption's.
    final moreFonts = swatch(
      key: const Key('text-card-font-more-setting'),
      label: customFont?.family ?? 'More fonts…',
      selected: customFont != null,
      onTap: () async {
        final choice = await showFontChoiceSheet(context,
            current: FontChoice(s.textCardFont, customFont), platformId: 'instagram', title: 'Text card font');
        if (choice == null) return;
        final custom = choice.customFont;
        n.update((x) => custom == null
            ? x.copyWith(textCardFont: choice.font, textCardCustomFont: const {})
            : x.copyWith(textCardCustomFont: custom.toJson()));
      },
      theme: s.textCardTheme,
      font: s.textCardFont,
      custom: customFont,
    );

    return SettingsSection(
      title: 'Text cards',
      icon: Icons.text_fields_rounded,
      subtitle: 'For networks that only take photos: Instagram, Pinterest, TikTok, Snapchat.',
      children: [
        SettingSwitch(
          title: 'Turn text-only posts into an image',
          description: 'Your words, set large on a plain card with the NEFORUM signature. The caption still carries the full text, hashtags and link.',
          value: s.textCards,
          onChanged: (v) => n.update((x) => x.copyWith(textCards: v)),
        ),
        SettingSwitch(
          key: const Key('text-card-every-network-setting'),
          title: 'Use the text card on every network',
          description: 'Text-only posts get the same card on every network that takes images, at each network\'s usual size, '
              'with your words as its description. Networks without images get plain text. Each post can change it with the card button '
              'in the toolbar, and under each card you choose whether your text goes along.',
          value: s.textCardEveryNetwork,
          onChanged: !s.textCards ? null : (v) => n.update((x) => x.copyWith(textCardEveryNetwork: v)),
        ),
        SettingRow(
          title: 'NEFORUM signature',
          description: 'The purple rule, mark and name on the card. Turn it off for a plain card with just your words and handle. '
              'You can also switch it per post under the preview.',
          enabled: s.textCards,
          below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            for (final id in const ['instagram', 'tiktok', 'pinterest', 'snapchat'])
              FilterChip(
                label: Text(ref.watch(registryProvider).descriptor(id)?.name ?? id),
                avatar: PlatformTile(id, size: 18),
                selected: s.textCardBranded(id),
                onSelected: !s.textCards
                    ? null
                    : (on) => n.update((x) => x.copyWith(
                          textCardPlainPlatforms: on ? x.textCardPlainPlatforms.where((p) => p != id).toList() : {...x.textCardPlainPlatforms, id}.toList(),
                        )),
              ),
          ]),
        ),
        SettingRow(
          title: 'Show @handle',
          description: 'Your account\'s handle in the corner of the card. Turn it off where you would rather not show it. '
              'You can also switch it per post under the preview.',
          enabled: s.textCards,
          below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            for (final id in const ['instagram', 'tiktok', 'pinterest', 'snapchat'])
              FilterChip(
                key: Key('text-card-handle-$id'),
                label: Text(ref.watch(registryProvider).descriptor(id)?.name ?? id),
                avatar: PlatformTile(id, size: 18),
                selected: s.textCardShowsHandle(id),
                onSelected: !s.textCards
                    ? null
                    : (on) => n.update((x) => x.copyWith(
                          textCardHandleHiddenPlatforms:
                              on ? x.textCardHandleHiddenPlatforms.where((p) => p != id).toList() : {...x.textCardHandleHiddenPlatforms, id}.toList(),
                        )),
              ),
          ]),
        ),
        // 1.3.1: cards. The card designer's defaults, for text cards and for the
        // picture of a sound file's video.
        SettingRow(
          title: 'Card designer',
          description: 'Templates, gradients, patterns, grain, a framed photo or cover art, the waveform of a sound, and every text block '
              'in any font. Text cards: ${_designLabel(s.textCardDesign)}. Sound videos: ${_designLabel(s.audioCardDesign)}. '
              'Each post can change it under its preview.',
          enabled: s.textCards,
          stackOnCompact: true,
          below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            OutlinedButton.icon(
              key: const Key('text-card-design-setting'),
              onPressed: !s.textCards ? null : () => showCardDesignerSheet(context, kind: CardKind.text, scope: CardDesignerScope.defaults),
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: const Text('Design text cards…'),
            ),
            OutlinedButton.icon(
              key: const Key('audio-card-design-setting'),
              onPressed: () => showCardDesignerSheet(context, kind: CardKind.audio, scope: CardDesignerScope.defaults),
              icon: const Icon(Icons.album_outlined, size: 18),
              label: const Text('Design sound video pictures…'),
            ),
          ]),
        ),
        SettingRow(
          title: 'Card style',
          description: 'You can also switch it per post under the preview, or set your words over a photo there.',
          enabled: s.textCards,
          below: Opacity(
            opacity: s.textCards ? 1 : 0.45,
            child: Wrap(spacing: Space.lg, runSpacing: Space.md, children: [for (final t in TextCardTheme.values) option(t)]),
          ),
        ),
        SettingRow(
          title: 'Font',
          description: 'The typeface of your words on the card: a built-in font, one installed on this device, or a font file you import. '
              'The NEFORUM signature keeps its own. You can also switch it per post under the preview.',
          enabled: s.textCards,
          below: Opacity(
            opacity: s.textCards ? 1 : 0.45,
            child: Wrap(spacing: Space.lg, runSpacing: Space.md, children: [for (final f in TextCardFont.values) fontOption(f), moreFonts]),
          ),
        ),
        SettingRow(
          title: 'Alignment',
          description: 'How the lines of your words are lined up. Distributed spreads every line across the card, the last one too. '
              'You can also switch it per post under the preview.',
          enabled: s.textCards,
          below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            for (final a in TextCardAlignment.values)
              Tooltip(
                message: a.description,
                child: ChoiceChip(
                  key: Key('text-card-alignment-${a.name}'),
                  avatar: Icon(a.icon, size: 16),
                  label: Text(a.label),
                  selected: s.textCardAlignment == a,
                  onSelected: !s.textCards ? null : (_) => n.update((x) => x.copyWith(textCardAlignment: a)),
                ),
              ),
          ]),
        ),
        SettingRow(
          title: 'Caption on photos',
          description: 'How your caption is written on TikTok and Instagram photos: on the photo or in a block above it, '
              'its size, colours, background, alignment and font. Turn it on per network in Posting, or per post under the preview.',
          trailing: OutlinedButton(
            key: const Key('caption-style-edit'),
            onPressed: () => showCaptionEditorSheet(context, defaults: true),
            child: const Text('Edit style'),
          ),
          stackOnCompact: true,
          below: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 132,
              child: CaptionPhotoPreview(
                platformId: 'tiktok',
                photo: null,
                text: 'Your caption, on your photo.',
                style: CaptionStyle.fromJson(s.captionStyle),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
