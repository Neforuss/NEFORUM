import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  test('the font travels with a card: placeholder and file name', () {
    for (final font in TextCardFont.values) {
      for (final branded in [true, false]) {
        final card = textCardPlaceholder('instagram', TextCardTheme.light, branded: branded, font: font);
        expect(textCardFontOf(card), font);
        expect(textCardBrandedOf(card), branded);
        expect(textCardThemeOf(card), TextCardTheme.light);
        final saved = MediaAttachment(
          id: 'm',
          path: '/media/x.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1,
          fileName: textCardFileName(TextCardTheme.dark, branded: branded, font: font),
          generated: true,
        );
        expect(textCardFontOf(saved), font);
        expect(textCardBrandedOf(saved), branded);
        expect(textCardThemeOf(saved), TextCardTheme.dark);
      }
    }
  });

  test('cards made before fonts existed read as the original font', () {
    expect(textCardFileName(TextCardTheme.dark), 'neforum-text-card-dark.jpg');
    final old = MediaAttachment(id: 'm', path: '/x.jpg', mimeType: 'image/jpeg', sizeBytes: 1, fileName: 'neforum-text-card-dark-plain.jpg', generated: true);
    expect(textCardFontOf(old), TextCardFont.original);
    expect(textCardBrandedOf(old), isFalse);
  });

  test('the default font is saved with the settings', () {
    expect(const AppSettings().textCardFont, TextCardFont.original);
    final s = const AppSettings().copyWith(textCardFont: TextCardFont.timesNewRoman);
    expect(AppSettings.fromJson(s.toJson()).textCardFont, TextCardFont.timesNewRoman);
    expect(AppSettings.fromJson(const {}).textCardFont, TextCardFont.original);
  });
}
