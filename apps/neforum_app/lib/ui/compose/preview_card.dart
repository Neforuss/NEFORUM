import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../media/aligned_text.dart';
import '../../media/caption_fonts.dart' show captionFontReadyProvider;
import '../../media/caption_overlay.dart';
import '../../media/caption_style.dart';
import '../../media/text_card.dart';
import '../../media/text_card_background.dart';
import '../../platform/file_export.dart';
import '../../state/captioned_photos.dart';
import '../../state/composer.dart';
import '../../state/fitted_photos.dart';
import '../../state/providers.dart';
import '../../state/settings.dart' show TextCardAlignment;
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../theme/zoom.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/char_ring.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import 'caption_editor_sheet.dart';
import 'card_background_sheet.dart';
import 'rich_text.dart';

/// How a platform presents a post; drives the preview layout.
enum PreviewFamily { microblog, visual, forum, chat, blog }

PreviewFamily previewFamilyFor(String platformId, {bool artPlatform = false}) => switch (platformId) {
      _ when artPlatform => PreviewFamily.visual,
      'instagram' || 'tiktok' || 'pinterest' || 'youtube' || 'snapchat' || 'rumble' || 'odysee' || 'bitchute' => PreviewFamily.visual,
      'reddit' || 'lemmy' => PreviewFamily.forum,
      'telegram' || 'discord' || 'matrix' || 'whatsapp' => PreviewFamily.chat,
      'wordpress' || 'ghost' || 'writefreely' || 'micropub' || 'devto' || 'hashnode' || 'substack' => PreviewFamily.blog,
      _ => PreviewFamily.microblog,
    };

/// Width / height of the media frame on photo-first platforms.
double _visualAspect(String platformId, List<MediaAttachment> media, {bool artPlatform = false}) {
  // Art sites show the work at its own shape.
  if (artPlatform) return (media.firstOrNull?.aspectRatio ?? 1).clamp(0.5, 2.0).toDouble();
  final video = media.isNotEmpty && media.first.isVideo;
  return switch (platformId) {
    // Instagram shows a feed photo at its own shape within 4:5 to 1.91:1.
    'instagram' => video ? 9 / 16 : (media.isEmpty ? 4 / 5 : (media.first.aspectRatio ?? 4 / 5).clamp(4 / 5, 1.91)),
    'tiktok' || 'snapchat' => 9 / 16,
    'pinterest' => 2 / 3,
    'youtube' || 'rumble' || 'odysee' || 'bitchute' => (media.isNotEmpty && (media.first.aspectRatio ?? 1.7) < 1) ? 9 / 16 : 16 / 9,
    _ => 1,
  };
}

/// One network's preview in the composer.
class PreviewCard extends ConsumerWidget {
  const PreviewCard({super.key, required this.preview, required this.onCustomize});

  final TargetPreview preview;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final p = preview;
    final d = p.descriptor;
    final v = p.variant;
    final customized = !p.target.overrides.isEmpty;
    final hasErrors = p.issues.hasErrors;
    final family = previewFamilyFor(d.id, artPlatform: d.isArtPlatform);
    final rules = d.text;
    final used = rules.maxLength == null ? v.text.characters.length : TextCounter.count(v.text, rules);

    final body = switch (family) {
      PreviewFamily.microblog => _Microblog(p: p),
      PreviewFamily.visual => _Visual(p: p),
      PreviewFamily.forum => _Forum(p: p),
      PreviewFamily.chat => _Chat(p: p),
      PreviewFamily.blog => _Blog(p: p),
    };

    return NfCard(
      padding: EdgeInsets.zero,
      borderColor: hasErrors ? nf.danger.withValues(alpha: 0.7) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
          child: Row(children: [
            PlatformTile(d.id, size: 28),
            const SizedBox(width: Space.sm + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
                  const SizedBox(width: Space.sm),
                  TierBadge(p.account.tier),
                  if (customized) ...[
                    const SizedBox(width: Space.xs),
                    const StatusPill('Customized', tone: Tone.accent, dense: true),
                  ],
                ]),
                Text(p.account.handle ?? p.account.displayName, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 11.5)),
              ]),
            ),
            CharRing(used: used, max: rules.maxLength, parts: v.isThread ? v.threadParts.length : 1, size: 20, alwaysShowCount: true),
            const SizedBox(width: Space.xs),
            ToolButton(icon: Icons.tune_rounded, tooltip: 'Customize for ${d.name}', onPressed: onCustomize, size: 34, active: customized),
          ]),
        ),
        Divider(height: 1, color: nf.border),
        Padding(padding: const EdgeInsets.all(Space.md + 2), child: body),
        if (p.issues.isNotEmpty) ...[
          Divider(height: 1, color: nf.border),
          _Issues(issues: p.issues),
        ],
        if (customized)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: Space.sm, bottom: Space.xs),
              child: TextButton.icon(
                onPressed: () => ref.read(composerProvider.notifier).clearOverride(p.account.id),
                icon: const Icon(Icons.restart_alt_rounded, size: 16),
                label: const Text('Use the main post'),
                style: TextButton.styleFrom(foregroundColor: nf.textMuted, textStyle: context.text.labelMedium),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Families
// ---------------------------------------------------------------------------

class _Microblog extends StatelessWidget {
  const _Microblog({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final parts = v.isThread ? v.threadParts : [v.text];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < parts.length; i++)
        // Thread connector painted behind the row (MediaGrid uses
        // LayoutBuilder, which cannot run inside IntrinsicHeight).
        Stack(children: [
          if (i < parts.length - 1)
            Positioned(left: 17, top: 40, bottom: 4, child: Container(width: 2, color: nf.border)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AccountAvatar(p.account, size: 36, showBadge: false),
            const SizedBox(width: Space.md),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: i < parts.length - 1 ? Space.lg : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(p.account.displayName, overflow: TextOverflow.ellipsis, style: context.text.labelLarge)),
                    const SizedBox(width: Space.xs + 2),
                    Text('· now', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                    if (parts.length > 1) ...[
                      const Spacer(),
                      Text('${i + 1}/${parts.length}', style: monoStyle(context, size: 11, color: nf.textFaint)),
                    ],
                  ]),
                  if (i == 0 && v.contentWarning != null) _CwBar(text: v.contentWarning!),
                  const SizedBox(height: 3),
                  _PostText(parts[i], empty: v.media.isEmpty),
                  // A poll or quiz post shows no images (an image poll shows them as its answers).
                  if (i == 0 && v.poll != null) ...[
                    const SizedBox(height: Space.sm + 2),
                    PollPreview(poll: v.poll!, media: v.media),
                  ] else if (i == 0 && v.media.isNotEmpty) ...[
                    const SizedBox(height: Space.sm + 2),
                    MediaGrid(media: v.media),
                  ],
                  if (i == 0 && v.media.isEmpty && v.link != null) ...[
                    const SizedBox(height: Space.sm + 2),
                    _LinkCard(url: v.link!),
                  ],
                ]),
              ),
            ),
          ]),
        ]),
    ]);
  }
}

