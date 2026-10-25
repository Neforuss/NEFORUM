import 'dart:async';

import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../platform/browser_bridge.dart';
import '../platform/env.dart';
import '../platform/notifications.dart';
import 'services.dart';

/// The page automatic posting opens for [plan]: the platform's full composer,
/// else its prefilled composer link, else its page. Null when none of them
/// is a web page.
Uri? automaticHandoffPage(HandoffPlan plan) {
  final desktop = plan.desktopUrl == null ? null : Uri.tryParse(plan.desktopUrl!);
  for (final url in [plan.composerUrl, plan.webIntent, desktop]) {
    if (url != null && (url.isScheme('http') || url.isScheme('https'))) return url;
  }
  return null;
}

/// Posts the hand-off targets of a scheduled post through the NEFORUM
/// browser extension, without the hand-off sheet, while NEFORUM runs on a
/// computer with automatic posting on (Settings > Browser extension > Post
/// automatically) and a paired browser.
///
/// One target at a time, since the bridge holds one job: NEFORUM opens the
/// page in the browser, the extension fills it in, counts down and presses
/// Post, and once it confirms the post the target is marked handed off.
/// Anything else (the countdown stopped, something not filled in, no answer)
/// leaves the target waiting, with the usual "Time to post" notification.
class AutomaticHandoff {
  AutomaticHandoff(
    this._s, {
    this.firstReport = const Duration(minutes: 2),
    this.posting = const Duration(minutes: 4),
    Future<bool> Function(Uri url)? openDefault,
  }) : _openDefault = openDefault ?? ((url) => launchUrl(url, mode: LaunchMode.externalApplication));

  final AppServices _s;

  /// How long to wait for the extension's first report on a page, and, once
  /// its countdown started, for the post to go out (uploads take a while).
  final Duration firstReport;
  final Duration posting;

  /// Opens a page in the system's default browser (tests put a stand-in here).
  final Future<bool> Function(Uri url) _openDefault;

  bool get _available => Env.isDesktop && _s.settings.automaticHandoffPosting && _s.browserBridge.canFill;

  /// Posts the waiting hand-off targets of [post] automatically where that
  /// applies, and returns the post as it is afterwards. Only for runs nobody
  /// watches ([unattended]): an interactive run has shown the sheet already.
  Future<Post> complete(Post post, {bool unattended = true}) async {
    if (!unattended || !_available) return post;
    var current = post;
    var posted = 0;
    for (final target in post.targets) {
      if (target.status != TargetStatus.awaitingHandoff) continue;
      final account = await _s.accounts.get(target.accountId);
      if (account == null || !_s.settings.postsHandoffAutomatically(account.platformId)) continue;
      // A hand-off sheet is open (its job is in the bridge): this one waits.
      if (_s.browserBridge.job != null) break;
      if (await _post(current, target, account)) {
        current = await _s.publisher().confirmHandoff(current.id, target.accountId);
        posted++;
      }
    }
    // Nothing left to post by hand: the reminder at the post's time is moot.
    if (posted > 0 && !current.targets.any((t) => t.status == TargetStatus.awaitingHandoff)) {
      await NotificationService.instance.cancel('due:${post.id}');
    }
    return current;
  }

  /// Opens the page for one target and waits for the extension. True once it
  /// confirmed the post.
  Future<bool> _post(Post post, PostTarget target, ConnectedAccount account) async {
    final adapter = _s.registry.byId(account.platformId);
    if (adapter == null) return false;
    final publisher = _s.publisher();
    final HandoffPlan? planned;
    try {
      planned = await publisher.planHandoff(post, account.id);
    } on Object {
      return false;
    }
    if (planned == null) return false;
    final plan = planned;
    final url = automaticHandoffPage(plan);
    if (url == null) return false;
    final descriptor = adapter.descriptorForAccount(account);
    final variant = publisher.resolver.resolve(post, target, descriptor, account: account);
    final bridge = _s.browserBridge;

    final done = Completer<bool>();
    Timer? timer;
    void finish(bool ok) {
      if (!done.isCompleted) done.complete(ok);
    }

    void wait(Duration d) {
      timer?.cancel();
      timer = Timer(d, () => finish(false));
    }

    BrowserJob? job;
    final sub = bridge.results.listen((r) {
      if (r.jobId != job?.id) return;
      if (r.posted == BrowserPostState.confirmed) return finish(true);
      if (r.posted == BrowserPostState.pressed) return finish(false);
      switch (r.automatic) {
        case BrowserAutomaticState.countdown:
          wait(posting);
        case BrowserAutomaticState.stopped:
        case BrowserAutomaticState.manual:
        // An extension before 1.1.0 fills in but never posts by itself.
        case BrowserAutomaticState.none:
          finish(false);
      }
    });
    BrowserJob? makeJob(String? target) => bridge.createJob(
          platformId: account.platformId,
          platformName: descriptor.name,
          url: url.toString(),
          hosts: browserJobHosts(url, platformId: account.platformId),
          text: plan.clipboardText ?? plan.shareText ?? variant.text,
          title: variant.title,
          snippets: plan.snippets,
          media: browserJobMedia(plan.shareFiles, _s.media.read),
          steps: plan.composerInstructions ?? plan.instructions,
          quickPost: _s.settings.browserQuickPost,
          autoPost: true,
          details: BrowserJobDetails.fromVariant(variant),
          target: target,
        );
    try {
      final first = _s.settings.browserOpenInFirst ? await bridge.firstChoice() : null;
      job = makeJob(first?.program.id);
      if (job == null) return false;
      wait(firstReport);
      var opened = first != null && await BrowserBridge.openInBrowser(first.program.id, url);
      if (!opened) {
        // That browser would not start: the default one, and any browser fills in.
        if (first != null) job = makeJob(null);
        opened = job != null && await _openDefault(url);
      }
      if (!opened) finish(false);
      return await done.future;
    } finally {
      timer?.cancel();
      await sub.cancel();
      final id = job?.id;
      if (id != null) bridge.clearJob(id);
    }
  }
}
