import '../model/platform_descriptor.dart';

// The per-network options of a post, one list per network, each linked from
// its PlatformDescriptor.options. Every PostVariant.extra key an adapter reads
// is declared here once (test/post_options_declared_test.dart fails
// otherwise), and the app draws the customize sheet from these declarations.
//
// The choices follow each network's own API reference (apiField names the
// request field). `dart run tool/post_options_report.dart` prints the table.

const _api = {PlatformTier.openApi, PlatformTier.byokApi};

// ------------------------------------------------------------------ Telegram
// Bot API (core.telegram.org/bots/api). NEFORUM posts through the user's own
// bot, so nothing here depends on Telegram Premium.

/// `disable_notification` on every message of the post.
const String kTelegramSilent = 'silent';

/// `protect_content` on every message of the post.
const String kTelegramProtectContent = 'protectContent';

/// `show_caption_above_media` (sendPhoto, sendVideo, sendAnimation, and the
/// first InputMedia of an album).
const String kTelegramCaptionAbove = 'captionAboveMedia';

/// `has_spoiler` for these photos and videos (media ids), on top of the
/// spoiler every photo and video gets when the post is marked sensitive.
const String kTelegramSpoilerMedia = 'spoilerMedia';

/// `link_preview_options.is_disabled`.
const String kTelegramNoLinkPreview = 'disableLinkPreview';

/// `link_preview_options.url`.
const String kTelegramLinkPreviewUrl = 'linkPreviewUrl';

/// `link_preview_options.prefer_small_media` / `prefer_large_media`.
const String kTelegramLinkPreviewSize = 'linkPreviewSize';

/// `link_preview_options.show_above_text`.
const String kTelegramLinkPreviewAbove = 'linkPreviewAbove';

/// `message_thread_id`: the forum topic.
const String kTelegramTopic = 'topicId';

/// Several photos and videos as one album (`sendMediaGroup`) or as separate
/// messages.
const String kTelegramMediaGrouping = 'mediaGrouping';

/// `pinChatMessage` on the post's first message.
const String kTelegramPin = 'pin';

const List<PostOption> telegramOptions = [
  PostOption(
    key: kTelegramSilent,
    label: 'Send silently',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Members get the post without a notification sound.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.openApi},
    apiField: 'disable_notification',
  ),
  PostOption(
    key: kTelegramPin,
    label: 'Pin the post',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Pins the first message of the post in the chat.',
    gate: 'The bot needs the right to pin: "Edit messages of others" in a channel, "Pin messages" in a group. '
        'If Telegram refuses, the post stays up unpinned and NEFORUM says why.',
    tiers: {PlatformTier.openApi},
    apiField: 'pinChatMessage',
  ),
  PostOption(
    key: kTelegramCaptionAbove,
    label: 'Caption above the media',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'The text shows above the photo, video or album instead of below it.',
    gate: 'Photos, videos and GIFs. A sound file always shows its caption below.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.openApi},
    apiField: 'show_caption_above_media',
  ),
  PostOption(
    key: kTelegramSpoilerMedia,
    label: 'Hide behind a spoiler',
    kind: PostOptionKind.mediaSelection,
    help: 'The chosen photos and videos stay blurred until someone taps them. A post marked sensitive blurs all of them.',
    tiers: {PlatformTier.openApi},
    apiField: 'has_spoiler',
  ),
  PostOption(
    key: kTelegramNoLinkPreview,
    label: 'No link preview',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'A text message shows its link as plain text, without the preview card.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.openApi},
    apiField: 'link_preview_options.is_disabled',
  ),
  PostOption(
    key: kTelegramProtectContent,
    label: 'Protect from forwarding and saving',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Members cannot forward the post or save its photos and videos.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'protect_content',
  ),
  PostOption(
    key: kTelegramMediaGrouping,
    label: 'Several photos or videos',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('separate', 'One message each')],
    defaultLabel: 'One album',
    help: 'One message each keeps GIFs animated; the caption goes with the first one.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'sendMediaGroup',
  ),
  PostOption(
    key: kTelegramLinkPreviewSize,
    label: 'Link preview size',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('small', 'Small picture'), PostOptionChoice('large', 'Large picture')],
    defaultLabel: 'As Telegram chooses',
    help: 'For a text message with a link. Some sites have only one size.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'link_preview_options.prefer_small_media / prefer_large_media',
  ),
  PostOption(
    key: kTelegramLinkPreviewAbove,
    label: 'Link preview above the text',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'link_preview_options.show_above_text',
  ),
  PostOption(
    key: kTelegramLinkPreviewUrl,
    label: 'Link to preview',
    kind: PostOptionKind.text,
    hint: 'https://example.org/article',
    help: 'Which link gets the preview. Empty: the first link in the text.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'link_preview_options.url',
  ),
  PostOption(
    key: kTelegramTopic,
    label: 'Topic',
    kind: PostOptionKind.number,
    hint: 'e.g. 42',
    help: 'The topic of a group with topics. Its number is in a message link: t.me/c/group/TOPIC/message.',
    gate: 'Groups with topics only.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'message_thread_id',
  ),
];