class _Visual extends ConsumerWidget {
  const _Visual({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final v = p.variant;
    final id = p.descriptor.id;
    final placeholder = v.media.isNotEmpty && isTextCardPlaceholder(v.media.first) ? v.media.first : null;
    final card = placeholder == null ? null : textCardThemeOf(placeholder);
    final branded = card != null && textCardBrandedOf(placeholder!);
    final font = card == null ? TextCardFont.original : textCardFontOf(placeholder!);
    final alignment = placeholder == null ? TextCardAlignment.left : textCardAlignmentOf(placeholder);
    final showsHandle = placeholder == null || textCardShowsHandleOf(placeholder);
    final cardText = card == null ? '' : textCardText(_previewPost(ref), p.target);
    final byline = p.account.handle ?? p.account.displayName;
    final cardSize = textCardSize(id);
    final settings = ref.watch(settingsProvider);
    final composer = ref.watch(composerProvider);
    final cardBackground = placeholder != null && textCardParametersOf(placeholder)?['background'] != null
        ? TextCardBackground.tryParse(composer.textCardBackground)
        : null;
    final first = v.media.firstOrNull;
    final isPhoto = card == null && first != null && first.kind == MediaKind.image;
    // A photo NEFORUM fits: the composer checks a stand-in with the fitted
    // shape; show the photo the user attached, the way it will be fitted.
    final original = isPhoto && first.derivedFrom != null ? composer.media.where((m) => m.id == first.derivedFrom).firstOrNull : null;
    final captionOn = isPhoto && captionOnPhotoFor(id, settings, composer.captionOnPhoto);
    final captionStyle = captionStyleFor(composer.captionStyle, settings);
    if (captionOn) ref.watch(captionFontReadyProvider(captionStyle.customFont)); // 1.3: loads the caption's own font
    // A video on Instagram or TikTok can get the caption in a block above it
    // where this device can compose videos.
    final isVideo = card == null && first != null && first.isVideo;
    final videoCaptions = isVideo && kCaptionPhotoPlatforms.contains(id) && (ref.watch(videoCaptionsSupportedProvider).value ?? false);
    final videoCaptionOn = videoCaptions &&
        captionOnPhotoFor(id, settings, composer.captionOnPhoto) &&
        captionStyle.placement == CaptionPlacement.blockAbove;
    // The caption in a block above the photo or video: the preview is the
    // network's whole frame, as it will be saved.
    final blockFrame = videoCaptionOn
        ? videoFrameAspect(id)
        : (captionOn && captionStyle.placement == CaptionPlacement.blockAbove ? fullFrameAspect(id, v) : null);
    final aspect = card != null
        ? cardSize.width / cardSize.height
        : blockFrame ??
            ((original != null && first!.aspectRatio != null)
                ? first.aspectRatio!
                : _visualAspect(id, v.media, artPlatform: p.descriptor.isArtPlatform));
    return LayoutBuilder(builder: (context, c) {
      final maxW = aspect < 1 ? (c.maxWidth * 0.62).clamp(160.0, 300.0) : c.maxWidth;
      final w = maxW.toDouble();
      final h = w / aspect;
      final frame = card != null
          ? SizedBox(
              width: w,
              child: ClipRRect(
                borderRadius: Radii.rMd,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(borderRadius: Radii.rMd, border: Border.all(color: nf.border)),
                  child: TextCardView(
                    text: cardText,
                    theme: card,
                    font: font.resolve(id),
                    aspect: aspect,
                    byline: showsHandle ? byline : null,
                    branded: branded,
                    safe: textCardSafeArea(id),
                    alignment: alignment,
                    backdrop: previewBackdrop(ref, cardBackground),
                  ),
                ),
              ),
            )
          : v.media.isEmpty
          ? Container(
              width: w,
              height: h,
              decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rMd, border: Border.all(color: nf.border)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_photo_alternate_outlined, color: nf.textFaint, size: 30),
                const SizedBox(height: Space.sm),
                Text(
                  p.descriptor.media.requiresMedia ? '${p.descriptor.name} needs a photo or video' : 'Add a photo or video',
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: nf.textFaint),
                ),
              ]),
            )
          : Stack(children: [
              if (isVideo && blockFrame != null)
                SizedBox(
                  width: w,
                  height: h,
                  child: ClipRRect(
                    borderRadius: Radii.rMd,
                    child: Stack(fit: StackFit.expand, children: [
                      CaptionBlockFrame(
                        platformId: id,
                        photo: null,
                        text: captionStyle.wordsFor(captionWords(_previewPost(ref), p.target)),
                        style: captionStyle,
                        fit: settings.photoFit,
                      ),
                      Align(
                        alignment: const Alignment(0, 0.35),
                        child: Icon(Icons.play_circle_outline_rounded, size: w * 0.18, color: Colors.white70),
                      ),
                    ]),
                  ),
                )
              else if (isPhoto && blockFrame != null)
                SizedBox(
                  width: w,
                  height: h,
                  child: ClipRRect(
                    borderRadius: Radii.rMd,
                    child: CaptionBlockFrame(
                      platformId: id,
                      photo: original ?? composer.media.where((m) => m.id == first.id).firstOrNull ?? first,
                      text: captionStyle.wordsFor(captionWords(_previewPost(ref), p.target)),
                      style: captionStyle,
                      fit: settings.photoFit,
                    ),
                  ),
                )
              else if (isPhoto)
                SizedBox(
                  width: w,
                  height: h,
                  child: ClipRRect(
                    borderRadius: Radii.rMd,
                    child: Stack(fit: StackFit.expand, children: [
                      _PreviewPhoto(
                        photo: first,
                        original: original,
                        mode: settings.photoFit,
                        frameAspect: aspect,
                        // TikTok shows a photo that is not 9:16 whole, on black.
                        letterbox: id == 'tiktok',
                      ),
                      if (captionOn)
                        CustomPaint(
                          painter: CaptionOverlayPainter(
                            text: captionStyle.wordsFor(captionWords(_previewPost(ref), p.target)),
                            font: captionStyle.font.resolve(id),
                            style: captionStyle,
                            safe: captionSafeArea(id, aspect),
                          ),
                        ),
                    ]),
                  ),
                )
              else
                MediaThumb(v.media.first, size: h, aspect: aspect, radius: Radii.rMd),
              if (v.media.length > 1)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: Radii.rPill),
                    child: Text('1/${v.media.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]);
      // A single photo on a network that takes text cards can carry the words
      // as a card over it instead.
      final cardOnPhoto = isPhoto &&
          settings.textCards &&
          takesTextCards(p.descriptor) &&
          v.media.length == 1 &&
          first.mimeType != 'image/gif' &&
          v.text.trim().isNotEmpty;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: frame),
        if (card != null) ...[
          const SizedBox(height: Space.sm),
          Center(
            child: _CardStylePicker(
              current: card,
              font: font,
              platform: p.descriptor,
              branded: branded,
              text: cardText,
              byline: byline,
              alignment: alignment,
              showsHandle: showsHandle,
              background: cardBackground,
              withText: composer.textCardWithText[id] ?? true,
            ),
          ),
        ],
        if (isPhoto && (kCaptionPhotoPlatforms.contains(id) || fullFrameAspect(id, v) != null || cardOnPhoto)) ...[
          const SizedBox(height: Space.sm),
          Center(
            child: _PhotoOptions(
              platform: p.descriptor,
              variant: v,
              captionOn: captionOn,
              cardPhoto: cardOnPhoto ? (original ?? composer.media.where((m) => m.id == first.id).firstOrNull) : null,
            ),
          ),
        ],
        if (videoCaptions) ...[
          const SizedBox(height: Space.sm),
          Center(child: _VideoCaptionOption(platform: p.descriptor, captionOn: videoCaptionOn)),
        ],
        const SizedBox(height: Space.sm + 2),
        if ((v.title ?? '').isNotEmpty) ...[
          Text(v.title!, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
          const SizedBox(height: 2),
        ],
        RichText(
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: context.text.bodyMedium,
            children: [
              TextSpan(text: '${p.account.handle?.replaceFirst('@', '') ?? p.account.displayName}  ', style: context.text.labelLarge),
              ...highlightSpans(v.text, context.text.bodyMedium!, nf),
            ],
          ),
        ),
      ]);
    });
  }
}

