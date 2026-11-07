import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../model/media.dart';
import '../model/post_variant.dart';
import '../util/logger.dart';

/// What a target is doing. A stage says what is happening, never how far along
/// it is.
enum ProgressStage { renewingSignIn, reading, uploading, serverProcessing, posting, handingOff }

/// How a target ended for this run. Plain data, so a run can report it across
/// an isolate one day.
enum TargetOutcome {
  /// The network answered and has the post.
  published,

  /// The person posted it in the other app.
  handedOff,

  /// A hand-off that waits for the person.
  awaitingUser,
  failed,
  cancelled,
  skipped,

  /// This run does not touch the target: another network's time, a backoff, not
  /// selected. It is no part of the run's figures.
  notThisRun,
}

/// One network's real stages, which decide how a target's percentage is shared
/// out ([kProgressWeights]).
enum ProgressFamily {
  /// Upload, then the answer: nothing to wait for in between.
  direct,

  /// The server processes the upload and reports no number.
  waitNoNumber,

  /// The server processes the upload and reports its own percentage.
  waitReported,

  /// The file goes on a media host, and the network fetches it from there.
  pullFromUrl,

  /// One request carries the whole file, and its answer is the post.
  wholeFile,

  /// Nothing can be measured: words and elapsed time until the outcome.
  opaque,

  /// No bytes in the plan, only posts to make.
  textOnly,
}

/// How much of a target's percentage each stage owns. Presentation, not a time
/// model.
@immutable
class ProgressWeights {
  const ProgressWeights(this.upload, this.wait, this.posting);

  final int upload;
  final int wait;
  final int posting;
}

/// Every row sums to 100, by test. [ProgressFamily.opaque] has no row: it shows
/// no percentage at all.
const Map<ProgressFamily, ProgressWeights> kProgressWeights = {
  ProgressFamily.direct: ProgressWeights(90, 0, 10),
  ProgressFamily.waitNoNumber: ProgressWeights(70, 20, 10),
  ProgressFamily.waitReported: ProgressWeights(70, 20, 10),
  ProgressFamily.pullFromUrl: ProgressWeights(60, 30, 10),
  ProgressFamily.wholeFile: ProgressWeights(95, 0, 5),
  ProgressFamily.textOnly: ProgressWeights(0, 0, 100),
};

/// The highest a figure reads until an outcome, in permille. The byte count says
/// what the connection took, not what the server has, so a count never reads 100.
const int kPermilleCapUntilOutcome = 990;

/// A planned file of one target.
@immutable
class ProgressSlot {
  const ProgressSlot(this.key, this.bytes);

  /// [m]'s slot, keyed by placement when a network takes one file twice (feed
  /// and story).
  factory ProgressSlot.of(MediaAttachment m, {String? placement}) => ProgressSlot(keyOf(m, placement: placement), m.sizeBytes);

  static String keyOf(MediaAttachment m, {String? placement}) => placement == null ? m.id : '$placement:${m.id}';

  final String key;
  final int bytes;
}

/// What a target will do, known before it starts: its family, its files and how
/// many posts it makes.
@immutable
class ProgressShape {
  const ProgressShape({required this.family, this.slots = const [], this.steps = 1, this.stepsDone = 0, this.interleaved = false});

  /// The plan for [v]: one slot per file still to send, one step per post. Parts
  /// of a thread that are live already count as done from the start.
  factory ProgressShape.forVariant(PostVariant v, ProgressFamily family, {int? steps, bool interleaved = false}) {
    final parts = v.threadParts.isEmpty ? 1 : v.threadParts.length;
    final live = v.postedThreadIds.length;
    final slots = <String, ProgressSlot>{};
    for (var part = live; part < parts; part++) {
      for (final m in v.mediaOfPart(part)) {
        slots.putIfAbsent(m.id, () => ProgressSlot.of(m));
      }
    }
    return ProgressShape(family: family, slots: slots.values.toList(), steps: steps ?? parts, stepsDone: live, interleaved: interleaved);
  }

  final ProgressFamily family;
  final List<ProgressSlot> slots;

  /// Posts this target makes.
  final int steps;

  /// Posts that were live before this run.
  final int stepsDone;

  /// Posts go out between uploads (a story's frames, a series), so reaching the
  /// posting stage does not mean the uploads are over.
  final bool interleaved;

  int get plannedBytes => slots.fold(0, (sum, s) => sum + s.bytes);

  /// The family the plan really is: no files means nothing but posts to make.
  ProgressFamily get effectiveFamily => family != ProgressFamily.opaque && slots.isEmpty ? ProgressFamily.textOnly : family;

