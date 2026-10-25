import 'adapter_registry.dart';
import 'art/artfol_adapter.dart';
import 'art/artstation_adapter.dart';
import 'art/behance_adapter.dart';
import 'art/cara_adapter.dart';
import 'art/deviantart_adapter.dart';
import 'art/dribbble_adapter.dart';
import 'art/fivehundredpx_adapter.dart';
import 'art/flickr_adapter.dart';
import 'art/furaffinity_adapter.dart';
import 'art/inkbunny_adapter.dart';
import 'art/itaku_adapter.dart';
import 'art/kofi_adapter.dart';
import 'art/newgrounds_adapter.dart';
import 'art/pixelfed_adapter.dart';
import 'art/pixiv_adapter.dart';
import 'art/weasyl_adapter.dart';
import 'blogs_a/ghost_adapter.dart';
import 'blogs_a/wordpress_adapter.dart';
import 'blogs_a/writefreely_adapter.dart';
import 'blogs_b/devto_adapter.dart';
import 'blogs_b/hashnode_adapter.dart';
import 'blogs_b/micropub_adapter.dart';
import 'bluesky/bluesky_adapter.dart';
import 'chat/discord_adapter.dart';
import 'chat/matrix_adapter.dart';
import 'chat/telegram_adapter.dart';
import 'facebook/facebook_adapter.dart';
import 'handoff_only/google_business_adapter.dart';
import 'handoff_only/snapchat_adapter.dart';
import 'handoff_only/substack_adapter.dart';
import 'handoff_only/whatsapp_adapter.dart';
import 'instagram/instagram_adapter.dart';
import 'lemmy/lemmy_adapter.dart';
import 'linkedin/linkedin_adapter.dart';
import 'mastodon/mastodon_adapter.dart';
import 'misskey/misskey_adapter.dart';
import 'nostr/nostr_adapter.dart';
import 'pinterest/pinterest_adapter.dart';
import 'platform_adapter.dart';
import 'reddit/reddit_adapter.dart';
import 'threads/threads_adapter.dart';
import 'tiktok/tiktok_adapter.dart';
import 'tumblr/tumblr_adapter.dart';
import 'video_sites/bitchute_adapter.dart';
import 'video_sites/odysee_adapter.dart';
import 'video_sites/rumble_adapter.dart';
import 'x/x_adapter.dart';
import 'youtube/youtube_adapter.dart';
import 'youtube/youtube_posts_adapter.dart';

/// Every platform adapter shipped with NEFORUM.
List<PlatformAdapter> builtinAdapters() => [
      // Open networks
      MastodonAdapter(),
      BlueskyAdapter(),
      MisskeyAdapter(),
      NostrAdapter(),
      LemmyAdapter(),
      MatrixAdapter(),
      // Big platforms
      XAdapter(),
      ThreadsAdapter(),
      FacebookAdapter(),
      LinkedInAdapter(),
      RedditAdapter(),
      TumblrAdapter(),
      // Photo & video
      InstagramAdapter(),
      TikTokAdapter(),
      YouTubePostsAdapter(),
      PinterestAdapter(),
      SnapchatAdapter(),
      // Video sites
      YouTubeAdapter(),
      RumbleAdapter(),
      OdyseeAdapter(),
      BitChuteAdapter(),
      // Messaging
      TelegramAdapter(),
      DiscordAdapter(),
      WhatsAppAdapter(),
      // Blogs & newsletters
      WordPressAdapter(),
      GhostAdapter(),
      WriteFreelyAdapter(),
      MicropubAdapter(),
      DevtoAdapter(),
      HashnodeAdapter(),
      SubstackAdapter(),
      // Business
      GoogleBusinessAdapter(),
      // Art and portfolios (posting through an API)
      DeviantArtAdapter(),
      DribbbleAdapter(),
      PixelfedAdapter(),
      FlickrAdapter(),
      InkbunnyAdapter(),
      // Art and portfolios (hand-off)
      BehanceAdapter(),
      ArtStationAdapter(),
      CaraAdapter(),
      PixivAdapter(),
      ItakuAdapter(),
      NewgroundsAdapter(),
      FurAffinityAdapter(),
      WeasylAdapter(),
      KofiAdapter(),
      ArtfolAdapter(),
      FiveHundredPxAdapter(),
    ];

/// A registry with every built-in adapter.
AdapterRegistry builtinRegistry() => AdapterRegistry(builtinAdapters());
