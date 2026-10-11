import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import 'guide_sheet.dart';
import 'markdown_style.dart';

/// Step 3: the form generated from the adapter's [ConnectSpec].
class ConnectForm extends ConsumerStatefulWidget {
  const ConnectForm({super.key, required this.platformId, required this.tier, required this.onConnected});

  final String platformId;
  final PlatformTier tier;
  final ValueChanged<ConnectedAccount> onConnected;

  @override
  ConsumerState<ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends ConsumerState<ConnectForm> {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  final Map<String, bool> _bool = {};
  final Set<String> _revealed = {};
  final Map<String, String> _fieldErrors = {};
  String? _error;
  String? _progress;
  bool _busy = false;

  PlatformAdapter get _adapter => ref.read(registryProvider).require(widget.platformId);
  ConnectSpec get _spec => _adapter.specFor(widget.tier);

  @override
  void initState() {
    super.initState();
    for (final f in _spec.fields) {
      switch (f.kind) {
        case FieldKind.boolean:
          _bool[f.key] = f.defaultValue == 'true';
        case FieldKind.select:
          _choice[f.key] = f.defaultValue ?? (f.options?.isNotEmpty == true ? f.options!.first : null);
        default:
          _text[f.key] = TextEditingController(text: f.defaultValue ?? '');
          // Pasting a token switches the form from browser sign-in to Connect.
          if (_isTokenField(f)) _text[f.key]!.addListener(_onTokenChanged);
      }
    }
  }

  static bool _isTokenField(ConnectField f) => f.secret && f.key.toLowerCase().contains('token');

  bool _hadToken = false;
  void _onTokenChanged() {
    if (_tokenPasted != _hadToken) setState(() => _hadToken = _tokenPasted);
  }

  /// The user pasted an access token, so no browser sign-in will happen.
  bool get _tokenPasted => _spec.fields.any((f) => _isTokenField(f) && (_text[f.key]?.text.trim().isNotEmpty ?? false));
  bool get _usesBrowser => _spec.usesBrowser && !_tokenPasted;

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {
        for (final e in _text.entries) e.key: e.value.text.trim(),
        for (final e in _choice.entries)
          if (e.value != null) e.key: e.value!,
        for (final e in _bool.entries) e.key: e.value ? 'true' : 'false',
      };

  Future<void> _connect() async {
    setState(() {
      _fieldErrors.clear();
      _error = null;
    });
    if (!(_form.currentState?.validate() ?? true)) return;
    setState(() {
      _busy = true;
      _progress = _usesBrowser ? 'Waiting for you to approve in the browser…' : 'Checking…';
    });
    final s = ref.read(servicesProvider);
    try {
      final result = await _adapter.connect(
        widget.tier,
        _values,
        s.connectContext(onProgress: (m) {
          if (mounted) setState(() => _progress = m);
        }),
      );
      var account = result.account;
      final existing = ref.read(accountListProvider).where((a) =>
          a.platformId == account.platformId && a.tier == account.tier && (a.id == account.id || (a.handle != null && a.handle == account.handle)));
      if (existing.isNotEmpty && existing.first.id != account.id && mounted) {
        final replace = await confirmDialog(
          context,
          title: 'Replace the existing account?',
          message: '${account.handle ?? account.displayName} is already connected. Replace its sign-in with this one? Your posts keep pointing to it.',
          confirmLabel: 'Replace',
        );
        if (!replace) {
          setState(() => _busy = false);
          return;
        }
        account = ConnectedAccount.fromJson({...account.toJson(), 'id': existing.first.id});
      }
      await s.secrets.write(account.id, result.secrets);
      await s.accounts.upsert(account.copyWith(clearLastError: true));
      if (mounted) widget.onConnected(account);
    } on ConnectException catch (e) {
      setState(() {
        if (e.field != null && _spec.fields.any((f) => f.key == e.field)) {
          _fieldErrors[e.field!] = e.message;
        } else {
          _error = e.message;
        }
      });
    } on AuthCancelled catch (e) {
      if (mounted) showToast(context, e.message, icon: Icons.info_outline_rounded);
    } on OAuthException catch (e) {
      setState(() => _error = 'Sign-in failed: ${e.description ?? e.error ?? e.message}');
    } on HttpFailure catch (e) {
      setState(() => _error = 'The server answered HTTP ${e.statusCode}. ${e.body.length > 300 ? e.body.substring(0, 300) : e.body}');
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(widget.platformId)!;
    final spec = _spec;
    final redirect = _usesBrowser
        ? ref.read(servicesProvider).broker.chooseRedirectUri(
              loopbackOk: spec.loopbackRedirectOk,
              customSchemeOk: spec.customSchemeRedirectOk,
              fixed: spec.fixedRedirectUri,
            )
        : null;

    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PlatformTile(d.id, size: 52),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Connect ${d.name}', style: context.text.headlineMedium),
              const SizedBox(height: Space.xs),
              TierBadge(widget.tier, dense: false),
            ]),
          ),
          if (d.setupGuide != null)
            OutlinedButton.icon(
              onPressed: () => showGuideSheet(context, d.id),
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: Text(context.isCompact ? 'Guide' : 'Setup guide'),
            ),
        ]),
        const SizedBox(height: Space.xl),
        if (spec.intro.trim().isNotEmpty)
          NfCard(padding: const EdgeInsets.all(Space.xl), child: NfMarkdown(spec.intro)),
        if (redirect != null) ...[
          const SizedBox(height: Space.lg),
          Text('Redirect URI', style: context.text.titleSmall),
          const SizedBox(height: Space.xs),
          Text(
            spec.redirectNote ?? 'If you create your own developer app, register exactly this address as its redirect (callback) URL.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: Space.sm),
          NfWell(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
            child: Row(children: [
              Expanded(child: SelectableText('$redirect', style: monoStyle(context, size: 13, color: nf.text))),
              ToolButton(
                icon: Icons.copy_rounded,
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: '$redirect'));
                  if (context.mounted) showToast(context, 'Redirect URI copied', icon: Icons.check_rounded);
                },
              ),
            ]),
          ),
        ],
        const SizedBox(height: Space.xl),
        for (final f in spec.fields) Padding(padding: const EdgeInsets.only(bottom: Space.lg), child: _field(f)),
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(color: nf.dangerSoft, borderRadius: Radii.rMd, border: Border.all(color: nf.danger.withValues(alpha: 0.35))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline_rounded, color: nf.danger, size: 20),
              const SizedBox(width: Space.sm),
              Expanded(child: SelectableText(_error!, style: context.text.bodySmall?.copyWith(color: nf.text))),
              ToolButton(
                icon: Icons.copy_rounded,
                tooltip: 'Copy details',
                size: 32,
                onPressed: () => Clipboard.setData(ClipboardData(text: _error!)),
              ),
            ]),
          ),
          const SizedBox(height: Space.lg),
        ],
        Row(children: [
          if (_progress != null)
            Expanded(
              child: Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: Space.sm),
                Expanded(child: Text(_progress!, style: context.text.bodySmall)),
              ]),
            )
          else
            const Spacer(),
          const SizedBox(width: Space.md),
          PrimaryAction(
            label: _usesBrowser ? 'Sign in with ${d.name}' : (widget.tier == PlatformTier.handoff ? 'Add ${d.name}' : 'Connect'),
            icon: _usesBrowser ? Icons.open_in_new_rounded : Icons.link_rounded,
            loading: _busy,
            onPressed: _connect,
          ),
        ]),
      ]),
    );
  }

  Widget _field(ConnectField f) {
    final nf = context.nf;
    final help = f.help == null
        ? null
        : Padding(padding: const EdgeInsets.only(top: Space.xs + 2, left: Space.xs), child: NfMarkdown(f.help!, small: true));
    String? validate(String? v) {
      if (f.required && (v == null || v.trim().isEmpty)) return '${f.label} is required';
      if (f.kind == FieldKind.url && v != null && v.trim().isNotEmpty) {
        final t = v.trim();
        final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
        if (u == null || u.host.isEmpty) return 'That does not look like a web address';
      }
      return null;
    }

    final Widget input;
    switch (f.kind) {
      case FieldKind.boolean:
        input = SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label, style: context.text.bodyMedium),
          value: _bool[f.key] ?? false,
          onChanged: (v) => setState(() => _bool[f.key] = v),
        );
      case FieldKind.select:
        input = DropdownButtonFormField<String>(
          initialValue: _choice[f.key],
          decoration: InputDecoration(labelText: f.label, errorText: _fieldErrors[f.key]),
          items: [for (final o in f.options ?? const <String>[]) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: (v) => setState(() => _choice[f.key] = v),
          validator: (v) => f.required && v == null ? '${f.label} is required' : null,
        );
      default:
        final obscure = (f.kind == FieldKind.password || f.secret) && !_revealed.contains(f.key);
        input = TextFormField(
          controller: _text[f.key],
          obscureText: obscure && f.kind != FieldKind.multiline,
          minLines: f.kind == FieldKind.multiline ? 3 : 1,
          maxLines: f.kind == FieldKind.multiline ? 6 : 1,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: switch (f.kind) {
            FieldKind.url => TextInputType.url,
            FieldKind.number => TextInputType.number,
            FieldKind.multiline => TextInputType.multiline,
            _ => TextInputType.text,
          },
          style: f.secret || f.kind == FieldKind.password ? monoStyle(context, size: 14, color: nf.text) : null,
          validator: validate,
          decoration: InputDecoration(
            labelText: f.required || f.label.toLowerCase().contains('optional') ? f.label : '${f.label} (optional)',
            hintText: f.placeholder,
            errorText: _fieldErrors[f.key],
            errorMaxLines: 3,
            alignLabelWithHint: f.kind == FieldKind.multiline,
            prefixIcon: f.secret ? const Icon(Icons.key_rounded, size: 20) : null,
            suffixIcon: (f.kind == FieldKind.password || f.secret) && f.kind != FieldKind.multiline
                ? IconButton(
                    tooltip: obscure ? 'Show' : 'Hide',
                    icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                    onPressed: () => setState(() => _revealed.contains(f.key) ? _revealed.remove(f.key) : _revealed.add(f.key)),
                  )
                : null,
          ),
        );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [input, ?help]);
  }
}
