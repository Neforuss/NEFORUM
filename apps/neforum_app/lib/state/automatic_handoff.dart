import 'dart:async';

import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../platform/browser_bridge.dart';
import '../platform/notifications.dart';
import 'services.dart';

/// The page automatic posting opens for [plan]: the platform's full composer,
/// else its prefilled composer link, else its page, the first of them that
/// the extension fills in by itself ([extensionFillsPage]). Null when none
/// is: nothing there could ever report back.
Uri? automaticHandoffPage(HandoffPlan plan) {
  final desktop = plan.desktopUrl == null ? null : Uri.tryParse(plan.desktopUrl!);
  for (final url in [plan.composerUrl, plan.webIntent, desktop]) {
    if (url != null && extensionFillsPage(url, platformId: plan.platformId)) return url;
  }
  return null;
}

/// Whether [account]'s hand-offs are posted automatically: hand-offs go to
/// the browser extension ([AppServices.extensionFillsHandoffs]), automatic
/// posting is on for its network, and it is the user's only account there.
/// The browser posts as whichever account is signed in on the site, so with
/// two accounts on one network NEFORUM cannot tell which one a post would
/// reach, and their hand-offs wait for the user.
Future<bool> automaticPostingApplies(AppServices s, ConnectedAccount account) async {
  if (!s.extensionFillsHandoffs || !s.settings.postsHandoffAutomatically(account.platformId)) return false;
  final accounts = await s.accounts.all();
  return !accounts.any((a) => a.platformId == account.platformId && a.id != account.id);
}

/// What a hand-off whose automatic posting ended without a confirmed post
/// leaves for the user to check before posting it by hand
/// ([PostTarget.handoffNote]), by the last report [r] of the page that posts
/// it, on [host]. The hand-off sheet and scheduled runs keep the same notes,
/// and a target with one is never posted automatically again. Null when
/// there is nothing to check: the post was confirmed, or [r] came from
/// another page.
String? automaticHandoffNote(BrowserFillResult r, String host) {
  if (r.posted == BrowserPostState.confirmed) return null;
  if (r.posted == BrowserPostState.pressed) return 'Post was pressed on $host, but the post was not seen going up. Check the page before you post it again.';
  final message = r.message == null ? '' : ' ${_sentence(r.message!)}';
  return switch (r.automatic) {
    // The countdown ran, and nothing came after it: Post may have been pressed.
    BrowserAutomaticState.countdown => 'The NEFORUM extension started posting on $host but did not report back. Check the page before you post it again.',
    BrowserAutomaticState.stopped => 'Automatic posting was stopped on $host before Post was pressed. If you posted it there yourself, mark it as posted.',
    BrowserAutomaticState.manual => 'Not posted automatically.$message It was left filled in on $host: if you posted it there yourself, mark it as posted.',
    // An extension before 1.1.0 fills in but never posts by itself.
    BrowserAutomaticState.none => 'Filled in on $host, but that NEFORUM extension is older than 1.1.0 and does not post by itself. If you posted it there yourself, mark it as posted.',
    BrowserAutomaticState.otherPage => null,
  };
}

String _sentence(String s) => RegExp(r'[.!?…]$').hasMatch(s) ? s : '$s.';

/// How one automatic hand-off ended.
enum _Outcome {
  /// The extension pressed Post and saw the post go up.
  posted,

  /// The page was filled in, but no post was confirmed: Post may have been
  /// pressed, or the page was left to the user ([_Attempt.note] says which).
  unconfirmed,

  /// Nothing came back from the page, so nothing was filled in there.
  unreported,

  /// The user cancelled the run in Activity before anything was posted.
  cancelled,
}

class _Attempt {
  const _Attempt(this.outcome, [this.note]);
  final _Outcome outcome;

  /// What the user should check before posting by hand
  /// ([PostTarget.handoffNote]); null when nothing was left on the page.
  final String? note;
}

/// What automatic posting needs for one target: the page to open, the plan
/// and the post as that network gets it.
typedef _Page = ({ConnectedAccount account, HandoffPlan plan, Uri url, PlatformDescriptor descriptor, PostVariant variant});

