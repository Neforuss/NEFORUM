import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Visual identity of one platform inside NEFORUM: a color, an icon (or a
/// monogram when Font Awesome has no logo) and an optional gradient.
@immutable
class PlatformBrand {
  const PlatformBrand({
    required this.color,
    this.icon,
    this.monogram,
    this.onColor = Colors.white,
    this.gradient,
    this.darkColor,
  });

  /// Primary brand color (used on light backgrounds).
  final Color color;

  /// Brand color variant for dark backgrounds (for black/near-black brands).
  final Color? darkColor;
  final Color onColor;
  final FaIconData? icon;

  /// One or two characters shown when there is no icon.
  final String? monogram;
  final Gradient? gradient;

  Color colorFor(Brightness b) => b == Brightness.dark ? (darkColor ?? color) : color;

  /// A background that works for avatars/tiles: the gradient when there is
  /// one, otherwise the solid color.
  Decoration tile(Brightness b, {BorderRadius? radius, BoxShape shape = BoxShape.rectangle}) => BoxDecoration(
        color: gradient == null ? colorFor(b) : null,
        gradient: gradient,
        borderRadius: shape == BoxShape.circle ? null : radius,
        shape: shape,
      );
}

const _instagramGradient = LinearGradient(
  begin: Alignment.bottomLeft,
  end: Alignment.topRight,
  colors: [Color(0xFFFEDA75), Color(0xFFFA7E1E), Color(0xFFD62976), Color(0xFF962FBF), Color(0xFF4F5BD5)],
);

const _tiktokGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF25F4EE), Color(0xFF010101), Color(0xFF010101), Color(0xFFFE2C55)],
  stops: [0.0, 0.35, 0.65, 1.0],
);

const _googleGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF4285F4), Color(0xFF34A853), Color(0xFFFBBC05), Color(0xFFEA4335)],
);

/// Known brands by adapter id. Unknown ids fall back to [fallbackBrand].
const Map<String, PlatformBrand> platformBrands = {
  'x': PlatformBrand(color: Color(0xFF0F1419), darkColor: Color(0xFF2A2F36), icon: FontAwesomeIcons.xTwitter),
  'bluesky': PlatformBrand(color: Color(0xFF1185FE), icon: FontAwesomeIcons.bluesky),
  'mastodon': PlatformBrand(color: Color(0xFF6364FF), icon: FontAwesomeIcons.mastodon),
  'threads': PlatformBrand(color: Color(0xFF101010), darkColor: Color(0xFF2A2A2A), icon: FontAwesomeIcons.threads),
  'instagram': PlatformBrand(color: Color(0xFFD62976), icon: FontAwesomeIcons.instagram, gradient: _instagramGradient),
  'facebook': PlatformBrand(color: Color(0xFF0866FF), icon: FontAwesomeIcons.facebook),
  'linkedin': PlatformBrand(color: Color(0xFF0A66C2), icon: FontAwesomeIcons.linkedin),
  'tiktok': PlatformBrand(color: Color(0xFF010101), darkColor: Color(0xFF1F1F1F), icon: FontAwesomeIcons.tiktok, gradient: _tiktokGradient),
  'youtube': PlatformBrand(color: Color(0xFFFF0033), icon: FontAwesomeIcons.youtube),
  // Text and image posts on the channel's Posts tab: same red, square glyph.
  'youtube_posts': PlatformBrand(color: Color(0xFFFF0033), icon: FontAwesomeIcons.squareYoutube),
  'pinterest': PlatformBrand(color: Color(0xFFE60023), icon: FontAwesomeIcons.pinterest),
  'reddit': PlatformBrand(color: Color(0xFFFF4500), icon: FontAwesomeIcons.reddit),
  'telegram': PlatformBrand(color: Color(0xFF26A5E4), icon: FontAwesomeIcons.telegram),
  'discord': PlatformBrand(color: Color(0xFF5865F2), icon: FontAwesomeIcons.discord),
  'matrix': PlatformBrand(color: Color(0xFF0DBD8B), monogram: '[m]'),
  'tumblr': PlatformBrand(color: Color(0xFF001935), darkColor: Color(0xFF34526F), icon: FontAwesomeIcons.tumblr),
  'lemmy': PlatformBrand(color: Color(0xFF14854F), monogram: 'Le'),
  'misskey': PlatformBrand(color: Color(0xFF86B300), monogram: 'Mk'),
  'nostr': PlatformBrand(color: Color(0xFF8E30EB), monogram: 'N'),
  'wordpress': PlatformBrand(color: Color(0xFF21759B), icon: FontAwesomeIcons.wordpress),
  'ghost': PlatformBrand(color: Color(0xFF15171A), darkColor: Color(0xFF30343B), icon: FontAwesomeIcons.ghost),
  'writefreely': PlatformBrand(color: Color(0xFF3C4A57), darkColor: Color(0xFF52657A), monogram: 'Wf'),
  'micropub': PlatformBrand(color: Color(0xFFE85D0C), icon: FontAwesomeIcons.rss),
  'devto': PlatformBrand(color: Color(0xFF0A0A0A), darkColor: Color(0xFF2B2B2B), icon: FontAwesomeIcons.dev),
  'hashnode': PlatformBrand(color: Color(0xFF2962FF), icon: FontAwesomeIcons.hashnode),
  'snapchat': PlatformBrand(color: Color(0xFFFFFC00), onColor: Color(0xFF111111), icon: FontAwesomeIcons.snapchat),
  'whatsapp': PlatformBrand(color: Color(0xFF25D366), icon: FontAwesomeIcons.whatsapp),
  'google_business': PlatformBrand(color: Color(0xFF4285F4), icon: FontAwesomeIcons.google, gradient: _googleGradient),
  'substack': PlatformBrand(color: Color(0xFFFF6719), monogram: 'S'),
};

