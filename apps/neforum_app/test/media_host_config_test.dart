// Main and fallback media hosts: stored apart, combined for posting, and the
// fallback becomes the main host when the main one is removed.

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const _bucket = {
  'endpoint': 'https://s3.us-west-004.backblazeb2.com',
  'bucket': 'my-post-media',
  'accessKeyId': 'KEYID',
  'secretAccessKey': 'SECRET',
};

void main() {
  late InMemorySecretStore secrets;
  late AppSettings settings;
  final http = NeforumHttp();

  setUp(() async {
    secrets = InMemorySecretStore();
    settings = await storeMediaHost(const AppSettings(), secrets, litterboxHostId, const {});
    settings = await storeMediaHost(settings, secrets, s3HostId, _bucket, slot: MediaHostSlot.fallback);
  });

  test('the fallback is stored apart from the main host, secrets in their own keychain entry', () async {
    expect(settings.mediaHostId, litterboxHostId);
    expect(settings.fallbackMediaHostId, s3HostId);
    expect(settings.fallbackMediaHostConfig, isNot(contains('secretAccessKey')));
    expect(await secrets.read(kFallbackMediaHostSecretsKey), {'secretAccessKey': 'SECRET'});
    expect(await mediaHostValues(settings, secrets, slot: MediaHostSlot.fallback), _bucket);
  });

  test('posting uses one host that tries the main host, then the fallback', () async {
    final host = await buildMediaHost(settings, secrets, http);
    expect(host, isA<FallbackMediaHost>());
    final f = host! as FallbackMediaHost;
    expect(f.main.id, litterboxHostId);
    expect(f.fallback.id, s3HostId);
    expect(await buildMediaHost(settings.copyWith(clearFallbackMediaHost: true), secrets, http), isA<CatboxMediaHost>());
  });

  test('a main host with broken settings leaves the fallback working on its own', () async {
    final broken = settings.copyWith(mediaHostId: s3HostId, mediaHostConfig: const {'bucket': 'only-a-name'});
    expect((await buildMediaHost(broken, secrets, http))?.id, s3HostId);
    expect(await buildMediaHost(broken, secrets, http), isNot(isA<FallbackMediaHost>()));
  });

  test('removing the main host makes the fallback the main host', () async {
    final next = await clearMediaHost(settings, secrets);
    expect(next.mediaHostId, s3HostId);
    expect(next.fallbackMediaHostId, isNull);
    expect(await mediaHostValues(next, secrets), _bucket);
    expect(await secrets.read(kFallbackMediaHostSecretsKey), isNull);
  });

  test('removing the fallback keeps the main host', () async {
    final next = await clearMediaHost(settings, secrets, slot: MediaHostSlot.fallback);
    expect(next.mediaHostId, litterboxHostId);
    expect(next.fallbackMediaHostId, isNull);
    expect(await secrets.read(kFallbackMediaHostSecretsKey), isNull);
  });

  test('a second copy of an account-free host is not offered as the fallback; a second bucket is', () {
    expect(fallbackOptions(litterboxHostId).map((d) => d.id), isNot(contains(litterboxHostId)));
    expect(fallbackOptions(litterboxHostId).map((d) => d.id), contains(s3HostId));
    expect(fallbackOptions(s3HostId).map((d) => d.id), contains(s3HostId));
  });

  test('the fallback survives a settings.json round trip', () {
    final back = AppSettings.fromJson(settings.toJson());
    expect(back.fallbackMediaHostId, s3HostId);
    expect(back.fallbackMediaHostConfig, settings.fallbackMediaHostConfig);
  });
}
