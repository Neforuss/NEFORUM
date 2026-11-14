// Swift and the Xcode project compile only on a Mac, in CI. These read the files, so a
// hand edit that breaks the project, or a word a stale Live Activity must never say,
// fails here first.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_core/neforum_core.dart' show Post, PostStatus, MediaAttachment;
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_app/state/scheduler.dart';

import '../integration_test/live_activity_probe_runs.dart' as probe;

String _read(String path) => File(path).readAsStringSync();

void main() {
  final project = _read('ios/Runner.xcodeproj/project.pbxproj');
  final keeper = _read('ios/Runner/PublishRunKeeper.swift');
  final attributes = _read('ios/NeforumLiveActivity/PublishActivityAttributes.swift');
  final widget = _read('ios/NeforumLiveActivity/NeforumLiveActivity.swift');
  final delegate = _read('ios/Runner/AppDelegate.swift');
  final plist = _read('ios/Runner/Info.plist');
  final extensionPlist = _read('ios/NeforumLiveActivity/Info.plist');
  final workflow = _read('../../.github/workflows/build.yml');

  /// The block of object [id] in the project.
  String object(String id) {
    final start = RegExp('^\\t\\t$id /\\* [^\\n]*? \\*/ = \\{', multiLine: true).firstMatch(project);
    expect(start, isNotNull, reason: 'object $id');
    final end = project.indexOf(RegExp(r'^\t\t};', multiLine: true), start!.end);
    return project.substring(start.start, end);
  }

  /// [PublishRunKeeper]'s native target.
  String targetId(String name) {
    final m = RegExp('([0-9A-F]{24}) /\\* $name \\*/ = \\{\\s*isa = PBXNativeTarget;').firstMatch(project);
    expect(m, isNotNull, reason: 'target $name');
    return m!.group(1)!;
  }

  group('the Xcode project', () {
    test('every object it mentions exists, and no two have one id', () {
      final defined = RegExp(r'^\t\t([0-9A-F]{24}) (?:/\*.*?\*/ )?= \{', multiLine: true).allMatches(project).map((m) => m.group(1)!).toList();
      expect(defined.toSet(), hasLength(defined.length), reason: 'duplicate ids');
      final used = RegExp(r'\b([0-9A-F]{24})\b').allMatches(project).map((m) => m.group(1)!).toSet();
      expect(used.difference(defined.toSet()), isEmpty);
    });

    test('its braces and parentheses balance', () {
      final body = project.replaceAll(RegExp(r'/\*.*?\*/'), '').replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '');
      expect('{'.allMatches(body).length, '}'.allMatches(body).length);
      expect('('.allMatches(body).length, ')'.allMatches(body).length);
    });

    test('the extension is a target of the project, and Runner depends on it', () {
      final id = targetId('NeforumLiveActivity');
      expect(object(id), contains('productType = "com.apple.product-type.app-extension"'));
      expect(object('97C146E61CF9000F007C117D'), contains('$id /* NeforumLiveActivity */'));
      final runner = object('97C146ED1CF9000F007C117D');
      final dependency = RegExp(r'dependencies = \(\s*([0-9A-F]{24})').firstMatch(runner)!.group(1)!;
      expect(object(dependency), contains('target = $id'));
    });

    test('Embed Foundation Extensions comes before Flutter\'s Run Script, or the build has a cycle', () {
      final runner = object('97C146ED1CF9000F007C117D');
      final embed = runner.indexOf('/* Embed Foundation Extensions */');
      final script = runner.indexOf('/* Run Script */');
      expect(embed, greaterThan(0));
      expect(embed, lessThan(script));
    });

    test('the appex is copied into PlugIns', () {
      final phase = RegExp(r'([0-9A-F]{24}) /\* Embed Foundation Extensions \*/ = \{').firstMatch(project)!.group(1)!;
      final block = object(phase);
      expect(block, contains('dstSubfolderSpec = 13'), reason: '13 is PlugIns');
      expect(block, contains('NeforumLiveActivity.appex in Embed Foundation Extensions'));
    });

    test('the attributes are compiled into both targets, the rest into one', () {
      final runner = object('97C146EA1CF9000F007C117D');
      expect(runner, contains('PublishRunKeeper.swift in Sources'));
      expect(runner, contains('PublishActivityAttributes.swift in Sources'));
      final extensionSources = RegExp(r'buildPhases = \(\s*([0-9A-F]{24}) /\* Sources').firstMatch(object(targetId('NeforumLiveActivity')))!.group(1)!;
      final block = object(extensionSources);
      expect(block, contains('PublishActivityAttributes.swift in Sources'));
      expect(block, contains('NeforumLiveActivity.swift in Sources'));
      expect(block, isNot(contains('PublishRunKeeper')));
    });

    test('Runner stays on iOS 15, the extension is 16.2, in all three configurations', () {
      expect('IPHONEOS_DEPLOYMENT_TARGET = 15.0;'.allMatches(project), hasLength(3));
      expect('IPHONEOS_DEPLOYMENT_TARGET = 16.2;'.allMatches(project), hasLength(3));
    });

    test('ActivityKit is linked weakly, or Runner cannot start on iOS 15', () {
      expect('"-weak_framework",'.allMatches(project), hasLength(3));
      expect(RegExp(r'"-weak_framework",\s*ActivityKit,').allMatches(project), hasLength(3));
    });

    test('the extension\'s bundle id starts with the app\'s: SideStore refuses anything else', () {
      expect('PRODUCT_BUNDLE_IDENTIFIER = org.neforum.neforumApp.NeforumLiveActivity;'.allMatches(project), hasLength(3));
    });

    test('no App Group anywhere: re-signing renames them and the activity goes blank', () {
      for (final file in [project, keeper, attributes, widget, plist, extensionPlist]) {
        expect(file, isNot(contains('application-groups')));
        expect(file.toLowerCase(), isNot(contains('appgroup')));
        expect(file, isNot(contains('group.org.neforum')));
      }
      expect(Directory('ios').listSync(recursive: true).where((f) => f.path.endsWith('.entitlements')), isEmpty);
    });
  });

  group('the property lists', () {
    test('the host says it has Live Activities, and asks for no push', () {
      expect(plist, contains('<key>NSSupportsLiveActivities</key>'));
      expect(plist, isNot(contains('NSSupportsLiveActivitiesFrequentUpdates')));
      expect(plist, isNot(contains('remote-notification')));
    });

    test('a continued task is permitted by a wildcard under the bundle id', () {
      expect(plist, contains('<string>org.neforum.neforumApp.*</string>'));
      expect(plist, contains('<string>org.neforum.publish_due</string>'));
    });

    test('the extension is a WidgetKit extension', () {
      expect(extensionPlist, contains('<string>com.apple.widgetkit-extension</string>'));
      expect(extensionPlist, contains(r'$(PRODUCT_BUNDLE_PACKAGE_TYPE)'));
    });
  });

  group('what the keeper does', () {
    test('the constants of the design', () {
      expect(keeper, contains('let kOwnActivityBesideContinuedTask = true'));
      expect(keeper, contains('kLiveActivityMinInterval: TimeInterval = 30'));
      expect(keeper, contains('kLiveActivityStaleSeconds: TimeInterval = 45'));
      expect(keeper, contains('kContinuedTaskWatchdogSeconds: TimeInterval = 2'));
      expect(keeper, contains('kSystemProgressUnits: Int64 = 1_000_000'));
    });

    test('every activity update sets a new stale date', () {
      expect(RegExp(r'ActivityContent\(state: state, staleDate: now\.addingTimeInterval\(kLiveActivityStaleSeconds\)\)').hasMatch(keeper), isTrue);
    });

    test('checks that the extension is there before asking for an activity', () {
      final possible = keeper.indexOf('builtInPlugInsURL');
      expect(possible, greaterThan(0));
      expect(keeper, contains('NeforumLiveActivity.appex'));
      expect(keeper, contains('guard !run.activityFailed, activityIsPossible()'));
    });

    test('the continued task\'s id comes from the real bundle id, once per run, with .fail', () {
      expect(keeper, contains('Bundle.main.bundleIdentifier'));
      expect(keeper, contains('UUID().uuidString'));
      expect(keeper, contains('request.strategy = .fail'));
      expect(keeper, isNot(contains('"org.neforum.neforumApp')));
    });

    test('a handler that fires after the watchdog completes itself at once', () {
      expect(keeper, contains('self.pendingContinuedIdentifier == identifier else'));
      expect(keeper, contains('task.setTaskCompleted(success: false)'));
    });

    test('compiles on an SDK older than iOS 26', () {
      final uses = RegExp(r'BGContinuedProcessingTask').allMatches(keeper).map((m) => m.start).toList();
      expect(uses, isNotEmpty);
      for (final at in uses) {
        final before = keeper.substring(0, at);
        expect('#if compiler(>=6.2)'.allMatches(before).length, greaterThan('#endif'.allMatches(before).length), reason: 'outside the guard at offset $at');
      }
    });

    test('asks for no push: self-signed builds cannot have it', () {
      expect(keeper, contains('pushType: nil'));
    });

    test('registers in every engine, and the background action takes its assertion first', () {
      expect('PublishRunPlugin.register(in: registry)'.allMatches(delegate), hasLength(2));
      expect(delegate, contains('PublishRunPlugin.register(in: engineBridge.pluginRegistry)'));
      final override = delegate.indexOf('didReceive response: UNNotificationResponse');
      final assertion = delegate.indexOf('beginNotificationAction()', override);
      final plugin = delegate.indexOf('super.userNotificationCenter', override);
      expect(override, greaterThan(0));
      expect(assertion, greaterThan(override));
      expect(assertion, lessThan(plugin), reason: 'before the plugin\'s early completion handler');
      expect(delegate, contains('static let publishAction = "$kPublishAction"'));
      expect(delegate, contains('static let dueCategory = "$kDueCategory"'));
    });
  });

  group('what native code says', () {
    test('a stale activity reads its paused words and no others', () {
      expect(attributes, contains('isStale ? pausedLabel : label'));
      expect(attributes, contains('isStale ? pausedShortLabel : shortLabel'));
      expect(attributes, contains('isStale ? nil : stageLabel'));
      expect(attributes, contains('isStale ? nil : permille'));
    });

    test('the widget never reads a live word straight from the state', () {
      for (final field in ['state.label', 'state.shortLabel', 'state.stageLabel', 'state.permille']) {
        expect(widget, isNot(contains(field)), reason: field);
      }
      expect(widget, contains('context.isStale'));
    });

    test('native code has no words of its own: all of them come from the reducer', () {
      for (final source in [keeper, attributes, widget]) {
        final code = source.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
        for (final m in RegExp(r'"([^"\n]*)"').allMatches(code)) {
          final s = m.group(1)!;
          expect(RegExp(r'\b(Posting|Posted|Paused|Stopped|Waiting)\b').hasMatch(s), isFalse, reason: s);
        }
      }
    });

    test('the shared state holds no field for the post\'s text', () {
      expect(attributes.toLowerCase(), isNot(contains('var text')));
      expect(attributes.toLowerCase(), isNot(contains('var body')));
    });

    test('every snapshot key the keeper reads is one Dart sends', () {
      final sent = const PublishSurfaceState(postId: 'p', phase: PublishSurfacePhase.posting, headline: 'h').toSnapshot().keys.toSet();
      final read = RegExp(r'snapshot\["(\w+)"\]').allMatches(keeper).map((m) => m.group(1)!).toSet();
      expect(read, containsAll(['activityShortLabel', 'pausedShortLabel', 'activityFailedLabel', 'activityPaused', 'postPermille']));
      expect(read.difference(sent), isEmpty);
    });

    test('fields added to the state are optional, so an activity from an older build still decodes', () {
      expect(attributes, contains('var failedLabel: String?'));
      expect(attributes, contains('var paused: Bool?'));
      expect(keeper, contains('failedLabel: snapshot["activityFailedLabel"] as? String'));
      expect(keeper, contains('paused: snapshot["activityPaused"] as? Bool'));
    });

    test('a new count or a failure reaches the activity at once', () {
      final key = RegExp(r'let key = \[([^\]]*)\]').firstMatch(keeper)!.group(1)!;
      expect(key, contains('state.shortLabel'));
      expect(key, contains('state.failedLabel'));
    });
  });

  group('the island', () {
    /// The body of the trailing closure [name] in the Dynamic Island builder.
    String closure(String name) {
      final start = widget.indexOf('} $name: {');
      expect(start, greaterThan(0), reason: name);
      final end = widget.indexOf(RegExp(r'\n      \}'), start + 1);
      return widget.substring(start, end);
    }

    test('the compact pill: a ring around the mark on one side, the count on the other', () {
      expect(closure('compactLeading'), contains('PublishRing(state: state, isStale: stale)'));
      expect(closure('compactTrailing'), contains('PublishCount(state: state, isStale: stale)'));
      expect(closure('minimal'), contains('PublishRing(state: state, isStale: stale)'));
    });

    test('the count is always there, and the badge sits beside it, never instead of it', () {
      final count = widget.substring(widget.indexOf('struct PublishCount'), widget.indexOf('struct PublishFailureBadge'));
      final text = count.indexOf('Text(state.shortLine(isStale: isStale))');
      final badge = count.indexOf('if let failure = state.failure()');
      expect(text, greaterThan(0));
      expect(badge, greaterThan(text));
      expect(count.substring(0, text), isNot(contains('if ')), reason: 'nothing hides the count');
      expect(count, contains('HStack'));
      expect(widget, contains('"exclamationmark.circle.fill"'));
      expect(widget, contains('Color.red'));
    });

    test('the ring follows the bar, so a stale ring has no arc; the pause shape follows stale or held back', () {
      expect(attributes, contains('guard let value = bar(isStale: isStale) else { return nil }'));
      expect(attributes, contains('isStale || paused == true'));
      final ring = widget.substring(widget.indexOf('struct PublishRing'), widget.indexOf('struct PublishCount'));
      expect(ring, contains('state.ring(isStale: isStale)'));
      expect(ring, contains('.trim(from: 0'));
      expect(ring, contains('state.showsPause(isStale: isStale)'));
      expect(widget, isNot(contains('PublishMark(isStale:')), reason: 'held back shows the pause shape too');
    });

    test('the minimal circle has words for VoiceOver, from the reducer', () {
      expect(closure('minimal'), contains('.accessibilityLabel(Text(state.line(isStale: stale)))'));
      expect(widget, contains('.accessibilityLabel(Text(failure))'));
    });

    test('the expanded island carries the count and the failure too', () {
      final expanded = widget.substring(widget.indexOf('return DynamicIsland {'), widget.indexOf('} compactLeading: {'));
      expect(expanded, contains('DynamicIslandExpandedRegion(.trailing)'));
      expect(expanded, contains('PublishCount(state: state, isStale: stale)'));
      final detail = widget.substring(widget.indexOf('struct PublishDetailView'), widget.indexOf('struct PublishLockScreenView'));
      expect(detail, contains('state.failure()'));
    });
  });

  group('CI', () {
    test('the iOS job proves the appex is in the IPA and its plist is sound', () {
      expect(workflow, contains('Payload/Runner.app/PlugIns/NeforumLiveActivity.appex'));
      expect(workflow, contains('plutil -lint'));
      expect(workflow, contains('LC_LOAD_WEAK_DYLIB'));
    });

    test('a simulator job with an island saves its screenshots', () {
      expect(workflow, contains('ios-live-activity:'));
      expect(workflow, contains('tool/ci_live_activity_simulator.sh'));
      expect(_read('tool/ci_live_activity_simulator.sh'), contains('simctl io'));
      expect(File('integration_test/live_activity_probe.dart').existsSync(), isTrue);
      expect(workflow, contains('apps/neforum_app/build/live-activity/*.png'));
    });

    group('the island run', () {
      final script = _read('tool/ci_live_activity_simulator.sh');
      String variable(String name) => RegExp('^$name="([^"]*)"\$', multiLine: true).firstMatch(script)!.group(1)!;

      test('reads the words the probe\'s run really has', () {
        final first = probe.probeFirstRun(DateTime.utc(2026));
        expect(variable('COUNT'), first.activityShortLabel);
        expect(variable('LABEL'), first.activityLabel);
        expect(variable('FAILED'), first.activityFailedLabel);
        expect(first.pausedShortLabel, first.activityShortLabel, reason: 'the stale pill is read for the same count');
        final second = probe.probeSecondRun(DateTime.utc(2026));
        expect(second.activityFailedLabel, isNull);
        expect(second.postId, isNot(first.postId), reason: 'two activities, for the minimal circles');
      });

      test('saves compact, expanded, stale and minimal pictures', () {
        for (final name in ['island-compact.png', 'island-expanded', 'island-stale.png', 'island-minimal.png']) {
          expect(script, contains(name));
        }
      });

      test('fails unless the compact pill shows the count with the badge, live and stale', () {
        expect(script, contains(r'shows_count "$OUT/island-compact.txt" || {'));
        expect(script, contains('--require right.red --forbid left.orange'));
        expect(script, contains('--require left.orange --require right.red --forbid left.blue'));
        expect(script, contains(r'shows_count "$OUT/island-stale.txt"'));
      });

      test('reads the count as Vision gives it, and never out of another number', () {
        // The script's own pattern, put together as bash does.
        expect(script, contains(r'COUNT_READ="(^|[^0-9])${COUNT%/*} ?${COUNT_SLASH} ?${COUNT#*/}([^0-9]|\$)"'));
        expect(script, contains(r'grep -qE "$COUNT_READ" "$1"'));
        final count = variable('COUNT').split('/');
        final read = RegExp('(^|[^0-9])${count[0]} ?${variable('COUNT_SLASH')} ?${count[1]}([^0-9]|\$)', multiLine: true);
        // CI run 43566168953: the pill showed "2/5" and Vision read "2|5".
        expect(read.hasMatch('6:45\n2|5\nSettings'), isTrue);
        for (final shown in ['2/5', '2 / 5', '2l5', '2I5', '2 | 5', '2/5 !']) {
          expect(read.hasMatch(shown), isTrue, reason: shown);
        }
        for (final absent in ['6:45\nSettings', '25', '2 5', '12/5', '2/50', '3/5', '2/4', '2:5', '…', '']) {
          expect(read.hasMatch(absent), isFalse, reason: absent);
        }
      });

      test('builds its tools before the probe starts, so the stale date is not spent on them', () {
        final ready = script.indexOf('PROBE_READY begin=');
        expect(script.indexOf('swiftc -o'), allOf(greaterThan(0), lessThan(ready)));
        expect(script.indexOf('dart compile exe tool/island_pixels.dart'), allOf(greaterThan(0), lessThan(ready)));
        expect(script.indexOf('brew install cameroncooke/axe/axe'), allOf(greaterThan(0), lessThan(ready)));
      });

      test('the expanded and minimal pictures warn instead of failing', () {
        expect(script, contains('::warning::No expanded island picture'));
        expect(script, contains('::warning::The probe never started its second run'));
      });
    });
  });

  group('the reminder split', () {
    Post post(List<MediaAttachment> media) => Post(id: 'p', text: 'hi', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026), status: PostStatus.scheduled, media: media);

    test('text can go in the seconds iOS gives; files open the app', () {
      expect(reminderOpensApp(post(const [])), isFalse);
      expect(reminderOpensApp(post(const [MediaAttachment(id: 'a', path: 'a.png', mimeType: 'image/png', sizeBytes: 3)])), isTrue);
    });

    test('the two categories are declared, and a post with files opens the app', () {
      final source = _read('lib/platform/notifications.dart');
      expect(source, contains('DarwinNotificationCategory(kDueCategory'));
      expect(RegExp(r'DarwinNotificationCategory\(kDueOpensAppCategory, actions: \[\s*DarwinNotificationAction\.plain\(kPublishAction, .Publish now., options: \{DarwinNotificationActionOption\.foreground\}\)').hasMatch(source), isTrue);
    });

    test('nothing promises more than iOS gives', () {
      final readme = _read('../../README.md');
      expect(readme, isNot(contains('button posts without opening the app')));
      expect(_read('lib/ui/settings/scheduling_section.dart'), isNot(contains('button posts without opening NEFORUM')));
    });
  });
}
