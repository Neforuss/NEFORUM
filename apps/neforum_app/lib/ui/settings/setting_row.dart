import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';

/// A settings section: titled card with rows separated by hairlines.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.icon, this.subtitle, required this.children});

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 1, color: nf.border, indent: Space.xl, endIndent: Space.xl));
      rows.add(children[i]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(left: Space.xs, bottom: Space.md),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: nf.accentSoft, borderRadius: Radii.rSm),
            child: Icon(icon, size: 17, color: nf.accent),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.text.titleLarge),
              if (subtitle != null) Text(subtitle!, style: context.text.bodySmall),
            ]),
          ),
        ]),
      ),
      NfCard(padding: const EdgeInsets.symmetric(vertical: Space.xs), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
    ]);
  }
}

/// Title + description on the left, a control on the right (or below on
/// narrow screens when [stackOnCompact]).
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, this.description, this.trailing, this.below, this.onTap, this.stackOnCompact = false, this.enabled = true});

  final String title;
  final String? description;
  final Widget? trailing;

  /// Full-width content under the text (choice lists, forms).
  final Widget? below;
  final VoidCallback? onTap;
  final bool stackOnCompact;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final stack = stackOnCompact && context.isCompact;
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: context.text.titleSmall?.copyWith(color: enabled ? nf.text : nf.textFaint)),
      if (description != null) ...[
        const SizedBox(height: 2),
        Text(description!, style: context.text.bodySmall?.copyWith(color: enabled ? nf.textMuted : nf.textFaint)),
      ],
    ]);
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (stack) ...[
          text,
          if (trailing != null) ...[const SizedBox(height: Space.md), Align(alignment: Alignment.centerLeft, child: trailing!)],
        ] else
          Row(children: [
            Expanded(child: text),
            if (trailing != null) ...[const SizedBox(width: Space.lg), trailing!],
          ]),
        if (below != null) ...[const SizedBox(height: Space.md), below!],
      ]),
    );
    if (onTap == null) return body;
    return InkWell(onTap: enabled ? onTap : null, child: body);
  }
}

/// Switch row.
class SettingSwitch extends StatelessWidget {
  const SettingSwitch({super.key, required this.title, this.description, required this.value, required this.onChanged});
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingRow(
        title: title,
        description: description,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(value: value, onChanged: onChanged),
      );
}

/// Radio list with a description per option.
class SettingChoice<T> extends StatelessWidget {
  const SettingChoice({super.key, required this.title, this.description, required this.value, required this.options, required this.onChanged});

  final String title;
  final String? description;
  final T value;
  final List<(T, String, String?)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return SettingRow(
      title: title,
      description: description,
      below: RadioGroup<T>(
        groupValue: value,
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        child: Column(children: [
          for (final o in options)
            InkWell(
              borderRadius: Radii.rSm,
              onTap: () => onChanged(o.$1),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Radio<T>(value: o.$1),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: Space.sm + 2),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(o.$2, style: context.text.bodyMedium?.copyWith(fontWeight: o.$1 == value ? FontWeight.w600 : FontWeight.w400)),
                        if (o.$3 != null) Text(o.$3!, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
