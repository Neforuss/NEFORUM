/// Web: `package:http` surfaces everything as ClientException, which the
/// caller already treats as transient.
bool isTransientIoError(Object e) => false;

/// Web: the browser does not say why a request failed.
bool isConnectFailure(Object e) => false;
