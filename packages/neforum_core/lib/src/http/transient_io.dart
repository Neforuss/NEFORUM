import 'dart:io';

/// Native platforms: connection resets, DNS failures and TLS handshake
/// hiccups are worth one more try.
bool isTransientIoError(Object e) =>
    e is SocketException || e is HandshakeException || e is HttpException;

/// A body's pieces go to the connection as they are read, so a count of them says
/// how far it has got.
const bool bodyPiecesAreCounted = true;

/// No connection was made, so nothing of the request left: the name did not
/// resolve, the server refused, no route, or the TLS handshake failed. A write
/// that fails on a live connection is not one of these.
bool isConnectFailure(Object e) {
  if (e is HandshakeException) return true;
  if (e is! SocketException) return false;
  if (e.message.contains('Failed host lookup')) return true;
  return _connectErrors.contains(e.osError?.errorCode);
}

/// ECONNREFUSED, ENETUNREACH and EHOSTUNREACH on Linux and Android, on macOS and
/// iOS, and on Windows.
const _connectErrors = {111, 101, 113, 61, 51, 65, 10061, 10051, 10065};