/// The composer's current post, for the words on a text card.
Post _previewPost(WidgetRef ref) => ref.read(composerProvider).toPost(id: 'preview', status: PostStatus.draft, now: DateTime.now());

/// A photo in a network's frame as the network will show it: fitted (the
/// whole photo on a blur or colour fill, or cut to the frame), letterboxed on
/// black (TikTok, for a photo NEFORUM leaves as it is), or filling the frame.
class _PreviewPhoto extends ConsumerWidget {
  const _PreviewPhoto({required this.photo, required this.original, required this.mode, required this.frameAspect, required this.letterbox});

  final MediaAttachment photo;

  /// The photo the user attached, when [photo] is the stand-in for a fitted copy.
  final MediaAttachment? original;
  final PhotoFitMode mode;
  final double frameAspect;
  final bool letterbox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.read(servicesProvider).storage;
    final source = original ?? photo;
    if (original != null && (mode == PhotoFitMode.pad || mode == PhotoFitMode.color)) {
      final vertical = (source.aspectRatio ?? frameAspect) > frameAspect;
      final Widget background;
      if (mode == PhotoFitMode.color) {
        final edges = ref.watch(photoEdgeColoursProvider((source.path, vertical))).value;
        background = edges == null
            ? const ColoredBox(color: Colors.black)
            : DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
                    end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
                    colors: [Color(0xFF000000 | edges.start), Color(0xFF000000 | edges.end)],
                  ),
                ),
              );
      } else {
        background = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18, tileMode: TileMode.clamp),
          child: storage.image(source.path, fit: BoxFit.cover, cacheWidth: 120),
        );
      }
      return Stack(fit: StackFit.expand, children: [background, storage.image(source.path, fit: BoxFit.contain)]);
    }
    if (original == null && letterbox) {
      return ColoredBox(color: Colors.black, child: storage.image(source.path, fit: BoxFit.contain));
    }
    return storage.image(source.path, fit: BoxFit.cover);
  }
}

