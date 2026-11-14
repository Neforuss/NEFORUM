import 'dart:io';

/// Reads the adapters' source and lists every `PostVariant.extra` key each
/// adapter reads: the deterministic half of "every option is declared once"
/// (`post_options_declared_test.dart`).
///
/// A read is `x.extra['key']`, `x.extra[someConst]`, `x.extraAs<T>('key')`,
/// `x.extra.containsKey('key')`, a loop over a `const [...]` list of keys, or
/// Reddit's `_extraString(v, const ['a', 'b'])` / `_extraBool(...)` helpers.
/// Constants are resolved from every `const name = '...'` under `lib/src`.
/// Anything else that reads `extra` with a key the scan cannot name lands in
/// [unresolved], so a new way of reading options cannot slip past the gate.
class ExtraKeyScan {
  ExtraKeyScan._(this.root);

  /// `lib/src` of neforum_core.
  final Directory root;

  /// Source of every file under [root], comments removed, by path relative
  /// to [root] with `/` separators.
  final Map<String, String> sources = {};

  /// `const name = 'value'` declarations under [root].
  final Map<String, String> constants = {};
  final Map<String, Map<String, String>> _fileConstants = {};
  final Set<String> _ambiguous = {};

  /// Keys read per file (relative path), with the line of each read.
  final Map<String, Map<String, List<int>>> readsByFile = {};

  /// Reads whose key the scan could not name: `file:line expression`.
  final List<String> unresolved = [];

  /// Class name -> file that declares it.
  final Map<String, String> classFile = {};

  /// Class name -> the class it extends.
  final Map<String, String> superclassOf = {};

  /// File -> files under `adapters/` it imports (relative paths).
  final Map<String, Set<String>> importsOf = {};

  /// Getters declared outside the adapters that read extra keys for them:
  /// `variant.placement` reads [kPlacementKey] and [kStoryModeKey] through
  /// `placementOfExtra` in `model/post_placement.dart`.
  static const Map<String, String> accessorFiles = {'placement': 'model/post_placement.dart'};

  /// Identifiers that are loop variables of a helper whose callers pass the
  /// keys as `const` lists ([_helperListCall] scans those calls instead).
  static const Map<String, Set<String>> helperLoopVariables = {
    'adapters/reddit/reddit_adapter.dart': {'k'},
  };

  static final RegExp _constDecl = RegExp(r"""(?:static\s+)?const\s+(?:String\s+)?(\w+)\s*=\s*'([^'\\$]*)'\s*;""");
  static final RegExp _indexRead = RegExp(r'\.extra\s*\[\s*([^\]]+?)\s*\]');
  static final RegExp _bareIndexRead = RegExp(r'\bextra\s*\[\s*([^\]]+?)\s*\]');
  static final RegExp _asRead = RegExp(r'\.extraAs<[^>]+>\(\s*([^)]+?)\s*\)');
  static final RegExp _containsRead = RegExp(r'\.extra\.containsKey\(\s*([^)]+?)\s*\)');
  static final RegExp _helperListCall = RegExp(r'_extra(?:String|Bool)\(\s*\w+\s*,\s*const\s*\[([^\]]*)\]');
  static final RegExp _literal = RegExp(r"^'([^'\\$]*)'$");
  static final RegExp _identifier = RegExp(r'^[A-Za-z_][\w.]*$');
  static final RegExp _classDecl = RegExp(r'^(?:abstract\s+|final\s+|base\s+|sealed\s+)*class\s+(\w+)(?:<[^>]*>)?\s+extends\s+(\w+)', multiLine: true);
  static final RegExp _import = RegExp(r"^import\s+'([^']+)'", multiLine: true);
  static final RegExp _accessor = RegExp(r'\.(\w+)\b(?!\s*[:(])');

  /// Scans neforum_core's `lib/src` ([packageRoot] is the package directory).
  static ExtraKeyScan run([String packageRoot = '.']) {
    final scan = ExtraKeyScan._(Directory('$packageRoot/lib/src'));
    scan._load();
    scan._scan();
    return scan;
  }

  String _rel(File f) {
    final base = root.absolute.path.replaceAll('\\', '/');
    final path = f.absolute.path.replaceAll('\\', '/');
    return path.substring(base.length + 1);
  }

  /// Drops whole-line comments (`//`, `///`): reads named in docs are not reads.
  static String _withoutComments(String source) =>
      source.split('\n').map((l) => l.trimLeft().startsWith('//') ? '' : l).join('\n');