  /// This plan, then [next]: the further posts of a series. The numbers add up,
  /// and uploads and posts now take turns.
  ProgressShape followedBy(ProgressShape next) {
    final merged = <String, ProgressSlot>{for (final s in slots) s.key: s};
    for (final s in next.slots) {
      merged.putIfAbsent(s.key, () => s);
    }
    return ProgressShape(
      family: effectiveFamily == ProgressFamily.textOnly ? next.family : family,
      slots: merged.values.toList(),
      steps: steps + next.steps,
      stepsDone: stepsDone + next.stepsDone,
      interleaved: true,
    );
  }

  /// This plan with [done] more posts live already.
  ProgressShape withStepsDone(int done) =>
      ProgressShape(family: family, slots: slots, steps: steps, stepsDone: math.min(steps, stepsDone + done), interleaved: interleaved);
}

/// One thing an adapter or the HTTP client reports about a target.
@immutable
class ProgressEvent {
  const ProgressEvent({
    required this.stage,
    required this.label,
    required this.at,
    this.slot,
    this.position,
    this.slotTotal,
    this.confirmed = false,
    this.stepDone,
    this.stepTotal,
    this.serverPercent,
    this.attempt = 1,
    this.waitPolls,
  });

  /// [slot] of a body that carries all the target's files.
  static const String wholeBody = '*';

  final ProgressStage stage;

  /// What is happening, in words fit to show.
  final String label;
  final DateTime at;

  /// Which file or file group of the plan the bytes belong to.
  final String? slot;

  /// Bytes through the slot: where the body starts in the file, plus what the
  /// connection took of it.
  final int? position;

  /// File size for a chunked upload, the request's length for one body.
  final int? slotTotal;

  /// [position] is what the server answered for, not only what was sent.
  final bool confirmed;

  /// Posts live so far, set when one more just went live.
  final int? stepDone;
  final int? stepTotal;

  /// Only ever a number the network itself sent.
  final int? serverPercent;
  final int attempt;

  /// Requests really made so far in this server wait.
  final int? waitPolls;
}

/// Bytes per second, from positions at their real times. It says nothing until
/// two windows in a row agree within 25%: the first seconds of a transfer are the
/// socket's buffers filling, not speed.
class RateMeter {
  RateMeter({this.window = const Duration(seconds: 10)});

  final Duration window;
  DateTime? _windowStart;
  int _windowPosition = 0;
  int? _lastRate;
  int? _agreedRate;
  bool _confirmedOnly = false;
  DateTime? _lastAt;
  int _position = 0;

  /// Records [position] at [at]. Once the server has answered for a position,
  /// only its answers count: they are the truth, the count is not.
  void add(DateTime at, int position, {bool confirmed = false}) {
    if (confirmed && !_confirmedOnly) {
      _confirmedOnly = true;
      _restartWindow(at, position);
      _lastAt = at;
      _position = position;
      return;
    }
    if (_confirmedOnly && !confirmed) return;
    _lastAt = at;
    _position = position;
    final start = _windowStart;
    if (start == null) {
      _restartWindow(at, position);
      return;
    }
    final elapsedMs = at.difference(start).inMilliseconds;
    if (elapsedMs < window.inMilliseconds) return;
    final rate = (position - _windowPosition) * 1000 ~/ elapsedMs;
    final last = _lastRate;
    // Integer form of |a - b| / max(a, b) <= 25%.
    final agree = last != null && rate > 0 && last > 0 && (rate - last).abs() * 100 <= 25 * math.max(rate, last);
    _agreedRate = agree ? rate : null;
    _lastRate = rate;
    _restartWindow(at, position);
  }

  void _restartWindow(DateTime at, int position) {
    _windowStart = at;
    _windowPosition = position;
  }

  /// A new attempt or a new file: nothing known carries over.
  void reset() {
    _windowStart = null;
    _windowPosition = 0;
    _lastRate = null;
    _agreedRate = null;
    _confirmedOnly = false;
    _lastAt = null;
    _position = 0;
  }

  bool _fresh(DateTime now) => _lastAt != null && now.difference(_lastAt!) <= window * 2;

  /// The speed, once measured, while bytes are still moving.
  int? bytesPerSecond(DateTime now) => _fresh(now) ? _agreedRate : null;

  /// Time left to send up to [total]. Null when there is no honest figure, and
  /// always once everything is sent: from there on it is the server's turn.
  Duration? eta(int total, DateTime now) {
    final rate = bytesPerSecond(now);
    if (rate == null || rate <= 0 || _position >= total) return null;
    return Duration(seconds: (total - _position) ~/ rate);
  }
}