// ------------------------------------------------------------------- Discord

const List<PostOption> discordOptions = [
  PostOption(
    // The app's kMentionEveryoneKey; its default is a setting.
    key: 'mentionEveryone',
    label: 'Mention @everyone',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'The first message starts with @everyone, which notifies everyone in the channel. '
        'The default is in Settings > Posting.',
    apiField: 'content, allowed_mentions.parse',
  ),
  PostOption(
    key: 'disableLinkPreview',
    label: 'No link preview',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Links stay plain text, without embeds.',
    scope: PostOptionScope.postOrAccount,
    apiField: 'flags: SUPPRESS_EMBEDS',
  ),
];

// ------------------------------------------------------------------- Bluesky

const List<PostOption> blueskyOptions = [
  PostOption(
    key: 'bluesky.selfLabel',
    label: 'Content label',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('sexual', 'Suggestive'),
      PostOptionChoice('nudity', 'Nudity'),
      PostOptionChoice('porn', 'Adult'),
      PostOptionChoice('graphic-media', 'Graphic media'),
    ],
    defaultLabel: 'None (Graphic media when the post is marked sensitive)',
    help: 'A label on the post\'s photos or video, so people who hide that content do not see them.',
    gate: 'Posts with photos or a video only.',
    tiers: {PlatformTier.openApi},
    apiField: 'labels (com.atproto.label.defs#selfLabels)',
  ),
  PostOption(
    key: 'bluesky.linkCard',
    label: 'Link card',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    help: 'A preview card for the post\'s link. Off: the link stays in the text only.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'embed (app.bsky.embed.external)',
  ),
];

// ------------------------------------------------------------------- Misskey

const List<PostOption> misskeyOptions = [
  PostOption(
    key: 'visibility',
    label: 'Who can see it',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('public', 'Public'),
      PostOptionChoice('home', 'Home (not on the public timelines)'),
      PostOptionChoice('followers', 'Followers'),
      PostOptionChoice('specified', 'Direct (the people you mention)'),
    ],
    defaultLabel: 'From the post\'s visibility',
    scope: PostOptionScope.postOrAccount,
    apiField: 'visibility',
  ),
  PostOption(
    key: 'localOnly',
    label: 'This server only',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'The note is not sent to other servers: only people on yours see it.',
    scope: PostOptionScope.postOrAccount,
    apiField: 'localOnly',
  ),
  PostOption(
    key: 'reactionAcceptance',
    label: 'Reactions',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('likeOnly', 'Likes only'),
      PostOptionChoice('likeOnlyForRemote', 'Likes only from other servers'),
      PostOptionChoice('nonSensitiveOnly', 'No sensitive reactions'),
      PostOptionChoice('nonSensitiveOnlyForLocalLikeOnlyForRemote', 'No sensitive reactions, likes only from other servers'),
    ],
    defaultLabel: 'All reactions',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'reactionAcceptance',
  ),
  PostOption(
    key: 'channelId',
    label: 'Channel ID',
    kind: PostOptionKind.text,
    hint: 'e.g. 9xyz1abc2d',
    help: 'Posts the note in a Misskey channel. The ID is the last part of the channel\'s address.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.openApi},
    apiField: 'channelId',
  ),
  PostOption(
    key: 'visibleUserIds',
    label: 'Visible to (user IDs)',
    kind: PostOptionKind.text,
    help: 'Not offered: a Direct note reaches the people it mentions, which needs no IDs.',
    surface: PostOptionSurface.internal,
    tiers: {PlatformTier.openApi},
    apiField: 'visibleUserIds',
  ),
  PostOption(
    key: 'replyId',
    label: 'Reply to (note ID)',
    kind: PostOptionKind.text,
    help: 'Not offered: NEFORUM posts new notes and threads of its own, not replies to other notes.',
    surface: PostOptionSurface.internal,
    tiers: {PlatformTier.openApi},
    apiField: 'replyId',
  ),
];

