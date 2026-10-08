import '../util/logger.dart';
import 'auth_broker.dart';

/// Web stand-in: there is no local HTTP server in a browser. The app must
/// provide its own [AuthBroker] (e.g. a popup-based one) on web.
class LoopbackAuthBroker implements AuthBroker {
  LoopbackAuthBroker({
    required this.openBrowser,
    this.port = defaultPort,
    this.host = '127.0.0.1',
    this.path = '/callback',
    this.customScheme = 'neforum',
    Logger? log,
  });

  static const int defaultPort = 52771;

  final Future<void> Function(Uri url) openBrowser;
  final int port;
  final String host;
  final String path;
  final String customScheme;

  Uri get loopbackUri => Uri(scheme: 'http', host: host, port: port, path: path);

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) =>
      fixed ?? loopbackUri;

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) async =>
      throw UnsupportedError('LoopbackAuthBroker is not available on web');
}
