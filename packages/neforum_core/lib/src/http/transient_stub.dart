/// Web: `package:http` surfaces everything as ClientException, which the
/// caller already treats as transient.
bool isTransientIoError(Object e) => false;

/// Web: `BrowserClient` collects the whole body before it sends any, so a count of
/// its pieces would read "all sent" at once. A request reports only on its answer.
const bool bodyPiecesAreCounted = false;

/// Web: the browser does not say why a request failed.
bool isConnectFailure(Object e) => false;