// --------------------------------------------------------------------- Lemmy

const List<PostOption> lemmyOptions = [
  PostOption(
    key: 'community',
    label: 'Community',
    kind: PostOptionKind.text,
    hint: 'e.g. selfhosted@lemmy.world',
    help: 'Empty: the account\'s community.',
    apiField: 'community_id (looked up by name)',
  ),
  PostOption(
    key: 'nsfw',
    label: 'Mark as NSFW',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'A post marked sensitive is NSFW anyway.',
    apiField: 'nsfw',
  ),
  PostOption(
    key: 'communityId',
    label: 'Community ID',
    kind: PostOptionKind.number,
    hint: 'e.g. 1234',
    help: 'Lemmy\'s number for the community. It wins over the name.',
    surface: PostOptionSurface.more,
    apiField: 'community_id',
  ),
  PostOption(
    key: 'languageId',
    label: 'Language ID',
    kind: PostOptionKind.number,
    hint: 'e.g. 37',
    help: 'Lemmy\'s number for the post\'s language. Empty: the post\'s language.',
    surface: PostOptionSurface.more,
    apiField: 'language_id',
  ),
];

// ------------------------------------------------------------------------- X

const List<PostOption> xOptions = [
  PostOption(
    key: 'replySettings',
    label: 'Who can reply',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('following', 'People you follow'),
      PostOptionChoice('mentionedUsers', 'Only people you mention'),
      PostOptionChoice('verified', 'Verified accounts'),
      PostOptionChoice('subscribers', 'Your subscribers'),
    ],
    defaultLabel: 'Everyone',
    gate: 'Your subscribers: accounts with subscriptions only.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'reply_settings',
  ),
];

// ------------------------------------------------------------------- Threads

const List<PostOption> threadsOptions = [
  PostOption(
    key: 'reply_control',
    label: 'Who can reply',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('accounts_you_follow', 'Accounts you follow'),
      PostOptionChoice('followers_only', 'Your followers'),
      PostOptionChoice('mentioned_only', 'Only people you mention'),
      PostOptionChoice('parent_post_author_only', 'Only you'),
    ],
    defaultLabel: 'Everyone',
    gate: 'Only you: posting through your own keys; the hand-off cannot set it.',
    scope: PostOptionScope.postOrAccount,
    apiField: 'reply_control',
  ),
  PostOption(
    key: 'topic_tag',
    label: 'Topic',
    kind: PostOptionKind.text,
    hint: 'e.g. Photography',
    help: 'One topic per post: 1 to 50 characters, without periods or ampersands.',
    apiField: 'topic_tag',
  ),
];

// ------------------------------------------------------------------ Facebook

const List<PostOption> facebookOptions = [
  PostOption(
    key: 'placement',
    label: 'Post or story',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('feed', 'Post'), PostOptionChoice('story', 'Story'), PostOptionChoice('feedAndStory', 'Post + Story')],
    surface: PostOptionSurface.dedicated,
    tiers: {PlatformTier.byokApi},
  ),
  PostOption(
    key: 'storyMode',
    label: 'Story (NEFORUM 1.2)',
    kind: PostOptionKind.toggle,
    help: 'The 1.2 form of Post or story, still written next to it for a story so older versions agree.',
    surface: PostOptionSurface.internal,
    tiers: {PlatformTier.byokApi},
  ),
  PostOption(
    key: 'videoTitle',
    label: 'Video title',
    kind: PostOptionKind.text,
    help: 'The title of a video post. Empty: the post\'s title.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'title (/{page-id}/videos)',
  ),
];

// ----------------------------------------------------------------- Instagram

const List<PostOption> instagramOptions = [
  PostOption(
    key: 'placement',
    label: 'Post or story',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('feed', 'Post'), PostOptionChoice('story', 'Story'), PostOptionChoice('feedAndStory', 'Post + Story')],
    surface: PostOptionSurface.dedicated,
  ),
  PostOption(
    key: 'storyMode',
    label: 'Story (NEFORUM 1.2)',
    kind: PostOptionKind.toggle,
    help: 'The 1.2 form of Post or story, still written next to it for a story so older versions agree.',
    surface: PostOptionSurface.internal,
  ),
  PostOption(
    key: 'shareToFeed',
    label: 'Reel in the feed too',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    help: 'Off: the reel shows in the Reels tab only.',
    gate: 'A single video (a reel).',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'share_to_feed',
  ),
  PostOption(
    key: 'thumbOffsetMs',
    label: 'Reel cover frame (milliseconds)',
    kind: PostOptionKind.number,
    hint: 'e.g. 2500',
    help: 'Where in the video the cover is taken, counted from the start. Empty: the first frame.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'thumb_offset',
  ),
];