/// Under a photo for Instagram or TikTok: write the caption on it (the pill
/// opens the caption editor), and fit photos to the whole frame. Both are
/// remembered for the network. Under a single photo on a network that takes
/// text cards: set the words on a card over the photo instead.
class _PhotoOptions extends ConsumerWidget {
  const _PhotoOptions({required this.platform, required this.variant, required this.captionOn, this.cardPhoto});
  final PlatformDescriptor platform;
  final PostVariant variant;
  final bool captionOn;

  /// The photo the user attached, when it can become the text card's
  /// background.
  final MediaAttachment? cardPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final id = platform.id;
    final settings = ref.watch(settingsProvider);
    final frame = fullFrameAspect(id, variant);
    final fills = settings.fillsFrame(id);
    return Wrap(spacing: Space.xs, runSpacing: Space.xs, alignment: WrapAlignment.center, children: [
      if (kCaptionPhotoPlatforms.contains(id))
        _optionPill(
          context,
          selected: captionOn,
          label: 'Caption on photo',
          tooltip: captionOn
              ? 'Your caption is written on the first photo; tap to change how, or to turn it off'
              : 'Write your caption on the first photo, in ${platform.name}\'s own font, or in a block above it',
          leading: Icon(Icons.subtitles_outlined, size: 14, color: captionOn ? nf.accent : nf.textFaint),
          onTap: () {
            if (!captionOn) {
              ref.read(composerProvider.notifier).setCaptionOnPhoto(id, true);
              ref.read(settingsProvider.notifier).update((x) => x.copyWith(captionPhotoPlatforms: {...x.captionPhotoPlatforms, id}.toList()));
            }
            showCaptionEditorSheet(context, platformId: id);
          },
        ),
      if (cardPhoto != null)
        _optionPill(
          context,
          selected: false,
          label: 'Text card on this photo',
          tooltip: 'Set your words large on a card, with this photo blurred behind them',
          leading: Icon(Icons.text_fields_rounded, size: 14, color: nf.textFaint),
          onTap: () => ref.read(composerProvider.notifier).setTextCardBackground(TextCardBackground(photo: cardPhoto!).toJson()),
        ),
      if (frame != null)
        _optionPill(
          context,
          selected: fills,
          label: 'Fill the ${PhotoFit.ratioLabel(frame)} frame',
          tooltip: fills
              ? 'Photos are fitted to ${platform.name}\'s whole ${PhotoFit.ratioLabel(frame)} frame (Settings > Photos sets how); tap to leave their shape'
              : 'Fit photos to ${platform.name}\'s whole ${PhotoFit.ratioLabel(frame)} frame, so nothing is cut off',
          leading: Icon(Icons.fit_screen_outlined, size: 14, color: fills ? nf.accent : nf.textFaint),
          onTap: () => ref.read(settingsProvider.notifier).update((x) => x.copyWith(
                fillFramePlatforms: fills ? x.fillFramePlatforms.where((p) => p != id).toList() : {...x.fillFramePlatforms, id}.toList(),
              )),
        ),
    ]);
  }
}

/// Under a video for Instagram or TikTok: put the caption in a block above
/// the video (the pill turns it on in that placement and opens the caption
/// editor). Videos take the caption only as a block above them.
class _VideoCaptionOption extends ConsumerWidget {
  const _VideoCaptionOption({required this.platform, required this.captionOn});
  final PlatformDescriptor platform;
  final bool captionOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final id = platform.id;
    return _optionPill(
      context,
      selected: captionOn,
      label: 'Caption above video',
      tooltip: captionOn
          ? 'Your caption is in a block above the video, which NEFORUM puts in ${platform.name}\'s 9:16 frame; tap to change it, or to turn it off'
          : 'Put your caption in a block above the video, in ${platform.name}\'s 9:16 frame',
      leading: Icon(Icons.subtitles_outlined, size: 14, color: captionOn ? nf.accent : nf.textFaint),
      onTap: () {
        final composer = ref.read(composerProvider.notifier);
        final settings = ref.read(settingsProvider);
        if (!captionOn) {
          composer.setCaptionOnPhoto(id, true);
          ref.read(settingsProvider.notifier).update((x) => x.copyWith(captionPhotoPlatforms: {...x.captionPhotoPlatforms, id}.toList()));
          final style = captionStyleFor(ref.read(composerProvider).captionStyle, settings);
          if (style.placement != CaptionPlacement.blockAbove) {
            composer.setCaptionStyle(style.copyWith(placement: CaptionPlacement.blockAbove).toJson());
          }
        }
        showCaptionEditorSheet(context, platformId: id);
      },
    );
  }
}

