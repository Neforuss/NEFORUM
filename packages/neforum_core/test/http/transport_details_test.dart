import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  group('details of an exception from outside NeforumHttp', () {
    test('never quote the path or query', () {
      final details = NeforumHttp.transportDetails(
        http.ClientException('Write failed', Uri.parse('https://example.test/v1/me?access_token=SECRET123')),
      );
      expect(details, isNot(contains('SECRET123')));
      expect(details, isNot(contains('/v1/me')));
      expect(details, contains('Write failed'));
      expect(details, contains('example.test'));
    });

    test('keep every field of the system text that diagnoses a dropped upload', () {
      final details = NeforumHttp.transportDetails(http.ClientException(
        'SocketException: Write failed (OS Error: An established connection was aborted by the software in your host machine, errno = 10053), address = example.test, port = 51122',
        Uri.parse('https://example.test/api/v2/media'),
      ));
      expect(details, contains('errno = 10053'));
      expect(details, contains('Write failed'));
      expect(details, contains('port = 51122'));
      expect(details, contains('https://example.test'));
      expect(details, isNot(contains('/api/v2/media')));
    });

    test('keep a host lookup failure, quotes and all', () {
      final details = NeforumHttp.transportDetails(http.ClientException("Failed host lookup: 'example.test'"));
      expect(details, contains("Failed host lookup: 'example.test'"));
    });

    for (final (name, quoted) in const [
      ('a form body', 'failed: message=hello&access_token=SECRET123'),
      ('one form field', 'failed: access_token=SECRET123'),
      ('a JSON body', 'failed: {"access_token":"SECRET123"}'),
    ]) {
      test('drop the text when it quotes $name', () {
        final details = NeforumHttp.transportDetails(http.ClientException(quoted));
        expect(details, isNot(contains('SECRET123')));
        expect(details, contains('left out'));
      });
    }
  });
}