// ------------------------------------------------------------------ LinkedIn

const List<PostOption> linkedInOptions = [
  PostOption(
    key: 'linkedinVisibility',
    label: 'Who can see it',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('PUBLIC', 'Anyone'),
      PostOptionChoice('CONNECTIONS', 'Connections only'),
      PostOptionChoice('LOGGED_IN', 'Signed-in LinkedIn members'),
    ],
    defaultLabel: 'From the post\'s visibility',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'visibility',
  ),
  PostOption(
    key: 'linkedinDisableReshare',
    label: 'Turn off reshares',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'isReshareDisabledByAuthor',
  ),
  PostOption(
    key: 'linkTitle',
    label: 'Link title',
    kind: PostOptionKind.text,
    help: 'The title on the article card of the post\'s link. Empty: the post\'s title.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'content.article.title',
  ),
  PostOption(
    key: 'linkDescription',
    label: 'Link description',
    kind: PostOptionKind.text,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'content.article.description',
  ),
];

// -------------------------------------------------------------------- Reddit

const List<PostOption> redditOptions = [
  PostOption(
    key: 'subreddit',
    label: 'Subreddit',
    kind: PostOptionKind.text,
    hint: 'e.g. selfhosted (without r/)',
    help: 'Empty: the account\'s default subreddit.',
    aliases: ['sr'],
    apiField: 'sr',
  ),
  PostOption(
    key: 'flairId',
    label: 'Flair ID',
    kind: PostOptionKind.text,
    hint: 'Some subreddits require one',
    help: 'The ID of one of the subreddit\'s flairs.',
    aliases: ['flair_id'],
    tiers: {PlatformTier.byokApi},
    apiField: 'flair_id',
  ),
  PostOption(
    key: 'nsfw',
    label: 'Mark as NSFW',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'A post marked sensitive is NSFW anyway.',
    tiers: {PlatformTier.byokApi},
    apiField: 'nsfw',
  ),
  PostOption(
    key: 'spoiler',
    label: 'Mark as spoiler',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'A post with a content warning is a spoiler anyway.',
    tiers: {PlatformTier.byokApi},
    apiField: 'spoiler',
  ),
  PostOption(
    key: 'flairText',
    label: 'Flair text',
    kind: PostOptionKind.text,
    help: 'Your own words for a flair that allows them (up to 64 characters).',
    aliases: ['flair_text'],
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'flair_text',
  ),
  PostOption(
    key: 'bodyAsComment',
    label: 'Text as the first comment',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    help: 'Link, image and video posts have no text on Reddit. On: your text goes out as your first comment.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
  ),
  PostOption(
    key: 'sendReplies',
    label: 'Reply notifications',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    aliases: ['sendreplies'],
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'sendreplies',
  ),
  PostOption(
    key: 'resubmit',
    label: 'Allow a link posted before',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    help: 'Off: Reddit refuses a link that is already in the subreddit.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'resubmit',
  ),
  PostOption(
    key: 'videogif',
    label: 'Video as a GIF',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'A video plays as a silent, looping GIF.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'kind: videogif',
  ),
  PostOption(
    key: 'videoPoster',
    label: 'Video poster (file path)',
    kind: PostOptionKind.text,
    help: 'Not offered: a file path on this device. Without it NEFORUM makes a plain dark poster, which Reddit replaces with a frame.',
    surface: PostOptionSurface.internal,
    tiers: {PlatformTier.byokApi},
    apiField: 'video_poster_url',
  ),
];

// -------------------------------------------------------------------- Tumblr