/// A small toggle pill, as under text cards.
Widget _optionPill(BuildContext context,
    {required bool selected, required Widget leading, required String label, required VoidCallback? onTap, String? tooltip}) {
  final nf = context.nf;
  return Tooltip(
    message: tooltip ?? label,
    child: InkWell(
      borderRadius: Radii.rPill,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs + 1),
        decoration: BoxDecoration(
          color: selected ? nf.accentSoft : Colors.transparent,
          borderRadius: Radii.rPill,
          border: Border.all(color: selected ? nf.accent : nf.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading,
          const SizedBox(width: Space.xs + 2),
          Text(label, style: context.text.labelSmall?.copyWith(color: selected ? nf.text : nf.textMuted)),
        ]),
      ),
    ),
  );
}

/// Under a text card: black-on-white or white-on-black, the font, the
/// alignment, the NEFORUM signature and the @handle on or off for this
/// network, a colour or photo background, and saving the card as an image.
class _CardStylePicker extends ConsumerStatefulWidget {
  const _CardStylePicker({
    required this.current,
    required this.font,
    required this.platform,
    required this.branded,
    required this.text,
    required this.byline,
    required this.alignment,
    required this.showsHandle,
    required this.background,
    required this.withText,
  });
  final TextCardTheme current;
  final TextCardFont font;
  final PlatformDescriptor platform;
  final bool branded;
  final String text;
  final String byline;
  final TextCardAlignment alignment;
  final bool showsHandle;
  final TextCardBackground? background;

  /// The post's text goes along with the card on this network.
  final bool withText;

  @override
  ConsumerState<_CardStylePicker> createState() => _CardStylePickerState();
}

class _CardStylePickerState extends ConsumerState<_CardStylePicker> {
  bool _saving = false;