/// One target as a run shows it.
@immutable
class TargetProgress {
  const TargetProgress({
    required this.accountId,
    required this.name,
    required this.permille,
    required this.family,
    required this.stage,
    required this.label,
    required this.stageStartedAt,
    this.position,
    this.slotTotal,
    this.confirmed = false,
    this.stepsDone = 0,
    this.steps = 0,
    this.serverPercent,
    this.waitPolls = 0,
    this.attempt = 1,
    this.resending = false,
    this.eta,
    this.bytesPerSecond,
    this.outcome,
  });

  final String accountId;

  /// The network's name.
  final String name;

  /// Null when nothing about the target can be measured and it has no outcome.
  final int? permille;
  final ProgressFamily family;

  /// Null until the target starts.
  final ProgressStage? stage;
  final String? label;

  /// When [stage] began, so a wait can show its real elapsed time.
  final DateTime? stageStartedAt;
  final int? position;
  final int? slotTotal;
  final bool confirmed;
  final int stepsDone;
  final int steps;
  final int? serverPercent;
  final int waitPolls;
  final int attempt;

  /// A dropped connection is sending again what was already counted. The bar
  /// holds until it passes that mark.
  final bool resending;
  final Duration? eta;
  final int? bytesPerSecond;
  final TargetOutcome? outcome;

  bool get finished => outcome != null;

  /// Plain data, ready to go over a channel. Fields only: `toString` is minified
  /// in profile builds.
  Map<String, Object?> toJson() => {
        'accountId': accountId,
        'name': name,
        'permille': permille,
        'family': family.name,
        'stage': stage?.name,
        'label': label,
        'stageStartedAt': stageStartedAt?.toUtc().toIso8601String(),
        'position': position,
        'slotTotal': slotTotal,
        'confirmed': confirmed,
        'stepsDone': stepsDone,
        'steps': steps,
        'serverPercent': serverPercent,
        'waitPolls': waitPolls,
        'attempt': attempt,
        'resending': resending,
        'etaSeconds': eta?.inSeconds,
        'bytesPerSecond': bytesPerSecond,
        'outcome': outcome?.name,
      };
}

/// A whole run as it stands. It holds no time left on purpose: what remains
/// includes waits nobody can measure.
@immutable
class PostProgress {
  const PostProgress({
    required this.postId,
    required this.permille,
    required this.posted,
    required this.failed,
    required this.total,
    required this.targets,
    required this.at,
  });

  final String postId;

  /// Weighted by planned bytes, [kPermilleCapUntilOutcome] at most until every
  /// target of the run has an outcome.
  final int permille;

  /// Targets the network has, or the person posted.
  final int posted;
  final int failed;
  final int total;
  final List<TargetProgress> targets;
  final DateTime at;

  bool get finished => targets.every((t) => t.finished);

  /// The target being worked on, if any.
  TargetProgress? get current {
    for (final t in targets) {
      if (!t.finished && t.stage != null) return t;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'postId': postId,
        'permille': permille,
        'posted': posted,
        'failed': failed,
        'total': total,
        'targets': [for (final t in targets) t.toJson()],
        'at': at.toUtc().toIso8601String(),
      };
}

class _SlotState {
  _SlotState(this.planned, this.total);

  final int planned;
  int total;
  int high = 0;
  bool credited = false;

  int get ppm {
    if (credited) return 1000000;
    return total <= 0 ? 0 : math.min(1000000, high * 1000000 ~/ total);
  }

  bool get filled => credited || (total > 0 && high >= total);
}

/// Works out one target's figure, in integers. It never falls, and it reads 100
/// only on an outcome: the network answered, or this run is finished with it.
class TargetProgressTracker {
  TargetProgressTracker({required this.accountId, required this.shape, this.name = '', RateMeter? meter}) : _meter = meter ?? RateMeter() {
    _steps = shape.stepsDone;
    for (final s in shape.slots) {
      _slots[s.key] = _SlotState(math.max(1, s.bytes), s.bytes);
    }
  }

  final String accountId;
  final String name;
  final ProgressShape shape;
  final RateMeter _meter;
  final Map<String, _SlotState> _slots = {};

  int _wholeHigh = 0;
  int _wholeTotal = 0;
  int _steps = 0;
  int _waitsDone = 0;
  int _waitPercent = 0;
  int _waitPolls = 0;
  int _shown = 0;

  ProgressStage? _stage;
  String? _label;
  DateTime? _stageStartedAt;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _slot;
  int? _position;
  int? _slotTotal;
  bool _confirmed = false;
  int? _serverPercent;
  int _attempt = 1;
  bool _resending = false;
  TargetOutcome? _outcome;