/// Posts the hand-off targets of a scheduled post through the NEFORUM
/// browser extension, without the hand-off sheet, while NEFORUM runs on a
/// computer with automatic posting on (Settings > Browser extension > Post
/// automatically) and a paired browser.
///
/// One target at a time, since the bridge holds one job: NEFORUM opens the
/// page in the browser, the extension fills it in, counts down and presses
/// Post, and once it confirms the post the target is marked handed off.
/// Anything else leaves the target waiting, with the usual "Time to post"
/// notification; when the page was filled in (Post pressed without a sign
/// it went, the countdown stopped, something left to the user) the target
/// keeps a note saying what to check, and is never posted automatically
/// again. Cancel in Activity stops the run: no hand-off is posted after it.
class AutomaticHandoff {
  AutomaticHandoff(
    this._s, {
    this.firstReport = const Duration(minutes: 2),
    this.posting = const Duration(minutes: 4),
    this.pressing = const Duration(seconds: 30),
    Future<bool> Function(Uri url)? openDefault,
  }) : _openDefault = openDefault ?? ((url) => launchUrl(url, mode: LaunchMode.externalApplication));

  final AppServices _s;

  /// How long to wait for the extension's first report on a page, counted
  /// from the last time the page fetched the job or one of its files; and,
  /// once its countdown started, for the post to go out (uploads take a
  /// while). [firstReport] is also how long a page left to the user may
  /// still report a post made there.
  final Duration firstReport;
  final Duration posting;

  /// After a cancel during the countdown: how long a Post press already
  /// under way has to report (the extension watches it for 25 seconds).
  final Duration pressing;

  /// Opens a page in the system's default browser (tests put a stand-in here).
  final Future<bool> Function(Uri url) _openDefault;

  bool get _available => _s.extensionFillsHandoffs && _s.settings.automaticHandoffPosting;

  /// Posts the waiting hand-off targets of [post] automatically where that
  /// applies, and returns the post as it is afterwards. Only for runs nobody
  /// watches ([unattended]): an interactive run has shown the sheet already.
  /// Once [cancellation] fires, nothing more is posted: the hand-off on the
  /// page and those still to come become cancelled.
  Future<Post> complete(Post post, {bool unattended = true, CancellationSignal? cancellation}) async {
    if (!unattended || !_available) return post;
    final publisher = _s.publisher();
    var current = post;
    var posted = 0;
    // Hand-offs this run would have posted automatically, had it not been cancelled.
    final cancelled = <String>[];
    for (final target in post.targets) {
      // A note means Post may have been pressed already: the user finishes it.
      if (target.status != TargetStatus.awaitingHandoff || target.handoffNote != null) continue;
      final account = await _s.accounts.get(target.accountId);
      if (account == null || !await automaticPostingApplies(_s, account)) continue;
      final page = await _page(current, target, account);
      if (page == null) continue;
      if (cancellation?.isCancelled ?? false) {
        cancelled.add(target.accountId);
        continue;
      }
      // A hand-off sheet is open (its job is in the bridge): this one waits.
      if (_s.browserBridge.job != null) break;
      final attempt = await _post(page, cancellation);
      if (attempt.note != null) current = await publisher.noteHandoff(current.id, target.accountId, attempt.note!);
      switch (attempt.outcome) {
        case _Outcome.posted:
          current = await publisher.confirmHandoff(current.id, target.accountId);
          posted++;
        case _Outcome.cancelled:
          cancelled.add(target.accountId);
        case _Outcome.unconfirmed:
        case _Outcome.unreported:
          break;
      }
    }
    if (cancelled.isNotEmpty) current = await publisher.cancelTargets(current.id, cancelled);
    // Nothing left to post by hand: the reminder at the post's time is moot.
    if (posted > 0 && !current.targets.any((t) => t.status == TargetStatus.awaitingHandoff)) {
      await NotificationService.instance.cancel('due:${post.id}');
    }
    return current;
  }

  /// The page and plan for one target; null when there is no page the
  /// extension fills in by itself.
  Future<_Page?> _page(Post post, PostTarget target, ConnectedAccount account) async {
    final adapter = _s.registry.byId(account.platformId);
    if (adapter == null) return null;
    final publisher = _s.publisher();
    final HandoffPlan? plan;
    try {
      plan = await publisher.planHandoff(post, account.id);
    } on Object {
      return null;
    }
    if (plan == null) return null;
    final url = automaticHandoffPage(plan);
    if (url == null) return null;
    final descriptor = adapter.descriptorForAccount(account);
    return (account: account, plan: plan, url: url, descriptor: descriptor, variant: publisher.resolver.resolve(post, target, descriptor, account: account));
  }