const List<PostOption> tumblrOptions = [
  PostOption(
    key: 'tumblrPostType',
    label: 'Post type',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('quote', 'Quote'),
      PostOptionChoice('chat', 'Chat'),
      PostOptionChoice('audio', 'Audio (a SoundCloud, Spotify or Bandcamp link)'),
    ],
    defaultLabel: 'Automatic (text, photo, video or link)',
    help: 'Quote: the text is the quote. Chat: one line per speaker, like "Alex: hi". Audio: the post\'s link is the track.',
    tiers: {PlatformTier.byokApi},
    apiField: 'content blocks (NPF)',
  ),
  PostOption(
    key: 'tumblrQuoteSource',
    label: 'Quote source',
    kind: PostOptionKind.text,
    hint: 'Who said it (for quote posts; otherwise the title is used)',
    tiers: {PlatformTier.byokApi},
  ),
  PostOption(
    key: 'state',
    label: 'Publish as',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('published', 'Published'),
      PostOptionChoice('queue', 'Queued'),
      PostOptionChoice('draft', 'Draft'),
      PostOptionChoice('private', 'Private'),
    ],
    defaultLabel: 'From the post\'s visibility',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'state',
  ),
  PostOption(
    key: 'tumblrSourceUrl',
    label: 'Source URL',
    kind: PostOptionKind.text,
    help: 'The "source" link under the post. Empty: the post\'s link.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'source_url',
  ),
  PostOption(
    key: 'linkTitle',
    label: 'Link title',
    kind: PostOptionKind.text,
    help: 'The title of the post\'s link card. Empty: the page\'s own (a sound file\'s: its artist and title).',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'link block title',
  ),
  PostOption(
    key: 'linkDescription',
    label: 'Link description',
    kind: PostOptionKind.text,
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'link block description',
  ),
];

// -------------------------------------------------------------------- TikTok
// Content Posting API. TikTok's content sharing guidelines ask apps to leave
// comments, Duet and Stitch off until the creator turns them on.

const List<PostOption> tikTokOptions = [
  PostOption(
    key: 'privacyLevel',
    label: 'Who can watch',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('PUBLIC_TO_EVERYONE', 'Everyone'),
      PostOptionChoice('MUTUAL_FOLLOW_FRIENDS', 'Friends'),
      PostOptionChoice('FOLLOWER_OF_CREATOR', 'Followers'),
      PostOptionChoice('SELF_ONLY', 'Only me'),
    ],
    defaultLabel: 'Only me',
    gate: 'Apps TikTok has not audited can only post for Only me.',
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.privacy_level',
  ),
  PostOption(
    key: 'allowComments',
    label: 'Allow comments',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.disable_comment',
  ),
  PostOption(
    key: 'allowDuet',
    label: 'Allow Duet',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    gate: 'Videos only.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.disable_duet',
  ),
  PostOption(
    key: 'allowStitch',
    label: 'Allow Stitch',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    gate: 'Videos only.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.disable_stitch',
  ),
  PostOption(
    key: 'isAigc',
    label: 'Made with AI',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'TikTok labels the post as AI-generated content.',
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.is_aigc',
  ),
  PostOption(
    key: 'postMode',
    label: 'Send as',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('draft', 'A draft in my TikTok inbox')],
    defaultLabel: 'A post',
    help: 'A draft waits in TikTok for you to finish it there. A video draft carries no caption.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_mode',
  ),
  PostOption(
    key: 'brandContent',
    label: 'Paid partnership',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'The post promotes a brand that pays you. TikTok shows "Paid partnership".',
    gate: 'Not with Only me.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.brand_content_toggle',
  ),
  PostOption(
    key: 'brandOrganic',
    label: 'Promotes my own business',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'TikTok shows "Promotional content".',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.brand_organic_toggle',
  ),
  PostOption(
    key: 'coverTimestampMs',
    label: 'Video cover frame (milliseconds)',
    kind: PostOptionKind.number,
    hint: 'e.g. 1000',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.video_cover_timestamp_ms',
  ),
  PostOption(
    key: 'photoCoverIndex',
    label: 'Cover photo (0 is the first)',
    kind: PostOptionKind.number,
    hint: '0',
    gate: 'Photo posts only.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'source_info.photo_cover_index',
  ),
  PostOption(
    key: 'autoAddMusic',
    label: 'Add music',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'TikTok adds a recommended sound.',
    gate: 'Photo posts only.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'post_info.auto_add_music',
  ),
];

// ----------------------------------------------------------------- Pinterest

const List<PostOption> pinterestOptions = [
  PostOption(
    key: 'pinterestBoardId',
    label: 'Board ID',
    kind: PostOptionKind.text,
    hint: 'Numbers only',
    help: 'Empty: the board chosen for the account.',
    aliases: ['board'],
    tiers: {PlatformTier.byokApi},
    apiField: 'board_id',
  ),
  PostOption(
    key: 'pinterestBoardSectionId',
    label: 'Board section ID',
    kind: PostOptionKind.text,
    hint: 'Numbers only',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'board_section_id',
  ),
  PostOption(
    key: 'pinterestCoverImageUrl',
    label: 'Video cover image (link)',
    kind: PostOptionKind.text,
    hint: 'https://',
    gate: 'Video Pins.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'media_source.cover_image_url',
  ),
  PostOption(
    key: 'pinterestCoverKeyFrameSeconds',
    label: 'Video cover frame (seconds)',
    kind: PostOptionKind.number,
    hint: '1',
    gate: 'Video Pins without a cover image.',
    surface: PostOptionSurface.more,
    tiers: {PlatformTier.byokApi},
    apiField: 'media_source.cover_image_key_frame_time',
  ),
  PostOption(
    key: 'pinterestMediaUrl',
    label: 'Media link',
    kind: PostOptionKind.text,
    help: 'Set by NEFORUM: the link of the media on your media host, when it is there already.',
    aliases: ['mediaUrl'],
    surface: PostOptionSurface.internal,
    tiers: {PlatformTier.byokApi},
    apiField: 'media_source.url',
  ),
];