PlatformBrand fallbackBrand(String id) {
  // Stable hue from the id so unknown platforms still look intentional.
  final hue = (id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xFFFF) % 360).toDouble();
  final color = HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
  final mono = id.isEmpty ? '?' : id[0].toUpperCase() + (id.length > 1 ? id[1] : '');
  return PlatformBrand(color: color, monogram: mono);
}

PlatformBrand brandFor(String platformId) => platformBrands[platformId] ?? fallbackBrand(platformId);

/// The platform's mark, sized to fit a square of [size].
class PlatformGlyph extends StatelessWidget {
  const PlatformGlyph(this.platformId, {super.key, this.size = 18, this.color});

  final String platformId;
  final double size;

  /// Defaults to the brand's onColor (for use on a brand tile).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final b = brandFor(platformId);
    final c = color ?? b.onColor;
    if (b.icon != null) return FaIcon(b.icon, size: size, color: c);
    final mono = b.monogram ?? '?';
    return SizedBox(
      width: size * 1.4,
      height: size * 1.4,
      child: Center(
        child: Text(
          mono,
          maxLines: 1,
          style: TextStyle(
            fontFamily: 'Bricolage',
            fontWeight: FontWeight.w800,
            fontSize: size * (mono.length > 2 ? 0.66 : mono.length == 2 ? 0.8 : 1.0),
            letterSpacing: -0.5,
            color: c,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Rounded-square brand tile with the platform mark: the visual unit used for
/// target chips, account cards and the platform gallery.
class PlatformTile extends StatelessWidget {
  const PlatformTile(this.platformId, {super.key, this.size = 36, this.radius, this.circle = false, this.dimmed = false});

  final String platformId;
  final double size;
  final double? radius;
  final bool circle;

  /// Greyscale-ish look for disabled/unselected states.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final b = brandFor(platformId);
    final brightness = Theme.of(context).brightness;
    final tile = Container(
      width: size,
      height: size,
      decoration: b.tile(
        brightness,
        radius: BorderRadius.circular(radius ?? size * 0.28),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
      ),
      alignment: Alignment.center,
      child: PlatformGlyph(platformId, size: size * 0.5),
    );
    if (!dimmed) return tile;
    return Opacity(
      opacity: 0.45,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.45, 0.45, 0.1, 0, 0, //
          0.3, 0.6, 0.1, 0, 0, //
          0.3, 0.45, 0.25, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: tile,
      ),
    );
  }
}
