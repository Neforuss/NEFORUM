enum LogLevel { debug, info, warn, error }

typedef LogSink = void Function(LogLevel level, String area, String message, [Object? error]);

/// Minimal logger: one sink, no dependencies. The app wires it to its own
/// log view; the CLI prints to stderr.
class Logger {
  Logger(this.area, {LogSink? sink}) : _sink = sink ?? Logger.defaultSink;

  static LogSink defaultSink = (level, area, message, [error]) {};

  final String area;
  final LogSink _sink;

  void debug(String message) => _sink(LogLevel.debug, area, message);
  void info(String message) => _sink(LogLevel.info, area, message);
  void warn(String message, [Object? error]) => _sink(LogLevel.warn, area, message, error);
  void error(String message, [Object? error]) => _sink(LogLevel.error, area, message, error);

  Logger child(String subArea) => Logger('$area/$subArea', sink: _sink);
}

/// Wall-clock source, injectable so tests and the scheduler can control time.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now();
