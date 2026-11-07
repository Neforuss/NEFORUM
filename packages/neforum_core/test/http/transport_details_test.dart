import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  test('details of an exception from outside NeforumHttp never quote the path or query', () {
    final details = NeforumHttp.transportDetails(
      http.ClientException('Write failed', Uri.parse('https://example.test/v1/me?access_token=SECRET123')),
    );
    expect(details, isNot(contains('SECRET123')));
    expect(details, isNot(contains('/v1/me')));
    expect(details, contains('Write failed'));
    expect(details, contains('example.test'));
  });
}