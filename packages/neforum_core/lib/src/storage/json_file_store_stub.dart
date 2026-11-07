import '../publish/publish_journal.dart';
import '../util/logger.dart';
import 'repositories.dart';
import 'secret_store.dart';
import 'sign_in_status_store.dart';

/// Web stand-in: no file system. Everything lives in memory for the session;
/// the web build is a preview, not a supported target for persistent use.
class JsonFileStore {
  JsonFileStore(this.directory, {String? process})
      : accounts = InMemoryAccountRepository(),
        posts = InMemoryPostRepository(),
        quota = InMemoryQuotaRepository(),
        secrets = InMemorySecretStore(),
        publishJournal = PublishJournal.inMemory(),
        signInStatus = SignInStatusStore.inMemory();

  final String directory;
  final InMemoryAccountRepository accounts;
  final InMemoryPostRepository posts;
  final InMemoryQuotaRepository quota;
  final InMemorySecretStore secrets;
  final PublishJournal publishJournal;
  final SignInStatusStore signInStatus;

  static SignInStatusStore openSignInStatus(String directory) => SignInStatusStore.inMemory();

  static PublishJournal openPublishJournal(String directory, {String? owner, Clock? clock, String? process}) => PublishJournal.inMemory(owner: owner, clock: clock, process: process);

  void dispose() {}
}
