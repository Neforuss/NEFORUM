import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

// Every key below is a published documentation example (Twitter/X's
// "Creating a signature" page and RFC 5849), not a real credential.

const _consumerKey = 'xvz1evFS4wEEPTGEFPHBog';
const _consumerSecret = 'kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw';
const _token = '370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb';
const _tokenSecret = 'LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE';
const _nonce = 'kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg';
const _timestamp = 1318622958;
const _status = 'Hello Ladies + Gentlemen, a signed OAuth request!';

String _docsHeader(String host) => OAuth1.authorizationHeader(
      method: 'POST',
      url: Uri.parse('https://$host/1.1/statuses/update.json?include_entities=true'),
      consumerKey: _consumerKey,
      consumerSecret: _consumerSecret,
      token: _token,
      tokenSecret: _tokenSecret,
      form: const {'status': _status},
      nonce: _nonce,
      timestamp: _timestamp,
    );

void main() {
  group('percent-encoding (RFC 3986, as RFC 5849 3.6 requires)', () {
    test('examples from X\'s "Percent encoding parameters" page', () {
      expect(OAuth1.percentEncode('Ladies + Gentlemen'), 'Ladies%20%2B%20Gentlemen');
      expect(OAuth1.percentEncode('An encoded string!'), 'An%20encoded%20string%21');
      expect(OAuth1.percentEncode('Dogs, Cats & Mice'), 'Dogs%2C%20Cats%20%26%20Mice');
      expect(OAuth1.percentEncode('☃'), '%E2%98%83');
    });

    test('only unreserved characters stay, hex is upper-case', () {
      expect(OAuth1.percentEncode('AZaz09-._~'), 'AZaz09-._~');
      expect(OAuth1.percentEncode("!*'()"), '%21%2A%27%28%29');
      expect(OAuth1.percentEncode('a/b:c=d&e'), 'a%2Fb%3Ac%3Dd%26e');
      expect(OAuth1.percentEncode('é'), '%C3%A9');
    });
  });

  group('signature', () {
    test('Twitter\'s classic "Creating a signature" example', () {
      final url = Uri.parse('https://api.twitter.com/1.1/statuses/update.json?include_entities=true');
      final base = OAuth1.baseString('POST', url, const [
        MapEntry('include_entities', 'true'),
        MapEntry('status', _status),
        MapEntry('oauth_consumer_key', _consumerKey),
        MapEntry('oauth_nonce', _nonce),
        MapEntry('oauth_signature_method', 'HMAC-SHA1'),
        MapEntry('oauth_timestamp', '$_timestamp'),
        MapEntry('oauth_token', _token),
        MapEntry('oauth_version', '1.0'),
      ]);
      expect(
        base,
        'POST&https%3A%2F%2Fapi.twitter.com%2F1.1%2Fstatuses%2Fupdate.json&include_entities%3Dtrue%26'
        'oauth_consumer_key%3Dxvz1evFS4wEEPTGEFPHBog%26oauth_nonce%3DkYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg%26'
        'oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D1318622958%26'
        'oauth_token%3D370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb%26oauth_version%3D1.0%26'
        'status%3DHello%2520Ladies%2520%252B%2520Gentlemen%252C%2520a%2520signed%2520OAuth%2520request%2521',
      );
      expect(OAuth1.signature(base, _consumerSecret, _tokenSecret), 'hCtSmYh+iHYCEqBWrE7C7hYmtUk=');
    });

    test('the same example on docs.x.com (api.x.com) and the complete header', () {
      final params = OAuth1.parseAuthorization(_docsHeader('api.x.com'))!;
      expect(params['oauth_signature'], 'Ls93hJiZbQ3akF3HF3x1Bz8/zU4=');
      expect(
        _docsHeader('api.twitter.com'),
        'OAuth oauth_consumer_key="xvz1evFS4wEEPTGEFPHBog", '
        'oauth_nonce="kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg", '
        'oauth_signature="hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D", '
        'oauth_signature_method="HMAC-SHA1", '
        'oauth_timestamp="1318622958", '
        'oauth_token="370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb", '
        'oauth_version="1.0"',
      );
    });

    test('RFC 5849 section 1.2: the photo request', () {
      final url = Uri.parse('http://photos.example.net/photos?file=vacation.jpg&size=original');
      final base = OAuth1.baseString('GET', url, [
        for (final q in url.queryParameters.entries) q,
        const MapEntry('oauth_consumer_key', 'dpf43f3p2l4k3l03'),
        const MapEntry('oauth_token', 'nnch734d00sl2jdk'),
        const MapEntry('oauth_signature_method', 'HMAC-SHA1'),
        const MapEntry('oauth_timestamp', '137131202'),
        const MapEntry('oauth_nonce', 'chapoH'),
      ]);
      expect(OAuth1.signature(base, 'kd94hf93k423kf44', 'pfkkdhi9sl3r4s00'), 'MdpQcU8iPSUjWoN/UDMsK2sui9I=');
    });

    test('RFC 5849 section 3.4.1.1: repeated names, empty values, encoded query', () {
      final url = Uri.parse('http://example.com/request?b5=%3D%253D&a3=a&c%40=&a2=r%20b');
      final base = OAuth1.baseString('POST', url, [
        for (final q in url.queryParametersAll.entries)
          for (final v in q.value) MapEntry(q.key, v),
        // The form body `c2&a3=2+q`.
        const MapEntry('c2', ''),
        const MapEntry('a3', '2 q'),
        const MapEntry('oauth_consumer_key', '9djdj82h48djs9d2'),
        const MapEntry('oauth_token', 'kkk9d7dh3k39sjv7'),
        const MapEntry('oauth_signature_method', 'HMAC-SHA1'),
        const MapEntry('oauth_timestamp', '137131201'),
        const MapEntry('oauth_nonce', '7d8f3e4a'),
      ]);
      expect(
        base,
        'POST&http%3A%2F%2Fexample.com%2Frequest&a2%3Dr%2520b%26a3%3D2%2520q%26a3%3Da%26b5%3D%253D%25253D%26'
        'c%2540%3D%26c2%3D%26oauth_consumer_key%3D9djdj82h48djs9d2%26oauth_nonce%3D7d8f3e4a%26'
        'oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D137131201%26oauth_token%3Dkkk9d7dh3k39sjv7',
      );
    });

    test('base URI: lower-case, default port dropped, other ports kept', () {
      expect(OAuth1.baseUri(Uri.parse('HTTPS://API.X.COM:443/2/tweets?x=1#f')), 'https://api.x.com/2/tweets');
      expect(OAuth1.baseUri(Uri.parse('http://Example.com:80/r%20v')), 'http://example.com/r%20v');
      expect(OAuth1.baseUri(Uri.parse('https://www.example.net:8080/?q=1')), 'https://www.example.net:8080/');
    });

    test('an empty token secret keeps the "&" in the key', () {
      expect(OAuth1.signature('base', 'cs'), OAuth1.signature('base', 'cs', ''));
      expect(OAuth1.signature('base', 'cs'), isNot(OAuth1.signature('base', 'cs', 'ts')));
    });
  });

  group('OAuth1Signer', () {
    const keys = OAuth1Credentials(
        consumerKey: _consumerKey, consumerSecret: _consumerSecret, token: _token, tokenSecret: _tokenSecret);

    test('takes the timestamp from the clock and the nonce from the injected generator', () {
      final signer = OAuth1Signer(keys,
          clock: () => DateTime.fromMillisecondsSinceEpoch(_timestamp * 1000 + 999, isUtc: true), nonce: () => _nonce);
      final header = signer.authorization('POST', Uri.parse('https://api.twitter.com/1.1/statuses/update.json?include_entities=true'),
          form: const {'status': _status});
      expect(header, _docsHeader('api.twitter.com'));
    });

    test('a new random nonce for every request', () {
      final signer = OAuth1Signer(keys, clock: () => DateTime.utc(2026, 10, 7));
      final url = Uri.parse('https://api.x.com/2/users/me');
      final a = OAuth1.parseAuthorization(signer.authorization('GET', url))!;
      final b = OAuth1.parseAuthorization(signer.authorization('GET', url))!;
      expect(a['oauth_nonce'], hasLength(32));
      expect(a['oauth_nonce'], matches(RegExp(r'^[A-Za-z0-9]+$')));
      expect(a['oauth_nonce'], isNot(b['oauth_nonce']));
      expect(a['oauth_signature'], isNot(b['oauth_signature']));
      expect(a['oauth_timestamp'], '${DateTime.utc(2026, 10, 7).millisecondsSinceEpoch ~/ 1000}');
    });

    test('query parameters are signed, so a changed query breaks the signature', () {
      final signer = OAuth1Signer(keys, clock: () => DateTime.utc(2026, 10, 7), nonce: () => 'n');
      final a = signer.authorization('GET', Uri.parse('https://api.x.com/2/media/upload?command=STATUS&media_id=1'));
      final b = signer.authorization('GET', Uri.parse('https://api.x.com/2/media/upload?command=STATUS&media_id=2'));
      expect(a, isNot(b));
    });
  });

  group('OAuth1Credentials', () {
    test('round-trips through the secret map and never prints the keys', () {
      const keys = OAuth1Credentials(consumerKey: 'ck', consumerSecret: 'cs', token: 't', tokenSecret: 'ts');
      final secrets = keys.toSecrets({'other': 'kept'});
      expect(secrets, {
        'other': 'kept',
        'oauth1_consumer_key': 'ck',
        'oauth1_consumer_secret': 'cs',
        'oauth1_token': 't',
        'oauth1_token_secret': 'ts',
      });
      final back = OAuth1Credentials.fromSecrets(secrets)!;
      expect([back.consumerKey, back.consumerSecret, back.token, back.tokenSecret], ['ck', 'cs', 't', 'ts']);
      expect('$keys', isNot(contains('cs')));
      // OAuth 2.0 code must not read it as a Bearer token.
      expect(OAuthTokens.fromSecrets(secrets), isNull);
    });

    test('an incomplete set is no credentials', () {
      expect(OAuth1Credentials.fromSecrets(const {'oauth1_consumer_key': 'ck', 'oauth1_consumer_secret': 'cs', 'oauth1_token': 't'}),
          isNull);
      expect(OAuth1Credentials.fromSecrets(const {'access_token': 'at'}), isNull);
    });
  });

  test('NeforumHttp signs every attempt afresh, so a retry never repeats a nonce', () async {
    final seen = <String?>[];
    final http0 = NeforumHttp(
      maxRetries: 1,
      client: MockClient((req) async {
        seen.add(req.headers['Authorization']);
        return seen.length == 1 ? http.Response('busy', 503, headers: {'retry-after': '0'}) : http.Response('{}', 200);
      }),
    );
    var n = 0;
    final res = await http0.get(Uri.parse('https://api.x.com/2/users/me'),
        headers: const {'Accept': 'application/json'}, signHeaders: () => {'Authorization': 'OAuth nonce-${++n}'});
    expect(res.statusCode, 200);
    expect(seen, ['OAuth nonce-1', 'OAuth nonce-2']);
  });
}
