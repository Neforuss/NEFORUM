import 'repositories.dart';
import 'secret_store.dart';

/// Web stand-in: no file system. Everything lives in memory for the session;
/// the web build is a preview, not a supported target for persistent use.
class JsonFileStore {
  JsonFileStore(this.directory)
      : accounts = InMemoryAccountRepository(),
        posts = InMemoryPostRepository(),
        quota = InMemoryQuotaRepository(),
        secrets = InMemorySecretStore();

  final String directory;
  final InMemoryAccountRepository accounts;
  final InMemoryPostRepository posts;
  final InMemoryQuotaRepository quota;
  final InMemorySecretStore secrets;

  void dispose() {}
}