  TargetOutcome? get outcome => _outcome;
  ProgressStage? get stage => _stage;
  int get plannedBytes => shape.plannedBytes;

  /// How much this target counts in the post's figure: a finished text post must
  /// not read as half the work beside an unstarted 500 MiB upload.
  int get weight => math.max(plannedBytes, 1024 * 1024);

  /// Applies [e]; true when the stage changed.
  bool apply(ProgressEvent e) {
    if (_outcome != null) return false;
    _lastAt = e.at;
    final changed = e.stage != _stage;
    if (changed) {
      if (_stage == ProgressStage.serverProcessing) {
        _waitsDone++;
        _waitPercent = 0;
        _waitPolls = 0;
        _serverPercent = null;
      }
      _stage = e.stage;
      _stageStartedAt = e.at;
    }
    _label = e.label;
    switch (e.stage) {
      case ProgressStage.uploading:
        if (e.position != null) _applyBytes(e);
      case ProgressStage.serverProcessing:
        if (e.serverPercent case final p?) {
          final clamped = p.clamp(0, 100);
          _serverPercent = clamped;
          _waitPercent = math.max(_waitPercent, clamped);
        }
        if (e.waitPolls case final n?) _waitPolls = n;
      case ProgressStage.posting:
        _reachedPosting();
        if (e.position != null) _applyBytes(e);
        if (e.stepDone != null) _steps = math.min(shape.steps, _steps + 1);
      case ProgressStage.renewingSignIn:
      case ProgressStage.reading:
      case ProgressStage.handingOff:
        break;
    }
    _hold();
    return changed;
  }

  void _applyBytes(ProgressEvent e) {
    final position = e.position!;
    final total = e.slotTotal ?? position;
    final key = e.slot;
    if (key != _slot || e.attempt != _attempt) _meter.reset();
    _slot = key;
    _attempt = e.attempt;
    _position = position;
    _slotTotal = total;
    _confirmed = e.confirmed;
    if (key == ProgressEvent.wholeBody) {
      _resending = position < _wholeHigh;
      if (total > 0) _wholeTotal = total;
      _wholeHigh = math.max(_wholeHigh, math.min(position, _wholeTotal));
    } else {
      final slot = key == null ? null : _slots[key];
      // A file the plan does not know (a cover, a poster) moves no number.
      if (slot == null) return;
      _resending = position < slot.high;
      if (total > 0) slot.total = total;
      slot.high = math.max(math.min(slot.high, slot.total), math.min(position, slot.total));
    }
    if (_resending && !e.confirmed) {
      _meter.reset();
    } else {
      _meter.add(e.at, position, confirmed: e.confirmed);
    }
  }

  /// The adapter moved on, so a stage that turned out not to happen is credited
  /// at once. Only uploads with no counted bytes are affected: the ones the
  /// server already had from an earlier attempt.
  void _reachedPosting() {
    _resending = false;
    if (!shape.interleaved) {
      for (final s in _slots.values) {
        if (!s.filled) s.credited = true;
      }
      _waitsDone = _waits;
    } else {
      _waitsDone = math.max(_waitsDone, _slots.values.where((s) => s.filled).length);
    }
  }

  int get _waits => math.max(1, shape.slots.length);

  int get _uploadPpm {
    var planned = 0;
    var sum = 0;
    for (final s in _slots.values) {
      planned += s.planned;
      sum += s.planned * s.ppm;
    }
    final slots = planned == 0 ? 0 : sum ~/ planned;
    final whole = _wholeTotal <= 0 ? 0 : math.min(1000000, _wholeHigh * 1000000 ~/ _wholeTotal);
    return math.max(slots, whole);
  }

  int get _waitPpm {
    final reported = shape.effectiveFamily == ProgressFamily.waitReported ? _waitPercent * 10000 : 0;
    return math.min(1000000, (_waitsDone * 1000000 + reported) ~/ _waits);
  }

  int get _raw {
    final w = kProgressWeights[shape.effectiveFamily];
    if (w == null) return 0;
    final steps = shape.steps <= 0 ? 0 : math.min(1000000, _steps * 1000000 ~/ shape.steps);
    return (w.upload * 10 * _uploadPpm + w.wait * 10 * _waitPpm + w.posting * 10 * steps) ~/ 1000000;
  }

  void _hold() => _shown = math.max(_shown, math.min(_raw, kPermilleCapUntilOutcome));

  /// This target is finished for the run.
  void finish(TargetOutcome outcome, DateTime at) {
    _outcome ??= outcome;
    _lastAt = at;
    _resending = false;
    if (_outcome != TargetOutcome.notThisRun) _shown = 1000;
  }

