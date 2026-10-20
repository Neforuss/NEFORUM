/// NEFORUM core: one message, every platform.
///
/// Pure Dart. The Flutter app and the CLI build on this; nothing in here
/// touches a screen.
library;

export 'src/adapters/adapter_context.dart';
export 'src/adapters/adapter_registry.dart';
export 'src/adapters/builtin_adapters.dart';
export 'src/adapters/connect_spec.dart';
export 'src/adapters/platform_adapter.dart';
export 'src/auth/auth_broker.dart';
export 'src/auth/loopback_auth_broker_stub.dart' if (dart.library.io) 'src/auth/loopback_auth_broker.dart';
export 'src/auth/oauth1.dart';
export 'src/auth/oauth2_pkce.dart';
export 'src/backup/backup_format.dart';
export 'src/backup/backup_service.dart';
export 'src/handoff/handoff_plan.dart';
export 'src/http/neforum_http.dart';
export 'src/media_hosts/media_hosts.dart';
export 'src/model/account.dart';
export 'src/model/media.dart';
export 'src/model/photo_fit.dart';
export 'src/model/platform_descriptor.dart';
export 'src/model/poll.dart';
export 'src/model/post.dart';
export 'src/model/post_variant.dart';
export 'src/model/publish_result.dart';
export 'src/model/validation.dart';
export 'src/publish/publish_service.dart';
export 'src/quota/quota_tracker.dart';
export 'src/schedule/schedule_engine.dart';
export 'src/storage/json_file_store_stub.dart' if (dart.library.io) 'src/storage/json_file_store.dart';
export 'src/storage/repositories.dart';
export 'src/storage/secret_store.dart';
export 'src/sync/folder_sync_backend_stub.dart' if (dart.library.io) 'src/sync/folder_sync_backend.dart';
export 'src/sync/secrets_coordinator.dart';
export 'src/sync/sync_backend.dart';
export 'src/sync/sync_document.dart';
export 'src/sync/sync_engine.dart';
export 'src/sync/sync_providers.dart';
export 'src/sync/sync_sources.dart';
export 'src/text/rules_validator.dart';
export 'src/text/text_counter.dart';
export 'src/text/text_splitter.dart';
export 'src/text/url_detector.dart';
export 'src/text/variant_resolver.dart';
export 'src/util/logger.dart';
