import 'dart:io';

import 'package:handrail_chat/flutter.dart' as flutter_api;
import 'package:handrail_chat/media.dart' as media_api;
import 'package:handrail_chat/testing.dart' as testing_api;
import 'package:handrail_chat/ui.dart' as ui_api;
import 'package:test/test.dart';

void main() {
  test('Flutter-facing libraries resolve from the handrail_chat package', () {
    expect([
      flutter_api.handrailChatPackageName,
      ui_api.handrailChatPackageName,
      media_api.handrailChatPackageName,
      testing_api.handrailChatPackageName,
    ], everyElement('handrail_chat'));
    expect(flutter_api.ChatScopeReadiness.values, isNotEmpty);
    expect(flutter_api.ChatDeepLinkUnavailableReason.values, isNotEmpty);
    expect(flutter_api.ChatReadTracker, isNotNull);
    expect(media_api.ChatMediaSessionStatus.values, isNotEmpty);
    expect(media_api.ChatHuddleMediaSession, isNotNull);
  });

  test('media-only APIs are exported only by media.dart', () async {
    final media = await File('lib/media.dart').readAsString();
    expect(media, contains("export 'src/media_session.dart';"));

    for (final entryPoint in <String>[
      'lib/core.dart',
      'lib/flutter.dart',
      'lib/ui.dart',
    ]) {
      expect(
        await File(entryPoint).readAsString(),
        isNot(contains('media_session.dart')),
        reason: '$entryPoint must not export the media-only API',
      );
    }
  });
}