  void _load() {
    final files = root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final rel = _rel(f);
      final src = _withoutComments(f.readAsStringSync().replaceAll('\r\n', '\n'));
      sources[rel] = src;
      for (final m in _constDecl.allMatches(src)) {
        (_fileConstants[rel] ??= {})[m.group(1)!] = m.group(2)!;
        final name = m.group(1)!;
        // A name declared twice with different values is only resolved
        // inside its own file.
        if (constants.containsKey(name) && constants[name] != m.group(2)) {
          _ambiguous.add(name);
        } else {
          constants[name] = m.group(2)!;
        }
      }
      for (final m in _classDecl.allMatches(src)) {
        classFile[m.group(1)!] = rel;
        superclassOf[m.group(1)!] = m.group(2)!;
      }
      final dir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
      importsOf[rel] = {
        for (final m in _import.allMatches(src))
          if (!m.group(1)!.contains(':')) _normalize('$dir/${m.group(1)!}'),
      }..removeWhere((p) => !p.startsWith('adapters/'));
    }
  }

  static String _normalize(String path) {
    final out = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else {
        out.add(part);
      }
    }
    return out.join('/');
  }

  int _lineOf(String src, int offset) => '\n'.allMatches(src.substring(0, offset)).length + 1;

  void _add(String file, String key, int line) => ((readsByFile[file] ??= {})[key] ??= []).add(line);

  /// The keys [expression] (inside a read) stands for.
  List<String>? _keysOf(String file, String expression) {
    final lit = _literal.firstMatch(expression);
    if (lit != null) return [lit.group(1)!];
    if (!_identifier.hasMatch(expression)) return null;
    final name = expression.split('.').last;
    final constant = _fileConstants[file]?[name] ?? (_ambiguous.contains(name) ? null : constants[name]);
    if (constant != null) return [constant];
    // A loop over a const list of keys: for (final key in const [a, b]).
    final loop = RegExp('for\\s*\\(\\s*final\\s+(?:String\\s+)?${RegExp.escape(name)}\\s+in\\s+const\\s*\\[([^\\]]*)\\]').firstMatch(sources[file]!);
    if (loop != null) {
      final keys = <String>[];
      for (final item in loop.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
        final k = _keysOf(file, item);
        if (k == null) return null;
        keys.addAll(k);
      }
      return keys;
    }
    if (helperLoopVariables[file]?.contains(name) ?? false) return const [];
    return null;
  }

  void _scan() {
    for (final e in sources.entries) {
      final file = e.key;
      final src = e.value;
      if (!file.startsWith('adapters/') && !accessorFiles.containsValue(file)) continue;
      // An accessor file takes the map itself (`placementOfExtra(extra)`).
      final index = accessorFiles.containsValue(file) ? _bareIndexRead : _indexRead;
      for (final pattern in [index, _asRead, _containsRead]) {
        for (final m in pattern.allMatches(src)) {
          final keys = _keysOf(file, m.group(1)!);
          final line = _lineOf(src, m.start);
          if (keys == null) {
            unresolved.add('$file:$line ${m.group(0)}');
          } else {
            for (final k in keys) {
              _add(file, k, line);
            }
          }
        }
      }
      for (final m in _helperListCall.allMatches(src)) {
        for (final item in m.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
          final keys = _keysOf(file, item);
          if (keys == null) {
            unresolved.add('$file:${_lineOf(src, m.start)} $item');
          } else {
            for (final k in keys) {
              _add(file, k, _lineOf(src, m.start));
            }
          }
        }
      }
    }
  }

  /// The files whose reads count for the adapter class [className]: its own
  /// file, its superclasses' files, and the helper files they import (not
  /// files that declare another adapter class).
  Set<String> filesOf(String className, Set<String> adapterClassNames) {
    final chain = <String>{};
    for (String? c = className; c != null && classFile.containsKey(c); c = superclassOf[c]) {
      chain.add(classFile[c]!);
    }
    final otherAdapterFiles = {
      for (final n in adapterClassNames)
        if (classFile[n] case final f? when !chain.contains(f)) f,
    };
    final out = <String>{...chain};
    final queue = [...chain];
    while (queue.isNotEmpty) {
      final f = queue.removeLast();
      for (final i in importsOf[f] ?? const <String>{}) {
        if (otherAdapterFiles.contains(i) || !out.add(i)) continue;
        queue.add(i);
      }
    }
    return out;
  }

  /// Every key the adapter class [className] reads, with where: key ->
  /// `file:line` list. [sharedOwners] limits a helper file's key to the
  /// platforms named for it (helper file -> key -> platform ids).
  Map<String, List<String>> keysOf(String className, String platformId, Set<String> adapterClassNames,
      {Map<String, Map<String, Set<String>>> sharedOwners = const {}}) {
    final out = <String, List<String>>{};
    final files = filesOf(className, adapterClassNames);
    void addFile(String f) {
      for (final r in (readsByFile[f] ?? const <String, List<int>>{}).entries) {
        final owners = sharedOwners[f]?[r.key];
        if (owners != null && !owners.contains(platformId)) continue;
        (out[r.key] ??= []).addAll(r.value.map((l) => '$f:$l'));
      }
    }

    for (final f in files) {
      addFile(f);
      for (final m in _accessor.allMatches(sources[f] ?? '')) {
        final accessorFile = accessorFiles[m.group(1)!];
        if (accessorFile != null && files.contains(f)) addFile(accessorFile);
      }
    }
    return out;
  }
}
