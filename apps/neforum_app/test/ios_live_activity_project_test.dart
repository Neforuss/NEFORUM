// Swift and the Xcode project compile only on a Mac, in CI. These read the files, so a
// hand edit that breaks the project, or a word a stale Live Activity must never say,
// fails here first.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_core/neforum_core.dart' show Post, PostStatus, MediaAttachment;
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/state/scheduler.dart';

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