// ------------------------------------------------------------------- YouTube

const List<PostOption> youTubeOptions = [
  PostOption(
    key: 'privacyStatus',
    label: 'Visibility',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('public', 'Public'),
      PostOptionChoice('unlisted', 'Unlisted (only people with the link)'),
      PostOptionChoice('private', 'Private'),
    ],
    defaultLabel: 'From the post\'s visibility',
    tiers: {PlatformTier.byokApi},
    apiField: 'status.privacyStatus',
  ),
  PostOption(
    key: 'categoryId',
    label: 'Category',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('1', 'Film & Animation'),
      PostOptionChoice('2', 'Autos & Vehicles'),
      PostOptionChoice('10', 'Music'),
      PostOptionChoice('15', 'Pets & Animals'),
      PostOptionChoice('17', 'Sports'),
      PostOptionChoice('19', 'Travel & Events'),
      PostOptionChoice('20', 'Gaming'),
      PostOptionChoice('22', 'People & Blogs'),
      PostOptionChoice('23', 'Comedy'),
      PostOptionChoice('24', 'Entertainment'),
      PostOptionChoice('25', 'News & Politics'),
      PostOptionChoice('26', 'Howto & Style'),
      PostOptionChoice('27', 'Education'),
      PostOptionChoice('28', 'Science & Technology'),
      PostOptionChoice('29', 'Nonprofits & Activism'),
    ],
    defaultLabel: 'People & Blogs (YouTube\'s default)',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'snippet.categoryId',
  ),
  PostOption(
    key: 'madeForKids',
    label: 'Made for kids',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'YouTube asks this of every video. A video made for kids gets no personalised ads and no comments.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'status.selfDeclaredMadeForKids',
  ),
  PostOption(
    key: 'containsSyntheticMedia',
    label: 'Altered or synthetic content',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Realistic content made or changed with AI or other tools: YouTube shows viewers a label.',
    tiers: {PlatformTier.byokApi},
    apiField: 'status.containsSyntheticMedia',
  ),
  PostOption(
    key: 'notifySubscribers',
    label: 'Tell my subscribers',
    kind: PostOptionKind.toggle,
    defaultValue: true,
    help: 'Off: the video goes up without a notification to subscribers.',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'notifySubscribers',
  ),
  PostOption(
    // YouTubeAdapter.thumbnailKey: a picture picked in its own control.
    key: 'thumbnail',
    label: 'Thumbnail',
    kind: PostOptionKind.text,
    surface: PostOptionSurface.dedicated,
    gate: 'A verified channel. If YouTube refuses it, the video still goes and NEFORUM says why.',
    tiers: {PlatformTier.byokApi},
    apiField: 'thumbnails.set',
  ),
];

const List<PostOption> youTubePostsOptions = [
  PostOption(
    // The app's kTextCardChoiceKey: the app reads it, to give the target its
    // text card or not.
    key: 'textCardChoice',
    label: 'A post with words only',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('card', 'With a text card (an image of the words)'), PostOptionChoice('text', 'Text only')],
    defaultLabel: 'A text card when the post makes one for another network',
    help: 'YouTube Posts takes the words alone or with an image. The card is the one your other networks get.',
  ),
];

// --------------------------------------------------------------------- Blogs

const PostOption _slug = PostOption(
  key: 'slug',
  label: 'Address (slug)',
  kind: PostOptionKind.text,
  hint: 'my-post-title',
  help: 'The last part of the post\'s address. Empty: made from the title.',
  surface: PostOptionSurface.more,
  tiers: _api,
);

const PostOption _canonical = PostOption(
  key: 'canonicalUrl',
  label: 'Original address (canonical URL)',
  kind: PostOptionKind.text,
  hint: 'https://',
  help: 'Where the post first appeared, so search engines credit that page.',
  surface: PostOptionSurface.more,
  tiers: _api,
);

