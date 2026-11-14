import 'package:meta/meta.dart';

import 'platform_descriptor.dart' show PlatformTier;

/// The value a per-network option takes.
enum PostOptionKind {
  /// On or off (a `bool`).
  toggle,

  /// One of [PostOption.choices] (a `String`), or no choice.
  choice,

  /// Free text (a `String`).
  text,

  /// A whole number (an `int`).
  number,

  /// Some of the post's own photos and videos: a `List<String>` of their
  /// [MediaAttachment.id]s.
  mediaSelection,
}

/// Where the customize sheet shows an option.
enum PostOptionSurface {
  /// With the network's options, up front.
  main,

  /// Folded under "More options": rarely needed, or for people who know the
  /// network well.
  more,

  /// A control of its own elsewhere in the sheet (YouTube's thumbnail
  /// picker, Post or story), not the generic option list.
  dedicated,

  /// Set by NEFORUM itself, never by the user: the key is read by the
  /// adapter but has no control on purpose ([PostOption.help] says why).
  internal,
}

/// How long a choice lasts.
enum PostOptionScope {
  /// This post only (kept in the post's per-network overrides).
  post,

  /// Every post from the account (kept in the account's post defaults,
  /// `ConnectedAccount.config['postDefaults']`).
  account,

  /// Per post, and the user can keep it as the account's default.
  postOrAccount,
}

/// One entry of a [PostOptionKind.choice] option.
@immutable
class PostOptionChoice {
  const PostOptionChoice(this.value, this.label);

  /// What goes into `PostVariant.extra`.
  final String value;

  /// What the user sees.
  final String label;
}

/// A per-network option of a post, declared once on its
/// [PlatformDescriptor.options]: the adapter reads it from
/// `PostVariant.extra[key]` and the app draws its control from this
/// declaration.
@immutable
class PostOption {
  const PostOption({
    required this.key,
    required this.label,
    required this.kind,
    this.help,
    this.hint,
    this.choices = const [],
    this.defaultValue,
    this.defaultLabel,
    this.scope = PostOptionScope.post,
    this.surface = PostOptionSurface.main,
    this.tiers = const {},
    this.gate,
    this.aliases = const [],
    this.apiField,
  });

  /// The `PostVariant.extra` key the adapter reads.
  final String key;
  final String label;
  final PostOptionKind kind;

  /// One or two plain sentences under the control: what it does.
  final String? help;

  /// Example text inside an empty text or number field.
  final String? hint;

  /// The values a [PostOptionKind.choice] option takes.
  final List<PostOptionChoice> choices;

  /// What the adapter does when the option is not set: a `bool` for a
  /// toggle; null when "not set" is its own answer (a choice's
  /// [defaultLabel], an empty text).
  final Object? defaultValue;

  /// For a choice: the words for "no choice" (what the network does then).
  final String? defaultLabel;
  final PostOptionScope scope;
  final PostOptionSurface surface;

  /// The tiers whose accounts can use it; empty: every tier.
  final Set<PlatformTier> tiers;

  /// Who can use it, when not everyone can (an account type, a right the
  /// network gives, a kind of chat). Shown with the control, so a choice the
  /// network may refuse is explained before it is made.
  final String? gate;

  /// Keys earlier versions of NEFORUM saved this option under. They are
  /// read as this option and replaced by [key] ([canonicalOptionKeys]).
  final List<String> aliases;

  /// The field of the network's API this option sets, as its reference
  /// names it (`disable_notification`, `snippet.categoryId`).
  final String? apiField;

  /// Whether an account on [tier] can use this option.
  bool appliesTo(PlatformTier tier) => tiers.isEmpty || tiers.contains(tier);

  /// The user can set it: it has a control in the app.
  bool get isUserFacing => surface != PostOptionSurface.internal;

  /// The value [extra] holds for this option: under [key], else under the
  /// first of [aliases] that has one. Null when none is set.
  Object? valueIn(Map<String, dynamic> extra) {
    if (extra.containsKey(key)) return extra[key];
    for (final a in aliases) {
      if (extra.containsKey(a)) return extra[a];
    }
    return null;
  }

  /// [raw] as this option's type, or null when it is not one (a hand-edited
  /// value, a key of an earlier version that had another type).
  Object? coerce(Object? raw) {
    switch (kind) {
      case PostOptionKind.toggle:
        if (raw is bool) return raw;
        if (raw == 'true') return true;
        if (raw == 'false') return false;
        return null;
      case PostOptionKind.choice:
        final s = raw is String ? raw.trim() : null;
        return s != null && choices.any((c) => c.value == s) ? s : null;
      case PostOptionKind.text:
        if (raw is String) return raw.trim().isEmpty ? null : raw.trim();
        if (raw is num) return '$raw';
        return null;
      case PostOptionKind.number:
        if (raw is int) return raw;
        if (raw is num && raw == raw.roundToDouble()) return raw.toInt();
        if (raw is String) return int.tryParse(raw.trim());
        return null;
      case PostOptionKind.mediaSelection:
        if (raw is List) {
          final ids = raw.whereType<String>().where((s) => s.isNotEmpty).toList();
          return ids.isEmpty ? null : ids;
        }
        return null;
    }
  }

  /// The label of [value] for a choice; the value itself otherwise.
  String labelOf(String value) => choices.where((c) => c.value == value).firstOrNull?.label ?? value;

  @override
  String toString() => 'PostOption($key)';
}

/// [extra] with every option's [PostOption.aliases] moved to its
/// [PostOption.key]: an option saved by an earlier version under an older
/// key keeps working. A value under the key itself wins over an alias.
/// Returns [extra] itself when nothing changes.
Map<String, dynamic> canonicalOptionKeys(List<PostOption> options, Map<String, dynamic> extra) {
  Map<String, dynamic>? out;
  for (final o in options) {
    for (final a in o.aliases) {
      if (!extra.containsKey(a)) continue;
      out ??= {...extra};
      final v = out.remove(a);
      out.putIfAbsent(o.key, () => v);
    }
  }
  return out ?? extra;
}
