import 'adapter_registry.dart';
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
import 'x/x_adapter.dart';
import 'youtube/youtube_adapter.dart';

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
      YouTubeAdapter(),
      PinterestAdapter(),
      SnapchatAdapter(),
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
    ];

/// A registry with every built-in adapter.
AdapterRegistry builtinRegistry() => AdapterRegistry(builtinAdapters());
