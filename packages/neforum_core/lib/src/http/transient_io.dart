import 'dart:io';

/// Native platforms: connection resets, DNS failures and TLS handshake
/// hiccups are worth one more try.
bool isTransientIoError(Object e) =>
    e is SocketException || e is HandshakeException || e is HttpException;
