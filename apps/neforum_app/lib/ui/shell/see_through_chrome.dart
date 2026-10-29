import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'app_backdrop.dart';

/// Where a piece of navigation chrome lies in the window.
enum ChromePlacement {
  /// Along the left edge, full height: the sidebar or the rail.
  side,

  /// Along the bottom edge, full width: the phone tab bar.
  bottom,
}

/// The background of the see-through navigation chrome (Settings >
/// Appearance > Navigation bar > See-through), painted under [child]: the
/// sidebar, the rail or the phone tab bar, [extent] logical pixels wide (on
/// the [ChromePlacement.side]) or tall (at the [ChromePlacement.bottom]).
///
/// What lies behind shows through: the background picture, frosted by
/// [blur] (logical pixels), or the page color when there is no picture.
/// Over it lies the theme's surface color at [opacity] or more: as much as
/// the chrome's labels ([NfColors.onChrome] and [NfColors.onChromeMuted])
/// need to keep WCAG AA contrast (4.5:1; 7:1 with the system's high
/// contrast setting) on the part of the picture under the chrome, measured
/// as the page's own scrim is (`legibleScrimOpacity`). The picture is
/// measured unfrosted, so a blur never makes the labels less readable.
class SeeThroughChrome extends StatefulWidget {
  const SeeThroughChrome({super.key, required this.placement, required this.extent, this.opacity = 0, this.blur = 0, required this.child});

  final ChromePlacement placement;
  final double extent;

  /// Least opacity of the surface color, 0 (fully see-through) to 1.
  final double opacity;
  final double blur;
  final Widget child;

  @override
  State<SeeThroughChrome> createState() => _SeeThroughChromeState();
}

class _SeeThroughChromeState extends State<SeeThroughChrome> {
  /// The last legibility result, for its inputs.
  (BackdropSampling, Rect, Size, Color, List<Color>, double)? _inputs;
  double _legible = 0;

  /// The part of the window under the chrome.
  Rect _region(Size window, EdgeInsets padding) => switch (widget.placement) {
        ChromePlacement.side => Rect.fromLTWH(0, 0, widget.extent + padding.left, window.height),
        ChromePlacement.bottom => Rect.fromLTRB(0, window.height - widget.extent - padding.bottom, window.width, window.height),
      };

  double _legibleOpacity(BackdropSampling sampling, Rect region, Size window, NfColors nf, double ratio) {
    final foregrounds = [nf.onChrome, nf.onChromeMuted];
    final scrim = nf.chrome.withValues(alpha: 1);
    final inputs = _inputs;
    if (inputs != null &&
        identical(inputs.$1, sampling) &&
        inputs.$2 == region &&
        inputs.$3 == window &&
        inputs.$4 == scrim &&
        listEquals(inputs.$5, foregrounds) &&
        inputs.$6 == ratio) {
      return _legible;
    }
    _inputs = (sampling, region, window, scrim, foregrounds, ratio);
    return _legible = legibleScrimOpacity(sampling.under(region, window), scrim, foregrounds, ratio: ratio);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final sampling = AppBackdrop.samplingOf(context);
    var opacity = widget.opacity;
    if (sampling != null) {
      final window = MediaQuery.sizeOf(context);
      final ratio = MediaQuery.highContrastOf(context) ? 7.0 : 4.5;
      opacity = math.max(opacity, _legibleOpacity(sampling, _region(window, MediaQuery.paddingOf(context)), window, nf, ratio));
    }
    Widget cover = ColoredBox(color: nf.chrome.withValues(alpha: opacity));
    // Frosted glass only over a picture: over the plain page it shows nothing.
    if (sampling != null && widget.blur > 0) {
      cover = BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur), child: cover);
    }
    return Stack(children: [
      Positioned.fill(child: ClipRect(child: cover)),
      widget.child,
    ]);
  }
}
