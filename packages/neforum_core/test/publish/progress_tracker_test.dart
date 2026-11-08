// What the numbers on a publish run may say: only what the server confirmed,
// integer arithmetic, never backward, 100 only on an outcome, and a time left
// only from a confirmed speed that held still.

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _mib = 1024 * 1024;

void main() {
  var now = DateTime.utc(2026, 11, 6, 12);
  setUp(() => now = DateTime.utc(2026, 11, 6, 12));

  /// A position the server confirmed: a chunk it answered, a resume offset it
  /// sent, or the answer to a whole body.
  ProgressEvent bytes(int position, int total, {String slot = 'a', int attempt = 1}) => ProgressEvent(
      stage: ProgressStage.uploading, label: 'Uploading', at: now, slot: slot, position: position, slotTotal: total, attempt: attempt, confirmed: true);

  /// Bytes the connection took, with no answer for them yet.
  ProgressEvent handed(int position, int total, {String slot = 'a', int attempt = 1}) => ProgressEvent(
      stage: ProgressStage.uploading, label: 'Uploading', at: now, slot: slot, position: position, slotTotal: total, attempt: attempt);
  ProgressEvent wait({int? percent}) => ProgressEvent(stage: ProgressStage.serverProcessing, label: 'Processing', at: now, serverPercent: percent);
  ProgressEvent posting({int? step}) => ProgressEvent(stage: ProgressStage.posting, label: 'Posting', at: now, stepDone: step);

  TargetProgressTracker tracker(ProgressFamily family, {List<ProgressSlot> slots = const [ProgressSlot('a', 1000)], int steps = 1, int done = 0, bool interleaved = false}) =>
      TargetProgressTracker(accountId: 'x', shape: ProgressShape(family: family, slots: slots, steps: steps, stepsDone: done, interleaved: interleaved));

  group('weights', () {
    test('every row sums to 100, and only the opaque family has no row', () {
      for (final f in ProgressFamily.values) {
        final w = kProgressWeights[f];
        if (f == ProgressFamily.opaque) {
          expect(w, isNull);
          continue;
        }
        expect(w!.upload + w.wait + w.posting, 100, reason: f.name);
      }
    });
  });

  group('one target', () {
    test('a dropped upload holds the bar while it re-sends, and moves again past the mark', () {
      final t = tracker(ProgressFamily.direct);
      final seen = <int>[];
      for (final (p, attempt) in [(100, 1), (400, 1), (700, 1), (0, 2), (100, 2), (650, 2), (800, 2), (1000, 2)]) {
        t.apply(bytes(p, 1000, attempt: attempt));
        seen.add(t.permille!);
      }
      expect(seen, [90, 360, 630, 630, 630, 630, 720, 900]);
      t.apply(bytes(100, 1000, attempt: 3));
      expect(t.snapshot().resending, isTrue, reason: 'the words say why the bar stopped');
      t.apply(bytes(1000, 1000, attempt: 3));
      expect(t.snapshot().resending, isFalse);
    });

    test('a body fully handed to the connection but not answered leaves the figure where it was', () {
      // The compiled slow-link run: the connection took a 3 MiB body in 50 ms,
      // the server had 0.5% of it, and the figure read 70% for 25 s.
      final t = tracker(ProgressFamily.waitNoNumber);
      for (final p in [16 * 1024, 1500000, 3146116]) {
        now = now.add(const Duration(milliseconds: 20));
        t.apply(handed(p, 3146116));
        expect(t.permille, 0, reason: 'handed over at $p: the server has confirmed nothing');
      }
      final waiting = t.snapshot(now);
      expect((waiting.position, waiting.confirmedPosition, waiting.confirmed), (3146116, null, false));
      expect(waiting.eta, isNull);
      expect(waiting.bytesPerSecond, isNull);
      now = now.add(const Duration(seconds: 25));
      t.apply(bytes(3146116, 3146116)); // The server answers the request.
      expect(t.permille, 700);
      expect(t.snapshot().confirmedPosition, 3146116);
      expect(t.snapshot().toJson(), containsPair('confirmedPosition', 3146116));
    });

    test('after a confirmed file, the next one handed over moves nothing until answered', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 1000), ProgressSlot('b', 1000)]);
      t.apply(bytes(1000, 1000));
      expect(t.permille, 450);
      t.apply(handed(1000, 1000, slot: 'b'));
      expect(t.permille, 450, reason: 'the percent stays where it was');
      expect(t.snapshot().confirmedPosition, isNull, reason: 'a new file starts with nothing confirmed');
      t.apply(bytes(1000, 1000, slot: 'b'));
      expect(t.permille, 900);
    });

    test('chunks the server answered for move the figure; bytes of the next chunk in flight do not', () {
      final t = tracker(ProgressFamily.wholeFile, slots: const [ProgressSlot('a', 4000)]);
      t.apply(bytes(1000, 4000));
      expect(t.permille, 237);
      t.apply(handed(1900, 4000));
      t.apply(handed(2000, 4000));
      expect(t.permille, 237);
      expect(t.snapshot().confirmedPosition, 1000);
      t.apply(bytes(2000, 4000));
      expect(t.permille, 475);
    });

    test('a resume from a lower server offset holds', () {
      final t = tracker(ProgressFamily.wholeFile);
      t.apply(bytes(900, 1000));
      final before = t.permille;
      t.apply(bytes(500, 1000));
      expect(t.permille, before);
      expect(t.snapshot().resending, isTrue);
      t.apply(bytes(950, 1000));
      expect(t.permille, greaterThan(before!));
    });

    test('a handed-over body sent again after a drop says so, and still moves nothing', () {
      final t = tracker(ProgressFamily.direct);
      t.apply(handed(800, 1000));
      t.apply(handed(100, 1000, attempt: 2));
      expect(t.snapshot().resending, isTrue);
      expect(t.permille, 0);
      t.apply(handed(1000, 1000, attempt: 2));
      expect(t.snapshot().resending, isFalse);
      expect(t.permille, 0);
    });

    test('after a resume from a lower offset the time left starts over, and can come back', () {
      final t = tracker(ProgressFamily.wholeFile, slots: const [ProgressSlot('a', 1000000)]);
      var sent = 0;
      void second() {
        now = now.add(const Duration(seconds: 1));
        sent += 1000;
        t.apply(bytes(sent, 1000000));
      }

      for (var i = 0; i < 25; i++) {
        second();
      }
      expect(t.snapshot(now).eta, isNotNull);
      t.apply(bytes(sent = 5000, 1000000));
      expect(t.snapshot(now).eta, isNull, reason: 'the server says less than the count did');
      expect(t.snapshot(now).resending, isTrue);
      for (var i = 0; i < 60; i++) {
        second();
      }
      expect(t.snapshot(now).resending, isFalse);
      expect(t.snapshot(now).eta, isNotNull, reason: 'past the old mark, and two windows agree again');
    });

    test('the server has the whole file and no post yet: not 100, and neither is every step counted', () {
      final t = tracker(ProgressFamily.direct);
      t.apply(bytes(1000, 1000));
      expect(t.permille, 900);
      t.apply(posting(step: 1));
      expect(t.permille, kPermilleCapUntilOutcome);
      t.finish(TargetOutcome.published, now);
      expect(t.permille, 1000);
    });

    test('a server wait moves nothing until it ends', () {
      final t = tracker(ProgressFamily.pullFromUrl);
      t.apply(bytes(1000, 1000));
      expect(t.permille, 600);
      for (var i = 0; i < 5; i++) {
        t.apply(wait());
        expect(t.permille, 600);
      }
      t.apply(posting());
      expect(t.permille, 900);
    });

    test('only the network\'s own number moves a wait', () {
      final t = tracker(ProgressFamily.waitReported);
      t.apply(bytes(1000, 1000));
      t.apply(wait(percent: 40));
      expect(t.permille, 780);
      expect(t.snapshot().serverPercent, 40);
      t.apply(wait(percent: 10)); // A number that falls does not move the bar.
      expect(t.permille, 780);
      final silent = tracker(ProgressFamily.waitNoNumber);
      silent.apply(bytes(1000, 1000));
      silent.apply(wait(percent: 40));
      expect(silent.permille, 700, reason: 'this family does not take a number into the bar');
    });

    test('a wait that never happened is credited when the adapter moves on', () {
      final t = tracker(ProgressFamily.waitNoNumber);
      t.apply(bytes(1000, 1000));
      expect(t.permille, 700);
      t.apply(posting());
      expect(t.permille, 900);
    });

    test('text only: the steps are all there is', () {
      final t = tracker(ProgressFamily.direct, slots: const [], steps: 4);
      expect(t.shape.effectiveFamily, ProgressFamily.textOnly);
      t.apply(posting(step: 1));
      expect(t.permille, 250);
    });

    test('a resumed thread starts with its live parts credited', () {
      final t = tracker(ProgressFamily.direct, slots: const [], steps: 4, done: 2);
      t.apply(posting());
      expect(t.permille, 500);
    });

    test('a size the plan had wrong, or 0, corrects itself and never throws', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 0)]);
      expect(t.permille, 0);
      t.apply(bytes(500, 1000));
      expect(t.permille, 450);
    });

    test('a file the plan does not know moves no number', () {
      final t = tracker(ProgressFamily.direct);
      t.apply(bytes(1000, 1000, slot: 'cover'));
      expect(t.permille, 0);
      expect(t.snapshot().label, 'Uploading');
    });

    test('a body that carries every file counts for them all', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 100), ProgressSlot('b', 300)]);
      t.apply(bytes(600, 1200, slot: ProgressEvent.wholeBody));
      expect(t.permille, 450);
    });

    test('files share the upload by planned bytes', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 100), ProgressSlot('b', 300)]);
      t.apply(bytes(100, 100));
      expect(t.permille, 225);
    });

    test('integers only: a value doubles would miss comes out exact', () {
      final t = tracker(ProgressFamily.waitNoNumber, slots: const [ProgressSlot('a', 3)]);
      t.apply(bytes(1, 3));
      expect(t.permille, 233);
    });

    test('a plan that goes on past the first post adds up', () {
      final first = ProgressShape.forVariant(PostVariant(text: 'a', media: [fakeImage(id: 'one')]), ProgressFamily.direct);
      final next = ProgressShape.forVariant(PostVariant(text: 'b', media: [fakeImage(id: 'two')]), ProgressFamily.direct);
      final series = first.followedBy(next);
      expect(series.slots.map((s) => s.key), ['one', 'two']);
      expect(series.steps, 2);
      expect(series.interleaved, isTrue);
    });

    test('an opaque target has no figure until its outcome', () {
      final t = tracker(ProgressFamily.opaque);
      t.apply(posting());
      expect(t.permille, isNull);
      t.finish(TargetOutcome.published, now);
      expect(t.permille, 1000);
    });

    test('an outcome is final: a late event changes nothing', () {
      final t = tracker(ProgressFamily.direct);
      t.finish(TargetOutcome.failed, now);
      t.apply(bytes(10, 1000));
      expect(t.permille, 1000);
      expect(t.outcome, TargetOutcome.failed);
    });
  });

  group('RateMeter', () {
    final start = DateTime.utc(2026);

    /// Feeds one position per second at each second's rate; the meter's answer
    /// after each second.
    List<int?> feed(RateMeter m, List<int> ratePerSecond) {
      var position = 0;
      final out = <int?>[];
      for (var i = 0; i < ratePerSecond.length; i++) {
        position += ratePerSecond[i];
        final at = start.add(Duration(seconds: i + 1));
        m.add(at, position);
        out.add(m.bytesPerSecond(at));
      }
      return out;
    }

    test('no figure until two windows agree', () {
      final seen = feed(RateMeter(), List.filled(35, 1000));
      expect(seen.take(20).every((v) => v == null), isTrue, reason: seen.toString());
      expect(seen.last, 1000);
    });

    test('windows that differ by more than 25% never pass: the measured TLS run', () {
      // 18.6%, 32.4% and 15.4% of a file in three 10 s windows (research-14, 6.6).
      final rates = [...List.filled(10, 186), ...List.filled(10, 324), ...List.filled(10, 154), ...List.filled(5, 154)];
      expect(feed(RateMeter(), rates).every((v) => v == null), isTrue);
    });

    test('25% is in, a bit more is out', () {
      final within = feed(RateMeter(), [...List.filled(10, 100), ...List.filled(11, 75)]);
      expect(within.last, isNotNull);
      final beyond = feed(RateMeter(), [...List.filled(10, 100), ...List.filled(11, 70)]);
      expect(beyond.last, isNull);
    });

    test('a new attempt starts over', () {
      final m = RateMeter();
      feed(m, List.filled(25, 1000));
      expect(m.bytesPerSecond(start.add(const Duration(seconds: 25))), 1000);
      m.reset();
      expect(m.bytesPerSecond(start.add(const Duration(seconds: 25))), isNull);
    });

    test('no time left once everything is sent, and none when bytes stop', () {
      final m = RateMeter();
      feed(m, List.filled(25, 1000));
      final at = start.add(const Duration(seconds: 25));
      expect(m.eta(35000, at), const Duration(seconds: 10));
      expect(m.eta(25000, at), isNull);
      expect(m.eta(35000, at.add(const Duration(seconds: 25))), isNull, reason: 'a stalled upload has no honest figure');
    });

    test('through the tracker: a speed and a time left come from confirmed positions only', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 1000000)]);
      final speeds = <int?>[];
      for (var chunk = 1; chunk <= 16; chunk++) {
        t.apply(handed(chunk * 5000, 1000000)); // The connection takes each chunk at once...
        expect(t.snapshot(now).bytesPerSecond, speeds.lastOrNull, reason: 'handed-over bytes change no speed');
        now = now.add(const Duration(seconds: 5));
        t.apply(bytes(chunk * 5000, 1000000)); // ...and the server answers for it 5 s later.
        speeds.add(t.snapshot(now).bytesPerSecond);
      }
      expect(speeds.take(4).every((s) => s == null), isTrue, reason: '$speeds');
      expect(speeds.whereType<int>().toSet(), {1000}, reason: 'the speed the server confirms, never the burst: $speeds');
      expect(t.snapshot(now).eta, const Duration(seconds: 920), reason: 'what the server still needs, at the speed it confirms');
    });

    test('through the tracker: a time left only after the gate, gone on a new attempt', () {
      final t = tracker(ProgressFamily.direct, slots: const [ProgressSlot('a', 100000)]);
      var sent = 0;
      Duration? eta;
      final etas = <Duration?>[];
      for (var i = 0; i < 25; i++) {
        now = now.add(const Duration(seconds: 1));
        sent += 1000;
        t.apply(bytes(sent, 100000));
        eta = t.snapshot(now).eta;
        etas.add(eta);
      }
      expect(etas.take(20).every((e) => e == null), isTrue);
      expect(eta, const Duration(seconds: 75));
      expect(t.snapshot(now).bytesPerSecond, 1000);
      now = now.add(const Duration(seconds: 1));
      t.apply(bytes(1000, 100000, attempt: 2));
      expect(t.snapshot(now).eta, isNull, reason: 'a failed then retried upload resets the time left');
      expect(t.permille, 225, reason: 'and holds the bar');
    });
  });

  group('the post', () {
    PublishRunPlan plan(List<PlannedTarget> targets) => PublishRunPlan(postId: 'p', targets: targets);
    const text = ProgressShape(family: ProgressFamily.textOnly);
    PlannedTarget member(String id, [ProgressShape shape = text, TargetOutcome? outcome]) => PlannedTarget(accountId: id, name: id, shape: shape, outcome: outcome);

    test('three text posts, one posted, one failed, one to go: two thirds', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('a'), member('b'), member('c')]));
      run.outcome('a', TargetOutcome.published);
      run.outcome('b', TargetOutcome.failed);
      final p = run.current;
      expect(p.permille, 666);
      expect((p.posted, p.failed, p.total), (1, 1, 3));
      expect(p.finished, isFalse);
    });

    test('a finished text post beside an unstarted 500 MiB upload is not half done', () {
      final big = ProgressShape(family: ProgressFamily.wholeFile, slots: [const ProgressSlot('v', 500 * _mib)]);
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('a'), member('y', big)]));
      run.outcome('a', TargetOutcome.published);
      expect(run.current.permille, 1);
    });

    test('capped until every target has an outcome, then 100', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('a'), member('b')]));
      run.outcome('a', TargetOutcome.published);
      run.event('b', posting(step: 1));
      expect(run.current.permille, kPermilleCapUntilOutcome);
      run.outcome('b', TargetOutcome.published);
      expect(run.current.permille, 1000);
      expect(run.current.finished, isTrue);
    });

    test('a target not in this run is in no figure, and one live already is credited', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now)
        ..plan(plan([member('live', text, TargetOutcome.published), member('other', text, TargetOutcome.notThisRun), member('todo')]));
      final p = run.current;
      expect(p.total, 2);
      expect(p.permille, 500);
      expect(p.posted, 1);
      expect(p.targets.map((t) => t.accountId), ['live', 'todo']);
    });

    test('never falls, whatever the events do', () {
      final shape = ProgressShape(family: ProgressFamily.direct, slots: [const ProgressSlot('a', 1000)]);
      final seen = <int>[];
      final run = PublishProgressTracker(postId: 'p', clock: () => now, interval: Duration.zero, onChange: (p) => seen.add(p.permille))..plan(plan([member('x', shape)]));
      for (final (position, attempt) in [(500, 1), (0, 2), (10, 2), (400, 2), (900, 2), (1000, 2)]) {
        run.event('x', bytes(position, 1000, attempt: attempt));
      }
      run.outcome('x', TargetOutcome.failed);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.last, 1000);
    });

    test('the post figure holds while a body is only handed over, and moves on the answer', () {
      final photo = ProgressShape(family: ProgressFamily.waitNoNumber, slots: [const ProgressSlot('a', 3 * _mib)]);
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('done'), member('x', photo)]));
      run.outcome('done', TargetOutcome.published);
      final before = run.current.permille;
      expect(before, 250, reason: 'the finished text post, weighted against 3 MiB');
      run.event('x', handed(3 * _mib, 3 * _mib));
      expect(run.current.permille, before, reason: 'the server has confirmed none of it');
      run.event('x', bytes(3 * _mib, 3 * _mib));
      expect(run.current.permille, 250 + 3 * 700 ~/ 4);
    });

    test('at most one update per 200 ms, plus every stage change and outcome', () {
      final shape = ProgressShape(family: ProgressFamily.direct, slots: [const ProgressSlot('a', 10000)]);
      var updates = 0;
      final run = PublishProgressTracker(postId: 'p', clock: () => now, onChange: (_) => updates++)..plan(plan([member('x', shape)]));
      expect(updates, 1);
      run.event('x', bytes(0, 10000));
      expect(updates, 2, reason: 'the stage changed');
      for (var i = 1; i <= 100; i++) {
        now = now.add(const Duration(milliseconds: 10));
        run.event('x', bytes(i, 10000));
      }
      expect(updates, 2 + 5, reason: '1 s of events at 100 a second');
      run.event('x', wait());
      expect(updates, 8, reason: 'a stage change goes out at once');
      run.outcome('x', TargetOutcome.published);
      expect(updates, 9, reason: 'so does an outcome');
    });

    test('a change the interval held back still goes out once the interval is up', () async {
      // The compiled slow-link probe: the connection took a 3 MiB body in under
      // 200 ms, the last piece was held back, and the screens showed 0% and no
      // bytes for the 24 s the server took to answer.
      final shape = ProgressShape(family: ProgressFamily.direct, slots: [const ProgressSlot('a', 1000)]);
      final seen = <int?>[];
      final run = PublishProgressTracker(postId: 'p', interval: const Duration(milliseconds: 50), onChange: (p) => seen.add(p.targets.single.position))
        ..plan(plan([member('x', shape)]));
      run.event('x', bytes(100, 1000));
      run.event('x', bytes(1000, 1000));
      expect(seen.last, 100, reason: 'inside the interval: held back');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(seen.last, 1000, reason: 'published without waiting for another event');
      expect(seen.where((p) => p == 1000), hasLength(1));
    });

    test('a look before the plan reads 0 and does not stick', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now);
      expect(run.current.permille, 0);
      run.plan(plan([member('a'), member('b')]));
      expect(run.current.permille, 0);
      run.outcome('a', TargetOutcome.published);
      expect(run.current.permille, 500);
    });

    test('a run with nothing to do is finished', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('a', text, TargetOutcome.notThisRun)]));
      expect((run.current.permille, run.current.total, run.current.finished), (1000, 0, true));
    });

    test('never a time left for the post', () {
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('a')]));
      final json = run.current.toJson();
      expect(json.keys, isNot(contains('eta')));
      expect(json.keys, isNot(contains('etaSeconds')));
      expect((json['targets']! as List).single, containsPair('permille', 0));
    });

    test('elapsed time for a wait comes from when its stage began', () {
      final shape = ProgressShape(family: ProgressFamily.waitNoNumber, slots: [const ProgressSlot('a', 10)]);
      final run = PublishProgressTracker(postId: 'p', clock: () => now)..plan(plan([member('x', shape)]));
      final began = now;
      run.event('x', wait());
      now = now.add(const Duration(minutes: 1));
      run.event('x', wait());
      expect(run.current.targets.single.stageStartedAt, began);
    });
  });
}