  /// The figure, or null when there is none to show. An [ProgressFamily.opaque]
  /// target counts as 0 in the post's figure until its outcome.
  int? get permille => shape.effectiveFamily == ProgressFamily.opaque && _outcome == null ? null : _shown;

  TargetProgress snapshot([DateTime? now]) {
    final at = now ?? _lastAt;
    final total = _slotTotal;
    final moving = _stage == ProgressStage.uploading && !_resending;
    return TargetProgress(
      accountId: accountId,
      name: name,
      permille: permille,
      family: shape.effectiveFamily,
      stage: _stage,
      label: _label,
      stageStartedAt: _stageStartedAt,
      position: _position,
      slotTotal: total,
      confirmed: _confirmed,
      stepsDone: _steps,
      steps: shape.steps,
      serverPercent: _serverPercent,
      waitPolls: _waitPolls,
      attempt: _attempt,
      resending: _resending,
      eta: moving && total != null ? _meter.eta(total, at) : null,
      bytesPerSecond: moving ? _meter.bytesPerSecond(at) : null,
      outcome: _outcome,
    );
  }
}

/// One target of a run's plan.
@immutable
class PlannedTarget {
  const PlannedTarget({required this.accountId, required this.name, required this.shape, this.outcome});

  final String accountId;
  final String name;
  final ProgressShape shape;

  /// Set when the run will not post it: live already, or [TargetOutcome.notThisRun].
  final TargetOutcome? outcome;
}

/// A run's targets, fixed when it starts.
@immutable
class PublishRunPlan {
  const PublishRunPlan({required this.postId, required this.targets});

  final String postId;
  final List<PlannedTarget> targets;
}

/// Turns a run's events into [PostProgress]. Feed it from
/// `PublishService.publish`'s `onPlan`, `onEvent` and `onOutcome`. At 100 Mbit/s
/// the 16 KiB pieces make hundreds of events a second, so [onChange] fires at most
/// every [interval], plus on every stage change and outcome.
class PublishProgressTracker {
  PublishProgressTracker({required this.postId, this.onChange, Clock? clock, this.interval = const Duration(milliseconds: 200)})
      : _now = clock ?? systemClock;

  final String postId;
  final void Function(PostProgress progress)? onChange;
  final Duration interval;
  final Clock _now;
  final Map<String, TargetProgressTracker> _targets = {};
  DateTime? _lastPublished;
  int _shown = 0;

  /// Sets the run's members. Targets that are not part of the run are left out of
  /// every figure.
  void plan(PublishRunPlan plan) {
    final now = _now();
    _targets.clear();
    for (final t in plan.targets) {
      if (t.outcome == TargetOutcome.notThisRun) continue;
      final tracker = TargetProgressTracker(accountId: t.accountId, shape: t.shape, name: t.name);
      if (t.outcome != null) tracker.finish(t.outcome!, now);
      _targets[t.accountId] = tracker;
    }
    _publish(force: true);
  }

  void event(String accountId, ProgressEvent e) {
    final tracker = _targets[accountId];
    if (tracker == null) return;
    _publish(force: tracker.apply(e));
  }

  void outcome(String accountId, TargetOutcome o) {
    final tracker = _targets[accountId];
    if (tracker == null) return;
    if (o == TargetOutcome.notThisRun && tracker.outcome == null) {
      _targets.remove(accountId);
    } else {
      tracker.finish(o, _now());
    }
    _publish(force: true);
  }

  /// The run as it stands now.
  PostProgress get current {
    final now = _now();
    var weights = 0;
    var sum = 0;
    var posted = 0;
    var failed = 0;
    var open = false;
    for (final t in _targets.values) {
      weights += t.weight;
      sum += t.weight * (t.permille ?? 0);
      if (t.outcome == null) open = true;
      if (t.outcome == TargetOutcome.published || t.outcome == TargetOutcome.handedOff) posted++;
      if (t.outcome == TargetOutcome.failed) failed++;
    }
    final raw = weights == 0 ? 0 : sum ~/ weights;
    _shown = open ? math.max(_shown, math.min(raw, kPermilleCapUntilOutcome)) : 1000;
    return PostProgress(
      postId: postId,
      permille: _shown,
      posted: posted,
      failed: failed,
      total: _targets.length,
      targets: [for (final t in _targets.values) t.snapshot(now)],
      at: now,
    );
  }

  void _publish({required bool force}) {
    final listener = onChange;
    if (listener == null) return;
    final now = _now();
    final last = _lastPublished;
    if (!force && last != null && now.difference(last) < interval) return;
    _lastPublished = now;
    listener(current);
  }
}
