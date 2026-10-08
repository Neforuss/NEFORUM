/// Web: `package:http` surfaces everything as ClientException, which the
/// caller already treats as transient.
bool isTransientIoError(Object e) => false;
