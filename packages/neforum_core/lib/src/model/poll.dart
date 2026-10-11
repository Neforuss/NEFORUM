import 'package:meta/meta.dart';

/// What kind of question a post asks.
enum PollKind {
  /// Viewers vote; no answer is right.
  poll,

  /// One answer is correct; viewers see whether they got it right.
  quiz,
}

/// A poll or quiz attached to a post. The post text is the question.
///
/// Only platforms whose descriptor has [PlatformDescriptor.polls] receive it;
/// everyone else gets the post without the poll.
@immutable
class PostPoll {
  const PostPoll({
    required this.options,
    this.kind = PollKind.poll,
    this.correctIndex,
    this.explanation,
    this.imageOptions = false,
  });

  factory PostPoll.fromJson(Map<String, dynamic> json) => PostPoll(
        options: (json['options'] as List? ?? const []).cast<String>(),
        kind: PollKind.values.asNameMap()[json['kind']] ?? PollKind.poll,
        correctIndex: json['correctIndex'] as int?,
        explanation: json['explanation'] as String?,
        imageOptions: json['imageOptions'] as bool? ?? false,
      );

  /// Answer texts in order. For an image poll these are the captions of the
  /// post's images, in the same order.
  final List<String> options;
  final PollKind kind;

  /// Quiz only: index into [options] of the right answer.
  final int? correctIndex;

  /// Quiz only: shown after answering.
  final String? explanation;

  /// Image poll: option i is the post's image i with its caption.
  final bool imageOptions;

  bool get isQuiz => kind == PollKind.quiz;

  /// Options with surrounding blanks removed, empty ones dropped.
  List<String> get cleanOptions => [for (final o in options) if (o.trim().isNotEmpty) o.trim()];

  PostPoll copyWith({
    List<String>? options,
    PollKind? kind,
    int? correctIndex,
    String? explanation,
    bool? imageOptions,
    bool clearCorrect = false,
    bool clearExplanation = false,
  }) =>
      PostPoll(
        options: options ?? this.options,
        kind: kind ?? this.kind,
        correctIndex: clearCorrect ? null : (correctIndex ?? this.correctIndex),
        explanation: clearExplanation ? null : (explanation ?? this.explanation),
        imageOptions: imageOptions ?? this.imageOptions,
      );

  Map<String, dynamic> toJson() => {
        'options': options,
        'kind': kind.name,
        if (correctIndex != null) 'correctIndex': correctIndex,
        if (explanation != null) 'explanation': explanation,
        if (imageOptions) 'imageOptions': true,
      };

  @override
  bool operator ==(Object other) =>
      other is PostPoll &&
      other.kind == kind &&
      other.correctIndex == correctIndex &&
      other.explanation == explanation &&
      other.imageOptions == imageOptions &&
      _listEq(other.options, options);

  @override
  int get hashCode => Object.hash(kind, correctIndex, explanation, imageOptions, Object.hashAll(options));

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