const PostOption _excerpt = PostOption(
  key: 'excerpt',
  label: 'Excerpt',
  kind: PostOptionKind.text,
  help: 'A short summary for lists and previews.',
  surface: PostOptionSurface.more,
  tiers: _api,
);

const PostOption _featuredImage = PostOption(
  key: 'featuredImage',
  label: 'First photo as the featured image',
  kind: PostOptionKind.toggle,
  defaultValue: true,
  help: 'Off: every photo goes in the text.',
  scope: PostOptionScope.postOrAccount,
  surface: PostOptionSurface.more,
  tiers: _api,
);

const PostOption _rawHtml = PostOption(
  key: 'html',
  label: 'The text is HTML',
  kind: PostOptionKind.toggle,
  defaultValue: false,
  help: 'On: the text goes in as written. Off: NEFORUM turns paragraphs and links into HTML.',
  surface: PostOptionSurface.more,
  tiers: _api,
);

const PostOption _rawHtmlFormat = PostOption(
  key: 'format',
  label: 'Text format',
  kind: PostOptionKind.text,
  help: 'An older form of "The text is HTML" ("html"), still read.',
  surface: PostOptionSurface.internal,
  tiers: _api,
);

const PostOption _coverFromFirstImage = PostOption(
  key: 'coverFromFirstImage',
  label: 'First photo as the cover',
  kind: PostOptionKind.toggle,
  defaultValue: true,
  help: 'Off: every photo goes in the text.',
  scope: PostOptionScope.postOrAccount,
  surface: PostOptionSurface.more,
  tiers: _api,
);

const List<PostOption> wordPressOptions = [
  PostOption(
    key: 'status',
    label: 'Publish as',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('publish', 'Published'),
      PostOptionChoice('draft', 'Draft'),
      PostOptionChoice('pending', 'Pending review'),
      PostOptionChoice('private', 'Private'),
    ],
    defaultLabel: 'As the account is set (scheduled when the post is)',
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'status',
  ),
  PostOption(
    key: 'categories',
    label: 'Categories',
    kind: PostOptionKind.text,
    hint: 'News, Photos (names or IDs)',
    help: 'Separated by commas. Empty: the account\'s categories.',
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'categories',
  ),
  _excerpt,
  _slug,
  _featuredImage,
  _rawHtml,
  _rawHtmlFormat,
];

const List<PostOption> ghostOptions = [
  PostOption(
    key: 'status',
    label: 'Publish as',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('published', 'Published'), PostOptionChoice('draft', 'Draft')],
    defaultLabel: 'As the account is set (scheduled when the post is)',
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'status',
  ),
  PostOption(
    key: 'ghostVisibility',
    label: 'Who can read it',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('public', 'Everyone'),
      PostOptionChoice('members', 'Members'),
      PostOptionChoice('paid', 'Paid members'),
      PostOptionChoice('tiers', 'Specific tiers (chosen in Ghost)'),
    ],
    defaultLabel: 'From the post\'s visibility',
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'visibility',
  ),
  _excerpt,
  _slug,
  _canonical,
  _featuredImage,
  PostOption(
    key: 'ghostHtmlCard',
    label: 'Whole post as one HTML card',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Ghost\'s editor keeps the post exactly as sent, as a single HTML card.',
    surface: PostOptionSurface.more,
    tiers: _api,
  ),
  _rawHtml,
  _rawHtmlFormat,
];

const List<PostOption> writeFreelyOptions = [
  PostOption(
    key: 'font',
    label: 'Font',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('norm', 'Serif'),
      PostOptionChoice('sans', 'Sans-serif'),
      PostOptionChoice('mono', 'Monospace'),
      PostOptionChoice('wrap', 'Monospace, wrapped'),
      PostOptionChoice('code', 'Code'),
    ],
    defaultLabel: 'The blog\'s font',
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'font',
  ),
  PostOption(
    key: 'rtl',
    label: 'Right-to-left text',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'Off: right to left only when the post\'s language is written that way.',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'rtl',
  ),
  _slug,
];