  Future<void> _save(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : windowRectOf(buttonContext, box);
    setState(() => _saving = true);
    TextCardBackdrop? backdrop;
    try {
      final background = widget.background;
      if (background != null) {
        backdrop = await decodeTextCardBackdrop(await ref.read(servicesProvider).storage.readMedia(background.photo.path), background);
      }
      final bytes = await renderTextCardJpeg(
        text: widget.text,
        theme: widget.current,
        size: textCardSize(widget.platform.id),
        byline: widget.showsHandle ? widget.byline : null,
        branded: widget.branded,
        font: widget.font.resolve(widget.platform.id),
        safe: textCardSafeArea(widget.platform.id),
        alignment: widget.alignment,
        backdrop: backdrop,
      );
      final stamp = DateFormat('yyyy-MM-dd HHmm').format(DateTime.now());
      final r = await FileExport.save(
        'Text cards',
        [ExportFile('NEFORUM card - ${widget.platform.name} - $stamp.jpg', bytes, mimeType: 'image/jpeg')],
        shareOrigin: origin,
      );
      if (mounted && r.paths.isNotEmpty) {
        showToast(context, 'Card saved to ${r.location}', icon: Icons.download_done_rounded);
      }
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not save the card: $e', icon: Icons.error_outline_rounded);
    } finally {
      backdrop?.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    Widget pill({required bool selected, required Widget leading, required String label, required VoidCallback? onTap, String? tooltip}) => Tooltip(
          message: tooltip ?? label,
          child: InkWell(
            borderRadius: Radii.rPill,
            onTap: onTap,
            child: AnimatedContainer(
              duration: Motion.fast,
              padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs + 1),
              decoration: BoxDecoration(
                color: selected ? nf.accentSoft : Colors.transparent,
                borderRadius: Radii.rPill,
                border: Border.all(color: selected ? nf.accent : nf.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                leading,
                const SizedBox(width: Space.xs + 2),
                Text(label, style: context.text.labelSmall?.copyWith(color: selected ? nf.text : nf.textMuted)),
              ]),
            ),
          ),
        );

    Widget themeOption(TextCardTheme t) => pill(
          selected: t == widget.current,
          label: t.label,
          leading: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: t.background, shape: BoxShape.circle, border: Border.all(color: nf.borderStrong)),
            alignment: Alignment.center,
            child: Container(width: 6, height: 6, decoration: BoxDecoration(color: t.foreground, shape: BoxShape.circle)),
          ),
          onTap: () {
            ref.read(composerProvider.notifier).setTextCardTheme(t);
            final s = ref.read(settingsProvider);
            if (s.textCardTheme != t) ref.read(settingsProvider.notifier).update((x) => x.copyWith(textCardTheme: t));
          },
        );

    Widget fontOption(TextCardFont f) => pill(
          selected: f == widget.font,
          label: switch (f) { TextCardFont.original => 'Inter', TextCardFont.platform => "${widget.platform.name}'s own", _ => f.label },
          tooltip: f == TextCardFont.original ? "NEFORUM's original font (Inter)" : 'Set the words in ${f.label}',
          leading: Text('Aa',
              style: TextStyle(
                  fontFamily: f.resolve(widget.platform.id).family,
                  fontFamilyFallback: f.resolve(widget.platform.id).fallback,
                  fontWeight: f.resolve(widget.platform.id).weight,
                  fontVariations: f.resolve(widget.platform.id).variations,
                  fontSize: 12,
                  height: 1,
                  color: nf.text)),
          onTap: () {
            ref.read(composerProvider.notifier).setTextCardFont(f);
            final s = ref.read(settingsProvider);
            if (s.textCardFont != f) ref.read(settingsProvider.notifier).update((x) => x.copyWith(textCardFont: f));
          },
        );

    final id = widget.platform.id;
    final background = widget.background;
    return Wrap(spacing: Space.xs, runSpacing: Space.xs, alignment: WrapAlignment.center, children: [
      if (background == null) for (final t in TextCardTheme.values) themeOption(t),
      for (final f in TextCardFont.values) fontOption(f),
      PopupMenuButton<TextCardAlignment>(
        tooltip: 'Alignment: ${widget.alignment.label}',
        initialValue: widget.alignment,
        position: PopupMenuPosition.under,
        onSelected: (a) {
          ref.read(composerProvider.notifier).setTextCardAlignment(a);
          final s = ref.read(settingsProvider);
          if (s.textCardAlignment != a) ref.read(settingsProvider.notifier).update((x) => x.copyWith(textCardAlignment: a));
        },
        itemBuilder: (_) => [
          for (final a in TextCardAlignment.values)
            PopupMenuItem(
              value: a,
              child: Row(children: [
                Icon(a.icon, size: 18),
                const SizedBox(width: Space.sm),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(a.label),
                    Text(a.description, style: context.text.bodySmall),
                  ]),
                ),
              ]),
            ),
        ],
        child: pill(
          selected: false,
          label: widget.alignment.label,
          leading: Icon(widget.alignment.icon, size: 14, color: nf.textMuted),
          onTap: null,
        ),
      ),
      pill(
        selected: widget.branded,
        label: 'NEFORUM signature',
        tooltip: widget.branded ? 'Signature on: tap for a plain card on ${widget.platform.name}' : 'Plain card: tap to add the NEFORUM signature',
        leading: Icon(widget.branded ? Icons.verified_rounded : Icons.do_not_disturb_on_outlined, size: 14, color: widget.branded ? nf.accent : nf.textFaint),
        onTap: () {
          final on = !widget.branded;
          ref.read(composerProvider.notifier).setTextCardBranded(id, on);
          // Remember it for this network from now on.
          ref.read(settingsProvider.notifier).update((x) => x.copyWith(
                textCardPlainPlatforms: on ? (x.textCardPlainPlatforms.where((p) => p != id).toList()) : {...x.textCardPlainPlatforms, id}.toList(),
              ));
        },
      ),
      pill(
        selected: widget.showsHandle,
        label: 'Show @handle',
        tooltip: widget.showsHandle
            ? 'Your handle (${widget.byline}) is on the card: tap to leave it off on ${widget.platform.name}'
            : 'Tap to put your handle (${widget.byline}) on the card',
        leading: Icon(Icons.alternate_email_rounded, size: 14, color: widget.showsHandle ? nf.accent : nf.textFaint),
        onTap: () {
          final on = !widget.showsHandle;
          ref.read(composerProvider.notifier).setTextCardHandle(id, on);
          // Remember it for this network from now on.
          ref.read(settingsProvider.notifier).update((x) => x.copyWith(
                textCardHandleHiddenPlatforms:
                    on ? x.textCardHandleHiddenPlatforms.where((p) => p != id).toList() : {...x.textCardHandleHiddenPlatforms, id}.toList(),
              ));
        },
      ),
      pill(
        selected: widget.withText,
        label: 'Post text too',
        tooltip: widget.withText
            ? 'Your text goes out with the card on ${widget.platform.name}: tap to post the card alone (its description keeps your words)'
            : 'Only the card goes to ${widget.platform.name}: tap to post your text with it',
        leading: Icon(widget.withText ? Icons.notes_rounded : Icons.image_outlined, size: 14, color: widget.withText ? nf.accent : nf.textFaint),
        onTap: () => ref.read(composerProvider.notifier).setTextCardWithText(id, !widget.withText),
      ),
      pill(
        selected: background != null,
        label: background == null ? 'Background: colour' : 'Background: photo',
        tooltip: 'A plain colour, or your words over a photo',
        leading: Icon(background == null ? Icons.format_color_fill_rounded : Icons.image_outlined, size: 14, color: background != null ? nf.accent : nf.textFaint),
        onTap: () => showCardBackgroundSheet(
          context,
          CardLook(
            platform: widget.platform,
            text: widget.text,
            theme: widget.current,
            font: widget.font,
            branded: widget.branded,
            alignment: widget.alignment,
            byline: widget.showsHandle ? widget.byline : null,
          ),
        ),
      ),
      Builder(
        builder: (bc) => pill(
          selected: false,
          label: _saving ? 'Saving…' : 'Save image',
          tooltip: 'Save this card as a JPEG (Downloads on a computer, the share sheet on a phone)',
          leading: Icon(Icons.download_rounded, size: 14, color: nf.textMuted),
          onTap: _saving || widget.text.isEmpty ? null : () => _save(bc),
        ),
      ),
    ]);
  }
}

