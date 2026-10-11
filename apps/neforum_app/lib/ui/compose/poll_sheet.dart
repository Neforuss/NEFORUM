import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../theme/tokens.dart';

/// Returned by [showPollEditor] when the user removes the poll.
const PostPoll kRemovePoll = PostPoll(options: []);

enum _Kind { poll, quiz, imagePoll }

/// Edits the post's poll or quiz. [rules] are the limits of the networks that
/// take polls ([networks] names them); [imageCount] is how many images the
/// post has, for image polls. Returns null when cancelled, [kRemovePoll]
/// when removed.
Future<PostPoll?> showPollEditor(
  BuildContext context, {
  PostPoll? initial,
  required PollRules rules,
  required String networks,
  required int imageCount,
}) {
  final editor = _PollEditor(initial: initial, rules: rules, networks: networks, imageCount: imageCount);
  if (context.isCompact) {
    return showModalBottomSheet<PostPoll>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => editor);
  }
  return showDialog<PostPoll>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: editor),
    ),
  );
}

class _PollEditor extends StatefulWidget {
  const _PollEditor({required this.initial, required this.rules, required this.networks, required this.imageCount});
  final PostPoll? initial;
  final PollRules rules;
  final String networks;
  final int imageCount;

  @override
  State<_PollEditor> createState() => _PollEditorState();
}

class _PollEditorState extends State<_PollEditor> {
  late _Kind _kind;
  late List<TextEditingController> _options;
  late final TextEditingController _explanation;
  int? _correct;

  PollRules get r => widget.rules;
  bool get _imagePollPossible => r.imagePolls && widget.imageCount >= r.minOptions;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _kind = p == null ? _Kind.poll : (p.imageOptions ? _Kind.imagePoll : (p.isQuiz ? _Kind.quiz : _Kind.poll));
    final texts = p?.options ?? const <String>[];
    _options = [for (var i = 0; i < (texts.length < r.minOptions ? r.minOptions : texts.length); i++) TextEditingController(text: i < texts.length ? texts[i] : '')];
    _explanation = TextEditingController(text: p?.explanation ?? '');
    _correct = p?.correctIndex;
    if (_kind == _Kind.imagePoll) _fitToImages();
  }

  @override
  void dispose() {
    for (final c in _options) {
      c.dispose();
    }
    _explanation.dispose();
    super.dispose();
  }

  /// An image poll has exactly one caption per image (up to the maximum).
  void _fitToImages() {
    final n = widget.imageCount.clamp(r.minOptions, r.maxOptions);
    while (_options.length < n) {
      _options.add(TextEditingController());
    }
    while (_options.length > n) {
      _options.removeLast().dispose();
    }
  }

  int? get _maxLength => switch (_kind) {
        _Kind.poll => r.optionMaxLength,
        _Kind.quiz => r.quizOptionMaxLength,
        _Kind.imagePoll => r.imageOptionMaxLength,
      };

  bool get _valid {
    final filled = _options.where((c) => c.text.trim().isNotEmpty).length;
    if (filled < r.minOptions) return false;
    final max = _maxLength;
    if (max != null && _options.any((c) => c.text.trim().characters.length > max)) return false;
    if (_kind == _Kind.quiz) {
      final c = _correct;
      if (c == null || c >= _options.length || _options[c].text.trim().isEmpty) return false;
      final e = r.quizExplanationMaxLength;
      if (e != null && _explanation.text.trim().characters.length > e) return false;
    }
    return true;
  }

  PostPoll _result() => PostPoll(
        options: [for (final c in _options) c.text.trim()],
        kind: _kind == _Kind.quiz ? PollKind.quiz : PollKind.poll,
        correctIndex: _kind == _Kind.quiz ? _correct : null,
        explanation: _kind == _Kind.quiz && _explanation.text.trim().isNotEmpty ? _explanation.text.trim() : null,
        imageOptions: _kind == _Kind.imagePoll,
      );

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final max = _maxLength;
    final optionFields = <Widget>[
      for (var i = 0; i < _options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_kind == _Kind.quiz)
              Padding(padding: const EdgeInsets.only(top: Space.xs), child: Radio<int>(value: i)),
            Expanded(
              child: TextField(
                controller: _options[i],
                onChanged: (_) => setState(() {}),
                maxLength: max,
                decoration: InputDecoration(
                  labelText: _kind == _Kind.imagePoll ? 'Caption for image ${i + 1}' : 'Answer ${i + 1}',
                  counterText: max == null ? null : '${_options[i].text.characters.length}/$max',
                ),
              ),
            ),
            if (_kind != _Kind.imagePoll && _options.length > r.minOptions)
              IconButton(
                tooltip: 'Remove answer',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => setState(() {
                  _options.removeAt(i).dispose();
                  if (_correct != null && _correct! >= i) _correct = _correct == i ? null : _correct! - 1;
                }),
              ),
          ]),
        ),
    ];

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.xxl, Space.xs),
        child: Text('Poll or quiz', style: context.text.headlineSmall),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: Text('Goes to ${widget.networks}; other networks get the post without it. Your post text is the question.',
            style: context.text.bodySmall),
      ),
      const SizedBox(height: Space.md),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<_Kind>(
              segments: [
                const ButtonSegment(value: _Kind.poll, label: Text('Poll'), icon: Icon(Icons.poll_outlined, size: 18)),
                if (r.quizzes) const ButtonSegment(value: _Kind.quiz, label: Text('Quiz'), icon: Icon(Icons.quiz_outlined, size: 18)),
                if (r.imagePolls)
                  ButtonSegment(
                    value: _Kind.imagePoll,
                    label: const Text('Image poll'),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    enabled: _imagePollPossible,
                    tooltip: _imagePollPossible ? null : 'Attach ${r.minOptions} to ${r.maxOptions} images to the post first',
                  ),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _kind = s.first;
                if (_kind == _Kind.imagePoll) _fitToImages();
              }),
            ),
            const SizedBox(height: Space.lg),
            if (_kind == _Kind.quiz)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text('Pick the correct answer with the circle next to it.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              ),
            if (_kind == _Kind.imagePoll)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text('Each answer is one of the post\'s images, in order.', style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
              ),
            if (_kind == _Kind.quiz)
              RadioGroup<int>(
                groupValue: _correct,
                onChanged: (v) => setState(() => _correct = v),
                child: Column(children: optionFields),
              )
            else
              ...optionFields,
            if (_kind != _Kind.imagePoll && _options.length < r.maxOptions)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _options.add(TextEditingController())),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add answer'),
                ),
              ),
            if (_kind == _Kind.quiz) ...[
              const SizedBox(height: Space.sm),
              TextField(
                controller: _explanation,
                onChanged: (_) => setState(() {}),
                minLines: 2,
                maxLines: 5,
                maxLength: r.quizExplanationMaxLength,
                decoration: const InputDecoration(labelText: 'Explanation (optional, shown after answering)'),
              ),
            ],
            if (r.notes != null) Text(r.notes!, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
            const SizedBox(height: Space.lg),
          ]),
        ),
      ),
      Divider(height: 1, color: nf.border),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.md, Space.xxl, Space.lg),
        child: Row(children: [
          if (widget.initial != null)
            TextButton(
              onPressed: () => Navigator.pop(context, kRemovePoll),
              style: TextButton.styleFrom(foregroundColor: nf.danger),
              child: const Text('Remove poll'),
            ),
          const Spacer(),
          TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
          const SizedBox(width: Space.sm),
          FilledButton(onPressed: _valid ? () => Navigator.pop(context, _result()) : null, child: const Text('Done')),
        ]),
      ),
    ]);
  }
}
