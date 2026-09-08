/// Testing APIs for applications integrating Handrail Chat with Flutter.
///
/// The helpers exported here model host-owned external edges only. Production
/// applications should import `core.dart`, `flutter.dart`, or `media.dart`
/// instead.
library;

export 'core.dart';
export 'flutter.dart';
export 'media.dart';
export 'ui.dart';
export 'src/testing/credential_safe_diagnostic_recorder.dart';
export 'src/testing/fake_chat_clock.dart';
export 'src/testing/fake_chat_connectivity.dart';
export 'src/testing/fake_chat_media.dart';
export 'src/testing/fake_chat_realtime.dart';
export 'src/testing/flutter_chat_widget_fixtures.dart';
export 'src/testing/in_memory_application_chat_storage.dart';
export 'src/testing/scripted_access_token_provider.dart';
export 'src/testing/scripted_http_transport.dart';