/// A poll or quiz the way YouTube shows it: one outlined row per answer (the
/// correct quiz answer ticked), or captioned images for an image poll.
class PollPreview extends StatelessWidget {
  const PollPreview({super.key, required this.poll, this.media = const []});
  final PostPoll poll;
  final List<MediaAttachment> media;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final options = poll.cleanOptions;
    final correct = poll.isQuiz ? _correctClean(poll) : null;
    final images = media.where((m) => m.isImage).toList();
    final Widget body;
    if (poll.imageOptions) {
      body = LayoutBuilder(builder: (context, c) {
        const gap = 6.0;
        final w = (c.maxWidth - gap) / 2;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (var i = 0; i < options.length; i++)
            SizedBox(
              width: w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (i < images.length)
                  MediaThumb(images[i], size: w, radius: Radii.rSm)
                else
                  Container(height: w, decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rSm)),
                const SizedBox(height: 4),
                Text(options[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium),
              ]),
            ),
        ]);
      });
    } else {
      body = Column(children: [
        for (var i = 0; i < options.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            decoration: BoxDecoration(
              borderRadius: Radii.rSm,
              border: Border.all(color: correct == i ? nf.success : nf.borderStrong),
              color: correct == i ? nf.successSoft : null,
            ),
            child: Row(children: [
              Expanded(child: Text(options[i], style: context.text.bodyMedium)),
              if (correct == i) Icon(Icons.check_circle_rounded, size: 16, color: nf.success),
            ]),
          ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      body,
      const SizedBox(height: 2),
      Text(
        poll.isQuiz ? 'Quiz · ${options.length} answers' : '${poll.imageOptions ? 'Image poll' : 'Poll'} · ${options.length} answers',
        style: context.text.bodySmall?.copyWith(color: nf.textFaint),
      ),
      if (poll.isQuiz && (poll.explanation ?? '').trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('Explanation: ${poll.explanation!.trim()}', style: context.text.bodySmall),
        ),
    ]);
  }

  static int? _correctClean(PostPoll poll) {
    final c = poll.correctIndex;
    if (c == null || c < 0 || c >= poll.options.length || poll.options[c].trim().isEmpty) return null;
    return poll.options.take(c).where((o) => o.trim().isNotEmpty).length;
  }
}
class _Forum extends StatelessWidget {
  const _Forum({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final community = (v.extra['subreddit'] ?? v.extra['community'] ?? p.account.config['defaultSubreddit'] ?? p.account.config['community'] ?? '') as Object;
    final where = community.toString().isEmpty
        ? (p.descriptor.id == 'reddit' ? 'r/ (pick a subreddit)' : 'Pick a community')
        : (p.descriptor.id == 'reddit' ? 'r/${community.toString().replaceFirst(RegExp(r'^r/'), '')}' : '!$community');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 20, height: 20, decoration: BoxDecoration(color: brandFor(p.descriptor.id).color, shape: BoxShape.circle)),
        const SizedBox(width: Space.sm),
        Flexible(child: Text(where, overflow: TextOverflow.ellipsis, style: context.text.labelMedium)),
        Text('  · ${p.account.handle ?? p.account.displayName}', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ]),
      const SizedBox(height: Space.sm),
      Text(
        (v.title ?? '').isEmpty ? 'Untitled post' : v.title!,
        style: context.text.titleMedium?.copyWith(fontSize: 16.5, color: (v.title ?? '').isEmpty ? nf.textFaint : nf.text),
      ),
      if (v.media.isNotEmpty) ...[
        const SizedBox(height: Space.sm),
        MediaGrid(media: v.media),
      ] else if (v.link != null) ...[
        const SizedBox(height: Space.sm),
        _LinkCard(url: v.link!),
      ],
      if (v.text.trim().isNotEmpty) ...[
        const SizedBox(height: Space.sm),
        _PostText(v.text, maxLines: 6),
      ],
    ]);
  }
}

class _Chat extends StatelessWidget {
  const _Chat({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final brand = brandFor(p.descriptor.id).colorFor(Theme.of(context).brightness);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AccountAvatar(p.account, size: 32, showBadge: false),
      const SizedBox(width: Space.sm + 2),
      Flexible(
        child: Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: Color.alphaBlend(brand.withValues(alpha: nf.isDark ? 0.16 : 0.07), nf.surfaceSunken),
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(Radii.lg),
              bottomLeft: Radius.circular(Radii.lg),
              bottomRight: Radius.circular(Radii.lg),
              topLeft: Radius.circular(Radii.xs),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(p.account.displayName, style: context.text.labelMedium?.copyWith(color: brand)),
            if (v.media.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              MediaGrid(media: v.media, maxHeight: 220),
            ],
            const SizedBox(height: Space.xs),
            _PostText(v.isThread ? v.threadParts.join('\n\n') : v.text, empty: v.media.isEmpty),
            const SizedBox(height: Space.xs),
            Align(alignment: Alignment.centerRight, child: Text('now', style: context.text.bodySmall?.copyWith(color: nf.textFaint, fontSize: 10.5))),
          ]),
        ),
      ),
    ]);
  }
}