const List<PostOption> micropubOptions = [
  PostOption(
    key: 'postStatus',
    label: 'Publish as',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('published', 'Published'), PostOptionChoice('draft', 'Draft')],
    defaultLabel: 'As the site decides (usually published)',
    scope: PostOptionScope.postOrAccount,
    apiField: 'post-status',
  ),
  PostOption(
    key: 'draft',
    label: 'Draft',
    kind: PostOptionKind.toggle,
    help: 'An older form of "Publish as: Draft", still read.',
    surface: PostOptionSurface.internal,
    apiField: 'post-status',
  ),
  PostOption(
    key: 'syndicateTo',
    label: 'Syndicate to',
    kind: PostOptionKind.text,
    hint: 'https://example.social/@me',
    help: 'Where the site copies the post, as its UIDs separated by commas. Empty: the account\'s list.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    apiField: 'mp-syndicate-to',
  ),
  PostOption(
    key: 'destination',
    label: 'Destination',
    kind: PostOptionKind.text,
    help: 'Which of the site\'s blogs gets the post, by its UID. Empty: the account\'s.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    apiField: 'mp-destination',
  ),
  PostOption(
    key: 'slug',
    label: 'Address (slug)',
    kind: PostOptionKind.text,
    hint: 'my-post-title',
    surface: PostOptionSurface.more,
    apiField: 'mp-slug',
  ),
];

const List<PostOption> devtoOptions = [
  PostOption(
    key: 'draft',
    label: 'Save as a draft',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    scope: PostOptionScope.postOrAccount,
    tiers: _api,
    apiField: 'published',
  ),
  PostOption(
    key: 'series',
    label: 'Series',
    kind: PostOptionKind.text,
    help: 'Articles with the same series name are linked together.',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'series',
  ),
  PostOption(
    key: 'description',
    label: 'Description',
    kind: PostOptionKind.text,
    help: 'The summary under the title in feeds and search.',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'description',
  ),
  _canonical,
  PostOption(
    key: 'mainImage',
    label: 'Cover image (link)',
    kind: PostOptionKind.text,
    hint: 'https://',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'main_image',
  ),
  _coverFromFirstImage,
  PostOption(
    key: 'organizationId',
    label: 'Organization ID',
    kind: PostOptionKind.number,
    help: 'Posts the article under an organization you belong to.',
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'organization_id',
  ),
];

const List<PostOption> hashnodeOptions = [
  PostOption(
    key: 'subtitle',
    label: 'Subtitle',
    kind: PostOptionKind.text,
    tiers: _api,
    apiField: 'subtitle',
  ),
  PostOption(
    key: 'disableComments',
    label: 'Turn off comments',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    scope: PostOptionScope.postOrAccount,
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'disableComments',
  ),
  _slug,
  PostOption(
    key: 'canonicalUrl',
    label: 'Original address (canonical URL)',
    kind: PostOptionKind.text,
    hint: 'https://',
    help: 'Where the post first appeared, so search engines credit that page.',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'originalArticleURL',
  ),
  PostOption(
    key: 'coverImageUrl',
    label: 'Cover image (link)',
    kind: PostOptionKind.text,
    hint: 'https://',
    surface: PostOptionSurface.more,
    tiers: _api,
    apiField: 'coverImageOptions.coverImageURL',
  ),
  _coverFromFirstImage,
];

// ----------------------------------------------------------------------- Art

const List<PostOption> flickrOptions = [
  PostOption(
    key: 'flickrContentType',
    label: 'Content type',
    kind: PostOptionKind.choice,
    choices: [PostOptionChoice('photo', 'Photo'), PostOptionChoice('screenshot', 'Screenshot'), PostOptionChoice('art', 'Art or illustration')],
    defaultLabel: 'Art or illustration',
    scope: PostOptionScope.postOrAccount,
    tiers: {PlatformTier.byokApi},
    apiField: 'content_type',
  ),
];

const List<PostOption> inkbunnyOptions = [
  PostOption(
    key: 'inkbunnyType',
    label: 'Submission type',
    kind: PostOptionKind.choice,
    choices: [
      PostOptionChoice('1', 'Picture/Pinup'),
      PostOptionChoice('2', 'Sketch'),
      PostOptionChoice('3', 'Picture Series'),
      PostOptionChoice('4', 'Comic'),
      PostOptionChoice('5', 'Portfolio'),
      PostOptionChoice('13', 'Character Sheet'),
      PostOptionChoice('14', 'Photography'),
    ],
    defaultLabel: 'As Inkbunny sets it',
    tiers: {PlatformTier.openApi},
    apiField: 'type (api_editsubmission.php)',
  ),
  PostOption(
    key: 'inkbunnyScraps',
    label: 'Put in Scraps',
    kind: PostOptionKind.toggle,
    defaultValue: false,
    help: 'The submission goes in your Scraps gallery instead of the main one.',
    tiers: {PlatformTier.openApi},
    apiField: 'scraps',
  ),
];
