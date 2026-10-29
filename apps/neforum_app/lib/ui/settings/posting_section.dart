
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../state/shrunk_videos.dart';
import '../../theme/tokens.dart';
import 'setting_row.dart';

class PostingSettingsSection extends ConsumerWidget {
  const PostingSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final canShrink = ref.watch(videoShrinkingSupportedProvider).value ?? false;
    return SettingsSection(title: 'Posting', icon: Icons.send_outlined, subtitle: 'How NEFORUM adapts one post for many networks.', children: [
      SettingChoice<OverflowStrategy>(
        title: 'When a post is too long for a network',
        value: s.overflow,
        onChanged: (v) => n.update((x) => x.copyWith(overflow: v)),
        options: const [
          (OverflowStrategy.threadOrError, 'Split into a thread, or ask me to shorten it', 'Recommended. Networks without threads ask you to customize the text.'),
          (OverflowStrategy.threadOrTruncate, 'Split into a thread, or shorten it with …', 'Never blocks posting.'),
          (OverflowStrategy.truncate, 'Always shorten it with …', 'Never makes threads.'),
          (OverflowStrategy.error, 'Never change my text', 'You customize the text for networks where it does not fit.'),
        ],
      ),
      SettingChoice<PhotoFitMode>(
        title: 'When a photo does not fit a network',
        description: 'Instagram takes photos from 4:5 (portrait) to 1.91:1 (wide), some networks only JPEG or files up to a size. '
            'That network gets an adjusted copy; your photo stays as it is everywhere else.',
        value: s.photoFit,
        onChanged: (v) => n.update((x) => x.copyWith(photoFit: v)),
        options: const [
          (PhotoFitMode.pad, 'Add borders', 'Recommended. The whole photo stays, on a soft blur of its own colours.'),
          (PhotoFitMode.color, 'Fill with its colours', 'The whole photo stays; the space around it is filled with its dominant colours, '
              'flowing from its edges like Instagram stories. No black bars.'),
          (PhotoFitMode.crop, 'Crop it to fit', 'Cuts the edges, keeping the middle.'),
          (PhotoFitMode.off, 'Never change my photos', 'The network shows an error and you replace the photo yourself.'),
        ],
      ),
      SettingRow(
        title: 'Fill the whole frame',
        description: 'Fit every photo to the frame these networks show it in, the way chosen above, so nothing is cut off and there '
            'are no black bars: TikTok 9:16, Instagram 4:5 (stories 9:16). You can also switch it under the preview.',
        enabled: s.photoFit != PhotoFitMode.off,
        below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final id in const ['tiktok', 'instagram'])
            FilterChip(
              label: Text(ref.watch(registryProvider).descriptor(id)?.name ?? id),
              avatar: PlatformTile(id, size: 18),
              selected: s.fillsFrame(id),
              onSelected: s.photoFit == PhotoFitMode.off
                  ? null
                  : (on) => n.update((x) => x.copyWith(
                        fillFramePlatforms: on ? {...x.fillFramePlatforms, id}.toList() : x.fillFramePlatforms.where((p) => p != id).toList(),
                      )),
            ),
        ]),
      ),
      SettingRow(
        title: 'Write the caption on the first photo or video',
        description: 'Your caption, set on the photo in the network\'s own font (TikTok Sans on TikTok, Instagram Sans on Instagram), '
            'on a label clear of the network\'s buttons or in a block above the photo (Settings > Text cards sets the style). A video '
            'gets the block above it: NEFORUM makes a copy in the network\'s 9:16 frame on this device. The caption is still posted as '
            'text too. You can also switch it per post under the preview.',
        below: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final id in const ['tiktok', 'instagram'])
            FilterChip(
              label: Text(ref.watch(registryProvider).descriptor(id)?.name ?? id),
              avatar: PlatformTile(id, size: 18),
              selected: s.captionOnPhoto(id),
              onSelected: (on) => n.update((x) => x.copyWith(
                    captionPhotoPlatforms: on ? {...x.captionPhotoPlatforms, id}.toList() : x.captionPhotoPlatforms.where((p) => p != id).toList(),
                  )),
            ),
        ]),
      ),
      // 1.3: video
      SettingSwitch(
        title: 'Shrink videos that are too big for a network',
        description: canShrink
            ? 'When a video is over a network\'s size limit, NEFORUM makes a smaller copy for that network as it posts, just '
                'under that network\'s own limit, on this device. Networks where the video fits get it as it is. A long video '
                'takes a while to shrink.'
            : 'This device cannot make video copies, so a video over a network\'s size limit has to be made smaller before you attach it.',
        value: s.shrinkOversizedVideos,
        onChanged: canShrink ? (v) => n.update((x) => x.copyWith(shrinkOversizedVideos: v)) : null,
      ),
      SettingSwitch(title: 'Number thread parts', description: 'Adds (1/3), (2/3)… to each part.', value: s.threadNumbering, onChanged: (v) => n.update((x) => x.copyWith(threadNumbering: v))),
      SettingSwitch(title: 'Add my hashtags to the text', description: 'Where the network has no separate tags field.', value: s.appendHashtags, onChanged: (v) => n.update((x) => x.copyWith(appendHashtags: v))),
      SettingSwitch(title: 'Add my link to the text', description: 'Where the network has no link field and the link is not in the text yet.', value: s.appendLink, onChanged: (v) => n.update((x) => x.copyWith(appendLink: v))),
      SettingSwitch(
        title: 'Mention @everyone on Discord',
        description: 'Discord posts start with @everyone, which notifies everyone in the channel. '
            'You can switch it for one post in Customize.',
        value: s.discordMentionEveryone,
        onChanged: (v) => n.update((x) => x.copyWith(discordMentionEveryone: v)),
      ),
      SettingSwitch(
        title: 'Hand off when an API limit is reached',
        description: 'If an account runs out of quota, NEFORUM opens the app for you instead of failing.',
        value: s.fallbackToHandoff,
        onChanged: (v) => n.update((x) => x.copyWith(fallbackToHandoff: v)),
      ),
      SettingSwitch(title: 'Ask before posting', value: s.confirmBeforePosting, onChanged: (v) => n.update((x) => x.copyWith(confirmBeforePosting: v))),
      SettingRow(
        title: 'Default visibility',
        description: 'For networks that support it.',
        trailing: DropdownButton<PostVisibility>(
          value: s.defaultVisibility,
          underline: const SizedBox.shrink(),
          borderRadius: Radii.rMd,
          items: const [
            DropdownMenuItem(value: PostVisibility.public, child: Text('Public')),
            DropdownMenuItem(value: PostVisibility.unlisted, child: Text('Unlisted')),
            DropdownMenuItem(value: PostVisibility.followers, child: Text('Followers only')),
            DropdownMenuItem(value: PostVisibility.private, child: Text('Private')),
          ],
          onChanged: (v) {
            if (v != null) n.update((x) => x.copyWith(defaultVisibility: v));
          },
        ),
      ),
    ]);
  }
}