  /// Opens the page for one target and waits for the extension.
  Future<_Attempt> _post(_Page page, CancellationSignal? cancellation) async {
    final (:account, :plan, :url, :descriptor, :variant) = page;
    final bridge = _s.browserBridge;

    final done = Completer<_Attempt>();
    Timer? timer;
    void finish(_Attempt attempt) {
      if (!done.isCompleted) done.complete(attempt);
    }

    void wait(Duration d, _Attempt then) {
      timer?.cancel();
      timer = Timer(d, () => finish(then));
    }

    BrowserJob? job;
    var reported = false;
    // The countdown is on: Post may be pressed at any moment.
    var counting = false;
    var cancelled = false;
    // Set once the page was left to the user.
    String? note;

    /// The page is the user's from here: no other page posts the job, and a
    /// post made from this one (its Post now, or Ctrl+Enter) still counts
    /// for a while.
    void leave(BrowserJob left, String why) {
      note = why;
      bridge.endAutomaticPosting(left.id);
      final attempt = _Attempt(_Outcome.unconfirmed, why);
      if (left.quickPost) {
        wait(firstReport, attempt);
      } else {
        finish(attempt);
      }
    }

    final results = bridge.results.listen((r) {
      final reportedOn = job;
      if (reportedOn == null || r.jobId != reportedOn.id) return;
      final host = bareHost(r.host).isEmpty ? bareHost(url.host) : bareHost(r.host);
      // A post counts from any page of the site.
      if (r.posted == BrowserPostState.confirmed) return finish(const _Attempt(_Outcome.posted));
      if (r.posted == BrowserPostState.pressed) return finish(_Attempt(_Outcome.unconfirmed, automaticHandoffNote(r, host)));
      // Another page filled the job in (another tab, a reload): the page that
      // posts it reports for itself, and is still waited for.
      if (r.automatic == BrowserAutomaticState.otherPage) return;
      reported = true;
      if (cancelled) return finish(_Attempt(_Outcome.cancelled, note));
      if (note != null) return;
      final left = automaticHandoffNote(r, host);
      switch (r.automatic) {
        case BrowserAutomaticState.countdown:
          counting = true;
          wait(posting, _Attempt(_Outcome.unconfirmed, left));
        case BrowserAutomaticState.stopped:
        case BrowserAutomaticState.manual:
        case BrowserAutomaticState.none:
          leave(reportedOn, left!);
        case BrowserAutomaticState.otherPage:
          break;
      }
    });
    // The page is still loading the job or its files: give it time to report.
    final served = bridge.served.listen((id) {
      if (id == job?.id && !reported) wait(firstReport, const _Attempt(_Outcome.unreported));
    });
    unawaited(cancellation?.whenCancelled.then((_) {
      if (done.isCompleted) return;
      cancelled = true;
      final id = job?.id;
      if (id != null) bridge.endAutomaticPosting(id);
      // A press already under way may still go out: wait for its report.
      if (counting && note == null) {
        wait(pressing, const _Attempt(_Outcome.cancelled));
      } else {
        finish(_Attempt(_Outcome.cancelled, note));
      }
    }));

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
      if (cancellation?.isCancelled ?? false) return const _Attempt(_Outcome.cancelled);
      final first = _s.settings.browserOpenInFirst ? await bridge.firstChoice() : null;
      job = makeJob(first?.program.id);
      if (job == null) return const _Attempt(_Outcome.unreported);
      wait(firstReport, const _Attempt(_Outcome.unreported));
      var opened = first != null && await BrowserBridge.openInBrowser(first.program.id, url);
      if (!opened) {
        // That browser would not start: the default one, and any browser fills in.
        if (first != null) job = makeJob(null);
        opened = job != null && await _openDefault(url);
      }
      if (!opened) finish(const _Attempt(_Outcome.unreported));
      return await done.future;
    } finally {
      timer?.cancel();
      await results.cancel();
      await served.cancel();
      final id = job?.id;
      if (id != null) bridge.clearJob(id);
    }
  }
}
