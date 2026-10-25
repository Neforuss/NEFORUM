import 'package:flutter/widgets.dart';

/// The system's text scaling ([base], from the phone's own text size and
/// accessibility settings) times the user's NEFORUM text size ([factor],
/// Settings → Appearance → Text size on phones and tablets).
@immutable
class CombinedTextScaler extends TextScaler {
  const CombinedTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // Required by TextScaler; kept for widgets that still read it.
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) => other is CombinedTextScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);

  @override
  String toString() => 'combined ($base × $factor)';
}

/// Applies [scale] on top of the system's text scaling below it. The tree is
/// the same at every scale, so changing it never rebuilds the pages from
/// scratch.
class TextScale extends StatelessWidget {
  const TextScale({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scaler = scale == 1 ? mq.textScaler : CombinedTextScaler(mq.textScaler, scale);
    return MediaQuery(data: mq.copyWith(textScaler: scaler), child: child);
  }
}
