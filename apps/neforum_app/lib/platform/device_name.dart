import 'device_name_web.dart' if (dart.library.io) 'device_name_io.dart' as impl;

/// This computer's or phone's network name ("DESKTOP-AB12", "Alices-iPhone"),
/// to tell devices apart in the sync settings. Empty when unknown.
String deviceHostName() => impl.deviceHostName();
