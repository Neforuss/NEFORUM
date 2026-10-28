// The update check: version comparison, reading latest.json, when automatic
// checks run, what the request carries (nothing about this NEFORUM or this
// device), and what the banner does with the answer.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/env.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/update_check.dart';
import 'package:neforum_app/platform/update_check_io.dart' as io;
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/update_checks.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _latestJson({String version = '9.0.0', bool critical = false}) => {
      'version': version,
      'published': '2026-11-02T10:00:00Z',
      'notes': 'Linux builds and an update check.',
      'critical': critical,
      'downloads': {
        'windows-installer': {'url': 'https://github.com/Neforuss/NEFORUM/releases/download/v$version/NEFORUM-Setup-$version.exe', 'sha256': _sha},
      },
    };

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object> settings = const {}]) : json = {'settings.json': settings};
  final Map<String, Object> json;
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

void main() {
  group('compareVersions', () {
    test('compares each part as a number', () {
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.3.0'), lessThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.3.0'), 0);
    });

    test('missing parts are zero; build numbers and suffixes are ignored', () {
      expect(compareVersions('1.3', '1.3.0'), 0);
      expect(compareVersions('1.3.0.1', '1.3'), greaterThan(0));
      expect(compareVersions('1.3.0+21', '1.3.0+20'), 0);
      expect(compareVersions('1.3.0-beta', '1.3.0'), 0);
      expect(compareVersions(' 1.4.0 ', '1.3.9'), greaterThan(0));
    });

    test('a release is newer than this NEFORUM only when its number is higher', () {
      expect(const LatestRelease(version: '99.0.0').isNewerThan(kAppVersion), isTrue);
      expect(const LatestRelease(version: kAppVersion).isNewerThan(kAppVersion), isFalse);
      expect(const LatestRelease(version: '0.1.0').isNewerThan(kAppVersion), isFalse);
    });
  });

  group('latest.json', () {
    test('reads every field', () {
      final r = LatestRelease.fromJson(_latestJson(critical: true));
      expect(r.version, '9.0.0');
      expect(r.published, DateTime.utc(2026, 11, 2, 10));
      expect(r.notes, 'Linux builds and an update check.');
      expect(r.critical, isTrue);
      expect(r.downloads.keys, ['windows-installer']);
      expect(r.downloads['windows-installer']!.sha256, _sha);
    });

    test('round-trips through toJson (kept in settings for the banner)', () {
      final r = LatestRelease.fromJson(_latestJson());
      final again = LatestRelease.fromJson(jsonDecode(jsonEncode(r.toJson())));
      expect(again.toJson(), r.toJson());
    });

    test('optional fields may be missing; critical is only a real true', () {
      final r = LatestRelease.fromJson({'version': '1.4.0', 'critical': 'yes'});
      expect(r.notes, isEmpty);
      expect(r.published, isNull);
      expect(r.critical, isFalse);
      expect(r.downloads, isEmpty);
    });

    test('downloads without an https URL or a SHA-256 are left out', () {
      final r = LatestRelease.fromJson({
        'version': '1.4.0',
        'downloads': {
          'good': {'url': 'https://example.org/a.zip', 'sha256': _sha.toUpperCase()},
          'http': {'url': 'http://example.org/a.zip', 'sha256': _sha},
          'short-hash': {'url': 'https://example.org/a.zip', 'sha256': 'abc'},
          'no-url': {'sha256': _sha},
          'not-a-map': 'https://example.org/a.zip',
        },
      });
      expect(r.downloads.keys, ['good']);
      expect(r.downloads['good']!.sha256, _sha, reason: 'stored lowercase');
    });

    test('anything without a usable version is refused', () {
      for (final bad in <Object?>[null, 'text', [], {}, {'version': 3}, {'version': ''}, {'version': 'v1.3.0'}, {'version': '1.3.0-beta'}]) {
        expect(() => LatestRelease.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('automatic check schedule', () {
    test('the first check waits a random 10 minutes to 2 hours after start, never at once', () {
      final rng = math.Random(7);
      final delays = [for (var i = 0; i < 200; i++) UpdateSchedule.nextDelay(now: DateTime(2026, 11, 1, 9), random: rng)];
      for (final d in delays) {
        expect(d, greaterThanOrEqualTo(UpdateSchedule.minimumDelay));
        expect(d, lessThanOrEqualTo(UpdateSchedule.maximumDelay));
      }
      expect(delays.toSet().length, greaterThan(150), reason: 'spread out, not one fixed moment');
    });

    test('checks at most once a day: a recent check waits for the rest of the day', () {
      final now = DateTime(2026, 11, 1, 9);
      final d = UpdateSchedule.nextDelay(now: now, lastCheck: now.subtract(const Duration(hours: 1)), random: math.Random(1));
      expect(d, greaterThanOrEqualTo(const Duration(hours: 23) + UpdateSchedule.minimumDelay));
      expect(d, lessThanOrEqualTo(const Duration(hours: 23) + UpdateSchedule.maximumDelay));
    });

    test('a launch soon after another does not check again', () {
      final now = DateTime(2026, 11, 1, 9);
      // Ten launches over a morning: every one waits until the day is over.
      for (var minutes = 0; minutes < 600; minutes += 60) {
        final last = now.subtract(Duration(minutes: minutes));
        final d = UpdateSchedule.nextDelay(now: now, lastCheck: last, random: math.Random(minutes));
        expect(now.add(d).isAfter(last.add(UpdateSchedule.interval)), isTrue, reason: '$minutes min after the last check');
      }
    });

    test('an old last check is due: only the random delay', () {
      final now = DateTime(2026, 11, 1, 9);
      final d = UpdateSchedule.nextDelay(now: now, lastCheck: now.subtract(const Duration(days: 3)), random: math.Random(2));
      expect(d, greaterThanOrEqualTo(UpdateSchedule.minimumDelay));
      expect(d, lessThanOrEqualTo(UpdateSchedule.maximumDelay));
    });

    test('a last check in the future (clock set back) waits a day at most', () {
      final now = DateTime(2026, 11, 1, 9);
      final d = UpdateSchedule.nextDelay(now: now, lastCheck: now.add(const Duration(days: 30)), random: math.Random(3));
      expect(d, lessThanOrEqualTo(UpdateSchedule.interval + UpdateSchedule.maximumDelay));
    });
  });

  group('the request', () {
    late HttpServer server;
    late List<HttpRequest> requests;
    late Object? Function() reply;
    late int status;

    setUp(() async {
      requests = [];
      status = 200;
      reply = _latestJson;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        requests.add(r);
        r.response.statusCode = status;
        r.response.headers
          ..contentType = ContentType.json
          // A server that sets a cookie: the next check must not send it back.
          ..add(HttpHeaders.setCookieHeader, 'tracking=1; Path=/');
        r.response.write(jsonEncode(reply()));
        await r.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/neforum/latest.json');

    test('is one plain GET with a fixed User-Agent and nothing about this NEFORUM or device', () async {
      final r = await io.fetchLatestRelease(url: url());
      expect(r.version, '9.0.0');
      await io.fetchLatestRelease(url: url());
      expect(requests, hasLength(2));
      for (final req in requests) {
        expect(req.method, 'GET');
        expect(req.uri.path, '/neforum/latest.json');
        expect(req.uri.query, isEmpty);
        expect(req.headers.value(HttpHeaders.userAgentHeader), kUpdateCheckUserAgent);
        expect(req.headers.value(HttpHeaders.cookieHeader), isNull, reason: 'no cookies, not even the one the server set');
        expect(req.cookies, isEmpty);
        final names = <String>[];
        req.headers.forEach((name, values) {
          names.add(name);
          final all = values.join(' ').toLowerCase();
          for (final secret in [kAppVersion, 'dart', Platform.operatingSystem, 'neforum/']) {
            expect(all.contains(secret.toLowerCase()), isFalse, reason: 'header $name: "$all" mentions $secret');
          }
        });
        expect(names.toSet().difference({'user-agent', 'accept', 'accept-encoding', 'host', 'connection', 'content-length'}), isEmpty,
            reason: 'only the headers HTTP needs: $names');
      }
    });

    test('the default client is replaced by an injected one, which gets the fixed User-Agent too', () async {
      HttpClient? made;
      await io.fetchLatestRelease(url: url(), createClient: () => made = HttpClient()..userAgent = 'Dart/3.13 (dart:io) $kAppVersion');
      expect(made, isNotNull);
      expect(made!.userAgent, kUpdateCheckUserAgent);
      expect(requests.single.headers.value(HttpHeaders.userAgentHeader), kUpdateCheckUserAgent);
    });

    test('a status other than 200 or a file that is not latest.json fails', () async {
      status = 404;
      await expectLater(io.fetchLatestRelease(url: url()), throwsA(isA<HttpException>()));
      status = 200;
      reply = () => {'hello': 'world'};
      await expectLater(io.fetchLatestRelease(url: url()), throwsFormatException);
    });
  });

  group('the banner', () {
    Future<(ProviderContainer, _MemoryStorage)> boot({String version = '9.0.0', bool critical = false, Map<String, Object> settings = const {}}) async {
      final storage = _MemoryStorage(settings);
      final services = await AppServices.create(demo: true, storage: storage);
      final c = ProviderContainer(overrides: [
        servicesProvider.overrideWithValue(services),
        latestReleaseFetcherProvider.overrideWithValue(() async => LatestRelease.fromJson(_latestJson(version: version, critical: critical))),
      ]);
      addTearDown(c.dispose);
      return (c, storage);
    }

    test('Check now keeps the answer and the time, and shows a newer version', () async {
      final (c, storage) = await boot();
      expect(c.read(updateCheckProvider).available, isNull);
      final before = DateTime.now();
      await c.read(updateCheckProvider.notifier).checkNow();
      final s = c.read(settingsProvider);
      expect(s.updateCheckedAt!.isBefore(before), isFalse);
      expect(c.read(updateCheckProvider).available!.version, '9.0.0');
      expect(c.read(updateCheckProvider).showsBanner(s), isTrue);
      final saved = storage.json['settings.json']! as Map<String, dynamic>;
      expect(saved['updateLatestRelease']['version'], '9.0.0', reason: 'the banner survives a restart');
      expect(saved.containsKey('updateCheckedAt'), isTrue);
    });

    test('the same or an older version shows nothing', () async {
      final (c, _) = await boot(version: kAppVersion);
      await c.read(updateCheckProvider.notifier).checkNow();
      expect(c.read(updateCheckProvider).available, isNull);
      expect(c.read(updateCheckProvider).showsBanner(c.read(settingsProvider)), isFalse);
    });

    test('closing it hides that version for good, but a later version shows again', () async {
      final (c, _) = await boot();
      await c.read(updateCheckProvider.notifier).checkNow();
      await c.read(updateCheckProvider.notifier).dismiss();
      expect(c.read(settingsProvider).updateDismissedVersion, '9.0.0');
      expect(c.read(updateCheckProvider).showsBanner(c.read(settingsProvider)), isFalse);

      // The next start, with the same version saved.
      final restarted = UpdateCheckStatus(latest: LatestRelease.fromJson(_latestJson()));
      expect(restarted.showsBanner(c.read(settingsProvider)), isFalse);
      final later = UpdateCheckStatus(latest: LatestRelease.fromJson(_latestJson(version: '9.1.0')));
      expect(later.showsBanner(c.read(settingsProvider)), isTrue);
    });

    test('a critical release can be hidden only until the next start', () async {
      final (c, _) = await boot(critical: true);
      await c.read(updateCheckProvider.notifier).checkNow();
      await c.read(updateCheckProvider.notifier).dismiss();
      expect(c.read(updateCheckProvider).showsBanner(c.read(settingsProvider)), isFalse);
      expect(c.read(settingsProvider).updateDismissedVersion, isNull);
      final restarted = UpdateCheckStatus(latest: LatestRelease.fromJson(_latestJson(critical: true)));
      expect(restarted.showsBanner(c.read(settingsProvider)), isTrue);
    });

    test('a saved answer is read back at start', () async {
      final (c, _) = await boot(settings: {'updateLatestRelease': _latestJson().cast<String, Object>()});
      expect(c.read(updateCheckProvider).available!.version, '9.0.0');
    });
  });

  group('the setting', () {
    test('asks by default (new installs and updates from 1.2, whose settings have no key)', () {
      expect(const AppSettings().updateCheck, UpdateCheckMode.ask);
      expect(AppSettings.fromJson({'onboarded': true, 'themeMode': 'dark'}).updateCheck, UpdateCheckMode.ask);
    });

    test('is kept, and stays on this device (never synced or moved)', () {
      final s = AppSettings.fromJson({'updateCheck': 'automatic'});
      expect(s.updateCheck, UpdateCheckMode.automatic);
      final checked = DateTime.utc(2026, 11, 1, 8);
      final json = s.copyWith(updateCheckedAt: checked, updateDismissedVersion: '1.3.1').toJson();
      expect(json['updateCheck'], 'automatic');
      expect(AppSettings.fromJson(json).updateCheckedAt, checked);
      expect(AppSettings.fromJson(json).updateDismissedVersion, '1.3.1');
      for (final key in ['updateCheck', 'updateCheckedAt', 'updateLatestRelease', 'updateDismissedVersion']) {
        expect(exportableSettings(s.copyWith(updateCheckedAt: checked, updateLatestRelease: {'version': '9.0.0'})).containsKey(key), isFalse, reason: key);
      }
      expect(withImportedSettings(const AppSettings(), {'updateCheck': 'off'}).updateCheck, UpdateCheckMode.ask);
    });

    test('store builds and the web preview never check', () {
      expect(kStoreBuild, isFalse, reason: 'tests run without NEFORUM_STORE_BUILD');
      expect(updateChecksAvailable, isTrue);
    });
  });
}