class _Blog extends StatelessWidget {
  const _Blog({required this.p});
  final TargetPreview p;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final v = p.variant;
    final title = (v.title ?? '').isNotEmpty ? v.title! : (v.text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'Untitled'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (v.media.isNotEmpty) ...[
        LayoutBuilder(builder: (context, c) => MediaThumb(v.media.first, size: c.maxWidth / 2.2, aspect: 2.2, radius: Radii.rMd)),
        const SizedBox(height: Space.md),
      ],
      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.headlineSmall?.copyWith(fontSize: 19)),
      const SizedBox(height: Space.xs),
      Text('By ${p.account.displayName} · ${_readingTime(v.text)} min read', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      const SizedBox(height: Space.sm),
      Text(v.text.trim().isEmpty ? 'Start writing…' : v.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
      if (v.tags.isNotEmpty) ...[
        const SizedBox(height: Space.sm + 2),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final t in v.tags.take(6)) StatusPill(t, dense: true),
        ]),
      ],
    ]);
  }

  static int _readingTime(String text) => (text.split(RegExp(r'\s+')).length / 220).ceil().clamp(1, 999);
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _PostText extends StatelessWidget {
  const _PostText(this.text, {this.maxLines, this.empty = true});
  final String text;
  final int? maxLines;

  /// Show a placeholder when the text is empty (only if nothing else shows).
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    if (text.trim().isEmpty) {
      return empty ? Text('Your words appear here', style: context.text.bodyMedium?.copyWith(color: nf.textFaint)) : const SizedBox.shrink();
    }
    final style = context.text.bodyMedium!.copyWith(height: 1.45);
    return RichText(
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      text: TextSpan(style: style, children: highlightSpans(text, style, nf)),
    );
  }
}

class _CwBar extends StatelessWidget {
  const _CwBar({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      margin: const EdgeInsets.only(top: Space.xs),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      decoration: BoxDecoration(color: nf.warningSoft, borderRadius: Radii.rXs),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 14, color: nf.warning),
        const SizedBox(width: Space.xs),
        Expanded(child: Text(text, style: context.text.labelMedium)),
        Text('Show', style: context.text.labelSmall?.copyWith(color: nf.textMuted)),
      ]),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final u = Uri.tryParse(url);
    final host = (u?.host ?? url).replaceFirst('www.', '');
    return Container(
      decoration: BoxDecoration(border: Border.all(color: nf.border), borderRadius: Radii.rMd),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
        Container(width: 64, height: 64, color: nf.surfaceSunken, child: Icon(Icons.link_rounded, color: nf.textFaint)),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(host, style: context.text.labelMedium),
            const SizedBox(height: 2),
            Text(u?.path.isNotEmpty == true ? u!.path : url, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
          ]),
        ),
        const SizedBox(width: Space.md),
      ]),
    );
  }
}

/// 1-4 media laid out the way most social apps do.
class MediaGrid extends StatelessWidget {
  const MediaGrid({super.key, required this.media, this.maxHeight = 280});
  final List<MediaAttachment> media;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      const gap = 3.0;
      final shown = media.take(4).toList();
      final extra = media.length - shown.length;
      Widget cell(MediaAttachment m, double cw, double ch, {String? overlay}) => SizedBox(
            width: cw,
            height: ch,
            child: Stack(children: [
              MediaThumb(m, size: ch, aspect: cw / ch, radius: BorderRadius.zero),
              if (overlay != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.5),
                    alignment: Alignment.center,
                    child: Text(overlay, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          );
      final Widget grid;
      switch (shown.length) {
        case 1:
          final a = shown.first.aspectRatio ?? 16 / 9;
          final h = (w / a.clamp(0.75, 2.0)).clamp(120.0, maxHeight);
          grid = cell(shown.first, w, h);
        case 2:
          final h = (w / 2 / 1.0).clamp(100.0, maxHeight * 0.8);
          grid = Row(children: [cell(shown[0], (w - gap) / 2, h), const SizedBox(width: gap), cell(shown[1], (w - gap) / 2, h)]);
        case 3:
          final h = (w * 0.56).clamp(120.0, maxHeight);
          grid = Row(children: [
            cell(shown[0], (w - gap) * 0.6, h),
            const SizedBox(width: gap),
            Column(children: [
              cell(shown[1], (w - gap) * 0.4, (h - gap) / 2),
              const SizedBox(height: gap),
              cell(shown[2], (w - gap) * 0.4, (h - gap) / 2),
            ]),
          ]);
        default:
          final cw = (w - gap) / 2;
          final ch = (cw * 0.62).clamp(70.0, maxHeight / 2);
          grid = Column(children: [
            Row(children: [cell(shown[0], cw, ch), const SizedBox(width: gap), cell(shown[1], cw, ch)]),
            const SizedBox(height: gap),
            Row(children: [cell(shown[2], cw, ch), const SizedBox(width: gap), cell(shown[3], cw, ch, overlay: extra > 0 ? '+$extra' : null)]),
          ]);
      }
      return ClipRRect(borderRadius: Radii.rMd, child: grid);
    });
  }
}

class _Issues extends StatelessWidget {
  const _Issues({required this.issues});
  final List<ValidationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final sorted = [...issues]..sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final i in sorted.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                switch (i.severity) {
                  IssueSeverity.error => Icons.error_rounded,
                  IssueSeverity.warning => Icons.warning_amber_rounded,
                  IssueSeverity.info => Icons.info_outline_rounded,
                },
                size: 15,
                color: switch (i.severity) {
                  IssueSeverity.error => nf.danger,
                  IssueSeverity.warning => nf.warning,
                  IssueSeverity.info => nf.info,
                },
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  i.message,
                  style: context.text.bodySmall?.copyWith(
                    color: i.severity == IssueSeverity.error ? nf.text : nf.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ]),
          ),
        if (sorted.length > 5)
          Text('+${sorted.length - 5} more', style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
      ]),
    );
  }
}
