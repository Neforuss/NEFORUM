import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../platform/app_auth_broker.dart';
import '../platform/browser_bridge.dart';
import '../platform/env.dart';
import '../platform/media_library.dart';
import '../platform/secure_secret_store.dart';
import '../platform/storage.dart';
import '../platform/ui_bridge.dart';
import 'demo.dart';
import 'media_host_config.dart';
import 'settings.dart';

/// Every long-lived object the app needs, created once at startup (and again
/// when the user toggles demo mode).
class AppServices {
  AppServices._({
    required this.storage,
    required this.accounts,
    required this.posts,
    required this.quotaRepo,
    required this.secrets,
    required this.registry,
    required this.http,
    required this.media,
    required this.broker,
    required this.handoff,
    required this.browserBridge,
    required this.demo,
    required this._settings,
  }) : quota = QuotaTracker(quotaRepo);

  final AppStorage storage;
  final AccountRepository accounts;
  final PostRepository posts;
  final QuotaRepository quotaRepo;
  final SecretStore secrets;
  final AdapterRegistry registry;
  final NeforumHttp http;
  final MediaLibrary media;
  final AppAuthBroker broker;
  final AppHandoffLauncher handoff;
  final QuotaTracker quota;

  /// The local server the NEFORUM browser extension fills hand-offs from.
  /// Runs on desktop while Settings > Browser extension is on, once
  /// [startBrowserBridge] was called.
  final BrowserBridge browserBridge;
  bool _bridgeWanted = false;
  bool _disposed = false;

  /// Demo workspace: simulated adapters, in-memory data.
  final bool demo;

  AppSettings _settings;
  AppSettings get settings => _settings;

  MediaHost? _mediaHost;

  /// Targets the user skipped in a hand-off sheet during the current run.
  final Set<String> _skipped = {};

  /// [browserBridge] replaces the real one in tests.
  static Future<AppServices> create({required bool demo, AppStorage? storage, BrowserBridge? browserBridge}) async {
    final st = storage ?? await openAppStorage();
    final settings = AppSettings.fromJson(await st.readJson('settings.json') ?? const {});
    final real = builtinRegistry();

    late final AccountRepository accounts;
    late final PostRepository posts;
    late final QuotaRepository quota;
    late final SecretStore secrets;
    final AdapterRegistry registry;

    if (demo) {
      accounts = InMemoryAccountRepository();
      posts = InMemoryPostRepository();
      quota = InMemoryQuotaRepository();
      secrets = InMemorySecretStore();
      registry = demoRegistry(real);
      await seedDemo(registry: registry, accounts: accounts, posts: posts, quota: quota, media: MediaLibrary(st));
    } else {
      final store = JsonFileStore(st.dataDir ?? '');
      accounts = store.accounts;
      posts = store.posts;
      quota = store.quota;
      secrets = SecureSecretStore();
      registry = real;
    }

    late final AppServices services;
    final handoff = AppHandoffLauncher(onSkip: (postId, accountId) => services._skipped.add('$postId|$accountId'));
    services = AppServices._(
      storage: st,
      accounts: accounts,
      posts: posts,
      quotaRepo: quota,
      secrets: secrets,
      registry: registry,
      http: NeforumHttp(),
      media: MediaLibrary(st),
      broker: AppAuthBroker(
        openUrl: (u) async {
          await launchUrl(u, mode: LaunchMode.externalApplication);
        },
        askPaste: (url, redirect) => UiBridge.instance.askPaste(url, redirect),
      ),
      handoff: handoff,
      // Paired browsers belong to this computer, not to a workspace: the demo
      // keeps them in the real keychain too, so trying the demo does not
      // unpair the extension.
      browserBridge: browserBridge ?? BrowserBridge.create(secrets: demo && Env.isDesktop ? SecureSecretStore() : secrets),
      demo: demo,
      settings: settings,
    );
    await services._rebuildMediaHost();
    return services;
  }

  Future<void> saveSettings(AppSettings s) async {
    final hostChanged = s.mediaHostId != _settings.mediaHostId ||
        !mapEquals(s.mediaHostConfig, _settings.mediaHostConfig) ||
        s.fallbackMediaHostId != _settings.fallbackMediaHostId ||
        !mapEquals(s.fallbackMediaHostConfig, _settings.fallbackMediaHostConfig);
    final bridgeChanged = s.browserExtension != _settings.browserExtension;
    _settings = s;
    await storage.writeJson('settings.json', s.toJson());
    if (hostChanged) await _rebuildMediaHost();
    if (bridgeChanged) await _syncBrowserBridge();
  }

  /// Starts the browser-extension bridge when this is a computer and the
  /// setting is on. Call when the UI starts (background runs leave it off).
  Future<void> startBrowserBridge() async {
    _bridgeWanted = true;
    await _syncBrowserBridge();
  }

  Future<void> _syncBrowserBridge() async {
    if (_bridgeWanted && !_disposed && Env.isDesktop && _settings.browserExtension) {
      await browserBridge.start();
    } else {
      await browserBridge.stop();
    }
  }

  Future<void> _rebuildMediaHost() async {
    _mediaHost = await buildMediaHost(_settings, secrets, http,
        onFallback: (m) => lastMediaHostFallback.value = (at: DateTime.now(), message: m));
  }

  /// The last time the fallback media host stepped in during this session,
  /// and why (shown under Settings > Media hosting).
  final ValueNotifier<({DateTime at, String message})?> lastMediaHostFallback = ValueNotifier(null);

  MediaHost? get mediaHost => _mediaHost;

  /// Call after the user edits media-host secrets.
  Future<void> refreshMediaHost() => _rebuildMediaHost();

  /// A publisher configured with the current settings.
  PublishService publisher() => PublishService(
        registry: registry,
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: quota,
        http: http,
        broker: broker,
        handoffLauncher: handoff,
        mediaHostProvider: () => _mediaHost,
        browserFills: () => Env.isDesktop && browserBridge.canFill,
        resolver: VariantResolver(_settings.resolverOptions),
        options: _settings.publishOptions,
        readMedia: media.read,
      );

  /// Context for connect flows (sign-in) outside a publish run.
  AdapterContext connectContext({void Function(String)? onProgress}) => AdapterContext(
        http: http,
        broker: broker,
        mediaHost: _mediaHost,
        onProgress: onProgress,
        readMedia: media.read,
      );

  /// Applies "Skip" choices made in hand-off sheets during a publish run.
  Future<Post?> applySkips(String postId) async {
    final mine = _skipped.where((k) => k.startsWith('$postId|')).toList();
    if (mine.isEmpty) return posts.get(postId);
    var post = await posts.get(postId);
    if (post == null) return null;
    for (final k in mine) {
      final accountId = k.split('|')[1];
      final t = post!.targetFor(accountId);
      if (t != null) post = post.withTarget(t.copyWith(status: TargetStatus.skipped));
      _skipped.remove(k);
    }
    final allDone = post!.targets.every((t) => t.isDone);
    post = post.copyWith(status: allDone ? PostStatus.published : post.status, updatedAt: DateTime.now());
    await posts.upsert(post);
    return post;
  }

  void dispose() {
    _disposed = true;
    unawaited(browserBridge.dispose());
    http.close();
  }
}
