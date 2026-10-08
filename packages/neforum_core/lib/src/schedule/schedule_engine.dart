import 'dart:async';

import '../model/post.dart';
import '../publish/publish_service.dart';
import '../storage/repositories.dart';
import '../util/logger.dart';

/// Pure scheduling logic: finds due posts and publishes them. The platform
/// layer decides how often [runDue] is called (an in-process timer on
/// desktop/CLI, WorkManager on Android, a tapped notification on iOS).
class ScheduleEngine {
  ScheduleEngine({
    required this.posts,
    required this.publisher,
    this.interval = const Duration(seconds: 30),
    this.interactive = false,
    Clock? clock,
    Logger? log,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('schedule');

  final PostRepository posts;
  final PublishService publisher;
  final Duration interval;

  /// Whether a run may open UI (share sheets). Background runs pass false.
  final bool interactive;
  final Clock _now;
  final Logger _log;

  Timer? _timer;
  bool _busy = false;
  final _completed = StreamController<Post>.broadcast();

  /// Emits every post the engine finished a run for (any outcome).
  Stream<Post> get completed => _completed.stream;

  bool get running => _timer != null;

  /// Starts the in-process ticker (desktop/CLI).
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => runDue());
    _log.info('Scheduler started (every ${interval.inSeconds}s)');
    unawaited(runDue());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.info('Scheduler stopped');
  }

  /// Publishes everything that is due. Safe to call from a timer, a
  /// background task or a notification tap; concurrent calls coalesce.
  Future<List<Post>> runDue() async {
    if (_busy) return const [];
    _busy = true;
    try {
      final due = await posts.due(_now());
      if (due.isEmpty) return const [];
      _log.info('${due.length} post(s) due');
      final out = <Post>[];
      for (final p in due) {
        try {
          final done = await publisher.publish(p.id, interactive: interactive, retryFailed: false);
          out.add(done);
          _completed.add(done);
        } on Object catch (e) {
          _log.error('Run failed for post ${p.id}', e);
        }
      }
      return out;
    } finally {
      _busy = false;
    }
  }

  /// The next moment anything is scheduled, for OS-level alarms.
  Future<DateTime?> nextDue() async {
    DateTime? next;
    for (final p in await posts.all()) {
      if (p.status != PostStatus.scheduled || p.scheduledAt == null) continue;
      if (next == null || p.scheduledAt!.isBefore(next)) next = p.scheduledAt;
    }
    return next;
  }

  void dispose() {
    stop();
    _completed.close();
  }
}
