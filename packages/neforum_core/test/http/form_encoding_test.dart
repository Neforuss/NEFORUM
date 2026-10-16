import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  test('forms go out as plain application/x-www-form-urlencoded, percent-encoded UTF-8', () async {
    late http.Request seen;
    final client = NeforumHttp(client: MockClient((r) async {
      seen = r;
      return http.Response('{}', 200);
    }));
    await client.postForm(Uri.parse('https://example.com/token'), {
      'code': 'a*b!c+d e',
      'redirect_uri': 'http://127.0.0.1:52771/callback',
      'name': 'Zoë',
    });
    expect(seen.headers['content-type'], 'application/x-www-form-urlencoded');
    final body = utf8.decode(seen.bodyBytes);
    expect(body, 'code=a%2Ab%21c%2Bd+e&redirect_uri=http%3A%2F%2F127.0.0.1%3A52771%2Fcallback&name=Zo%C3%AB');
    expect(Uri.splitQueryString(body), {'code': 'a*b!c+d e', 'redirect_uri': 'http://127.0.0.1:52771/callback', 'name': 'Zoë'});
  });

  test('a caller-supplied Content-Type is kept', () async {
    late http.Request seen;
    final client = NeforumHttp(client: MockClient((r) async {
      seen = r;
      return http.Response('{}', 200);
    }));
    await client.postForm(Uri.parse('https://example.com/x'), {'a': 'b'},
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'});
    expect(seen.headers['content-type'], 'application/x-www-form-urlencoded; charset=utf-8');
  });
}
