import 'package:meta/meta.dart';

import '../model/media.dart';

/// The preferred way to execute a hand-off in the current environment.
enum HandoffMethod {
  /// Open a URL that lands on a prefilled composer (works everywhere a
  /// browser exists; text only).
  webIntent,

  /// Native share sheet with files attached (mobile; the platform's app must
  /// be installed). Text usually has to go via the clipboard.
  shareSheet,

  /// Nothing can be prefilled; just open the platform and show instructions
  /// with the text already copied.
  manual,
}

/// A labelled piece of text the user copies into a separate field of the
/// platform's composer (a poll answer, a title, tags).
@immutable
class HandoffSnippet {
  const HandoffSnippet(this.label, this.text);
  final String label;
  final String text;
}

/// Everything the UI layer needs to hand a post to the platform's own app or
/// website. Built by adapters; executed by the app (share_plus, url_launcher,
/// clipboard) or printed by the CLI.
@immutable
class HandoffPlan {
  const HandoffPlan({
    required this.platformId,
    required this.instructions,
    this.webIntent,
    this.clipboardText,
    this.shareText,
    this.shareFiles = const [],
    this.androidPackage,
    this.iosScheme,
    this.desktopUrl,
    this.preferred = HandoffMethod.webIntent,
    this.mediaNote,
    this.snippets = const [],
  });

  final String platformId;

  /// Short numbered steps for the user, markdown allowed.
  final String instructions;

  /// A URL that opens the platform's composer prefilled with text (and
  /// sometimes a link). `null` when the platform has none.
  final Uri? webIntent;

  /// Text to put on the clipboard before launching (captions for Instagram,
  /// TikTok, ... which ignore shared text).
  final String? clipboardText;

  /// Text to pass to the share sheet (some apps accept it, e.g. X, Threads).
  final String? shareText;

  /// Media to attach to the share sheet.
  final List<MediaAttachment> shareFiles;

  /// Android package to prefer in the share sheet, e.g. `com.instagram.android`.
  final String? androidPackage;

  /// iOS URL scheme that opens the app, e.g. `instagram://`.
  final String? iosScheme;

  /// Where to send the user on desktop when there is no intent URL.
  final String? desktopUrl;
  final HandoffMethod preferred;

  /// Explains what happens to media ("Instagram ignores shared captions; your
  /// caption is on the clipboard").
  final String? mediaNote;

  /// Extra values to copy one by one, beyond [clipboardText].
  final List<HandoffSnippet> snippets;

  bool get hasMedia => shareFiles.isNotEmpty;

  HandoffPlan copyWith({HandoffMethod? preferred, String? instructions, Uri? webIntent}) => HandoffPlan(
        platformId: platformId,
        instructions: instructions ?? this.instructions,
        webIntent: webIntent ?? this.webIntent,
        clipboardText: clipboardText,
        shareText: shareText,
        shareFiles: shareFiles,
        androidPackage: androidPackage,
        iosScheme: iosScheme,
        desktopUrl: desktopUrl,
        preferred: preferred ?? this.preferred,
        mediaNote: mediaNote,
        snippets: snippets,
      );
}
