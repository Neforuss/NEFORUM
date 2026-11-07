import 'process_identity_web.dart' if (dart.library.io) 'process_identity_io.dart' as impl;

/// Names this OS process, the same for every isolate in it, for the publish journal.
/// Android and iOS only: there one process is all there can be, so an entry from
/// another process has nothing running behind it. Null elsewhere, where a second live
/// NEFORUM may share the data folder.
String? publishProcessIdentity() => impl.publishProcessIdentity();

/// [pid] plus the process's start time from the text of `/proc/self/stat`, so a reused
/// pid is another process. [stat] null or unreadable leaves the pid: the worst a clash
/// can then do is fall back to the heartbeat rule. The command name in the text may
/// hold spaces and brackets, so fields count from the last `)`.
String processIdentityFrom(int pid, String? stat) {
  final end = stat?.lastIndexOf(')') ?? -1;
  if (stat == null || end < 0) return '$pid';
  final fields = stat.substring(end + 1).trim().split(RegExp(r'\s+'));
  // Field 22 of proc(5), starttime; the third field is the first one after the name.
  return fields.length > 19 ? '$pid:${fields[19]}' : '$pid';
}
