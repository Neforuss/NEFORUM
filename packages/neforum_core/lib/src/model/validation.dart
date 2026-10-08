import 'package:meta/meta.dart';

enum IssueSeverity {
  /// Publishing will fail or be refused.
  error,

  /// Publishing will work but something was changed or looks off
  /// (text truncated, media dropped, hashtags moved).
  warning,

  /// Purely informational ("will be published as a 3-part thread").
  info,
}

/// A problem (or notice) found while adapting a post for one platform.
@immutable
class ValidationIssue {
  const ValidationIssue({
    required this.severity,
    required this.code,
    required this.message,
    this.field,
  });

  const ValidationIssue.error(this.code, this.message, {this.field})
      : severity = IssueSeverity.error;

  const ValidationIssue.warning(this.code, this.message, {this.field})
      : severity = IssueSeverity.warning;

  const ValidationIssue.info(this.code, this.message, {this.field})
      : severity = IssueSeverity.info;

  final IssueSeverity severity;

  /// Stable machine-readable code, e.g. `text.too_long`, `media.too_many`.
  final String code;
  final String message;

  /// Which part of the post the issue refers to (`text`, `title`, `media`,
  /// `link`, `account`).
  final String? field;

  bool get isError => severity == IssueSeverity.error;

  @override
  String toString() => '[${severity.name}] $code: $message';
}

extension ValidationIssuesX on Iterable<ValidationIssue> {
  bool get hasErrors => any((i) => i.isError);
  Iterable<ValidationIssue> get errors => where((i) => i.isError);
  Iterable<ValidationIssue> get warnings =>
      where((i) => i.severity == IssueSeverity.warning);
}
