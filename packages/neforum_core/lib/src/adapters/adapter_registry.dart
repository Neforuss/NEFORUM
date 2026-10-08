import '../model/platform_descriptor.dart';
import 'platform_adapter.dart';

/// Lookup table of all adapters known to this build.
class AdapterRegistry {
  AdapterRegistry([Iterable<PlatformAdapter> adapters = const []]) {
    adapters.forEach(register);
  }

  final Map<String, PlatformAdapter> _byId = {};

  void register(PlatformAdapter adapter) {
    if (_byId.containsKey(adapter.id)) {
      throw StateError('Adapter "${adapter.id}" registered twice');
    }
    _byId[adapter.id] = adapter;
  }

  PlatformAdapter? byId(String id) => _byId[id];

  PlatformAdapter require(String id) {
    final a = _byId[id];
    if (a == null) throw StateError('No adapter registered for platform "$id"');
    return a;
  }

  PlatformDescriptor? descriptor(String id) => _byId[id]?.descriptor;

  List<PlatformAdapter> get all => _byId.values.toList()..sort((a, b) => a.descriptor.name.toLowerCase().compareTo(b.descriptor.name.toLowerCase()));

  List<PlatformDescriptor> get descriptors => all.map((a) => a.descriptor).toList();

  Iterable<PlatformAdapter> withTier(PlatformTier tier) => all.where((a) => a.descriptor.supportsTier(tier));
}
