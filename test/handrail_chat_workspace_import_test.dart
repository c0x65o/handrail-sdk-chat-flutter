import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

void main() {
  test('ui.dart exposes the public workspace contract', () {
    const workspace = HandrailChatWorkspace();
    const header = HandrailChannelHeader(
      conversationId: ConversationId('public-header'),
    );
    const timeline = HandrailMessageTimeline(
      conversationId: ConversationId('public-header'),
    );
    const composer = HandrailMessageComposer(
      conversationId: ConversationId('public-header'),
    );
    const typing = HandrailTypingIndicator(
      conversationId: ConversationId('public-header'),
    );
    expect(workspace.scope, isA<OrganizationConversationSnapshotScope>());
    expect(workspace.builders, isA<ChatWidgetBuilders>());
    expect(workspace.delegates, isA<ChatApplicationDelegates>());
    expect(header.conversationId, const ConversationId('public-header'));
    expect(timeline.conversationId, const ConversationId('public-header'));
    expect(composer.conversationId, const ConversationId('public-header'));
    expect(typing.conversationId, const ConversationId('public-header'));
    expect(HandrailChatClient, isNotNull);
    expect(ChatScope, isNotNull);
    expect(ConversationStateBuilder, isNotNull);
    expect(ChatConversationController, isNotNull);
    expect(ChatTimelineController, isNotNull);
  });

  test('workspace source does not reach into normalized or client internals',
      () {
    final source =
        File('lib/src/handrail_chat_workspace.dart').readAsStringSync();
    expect(source, isNot(contains('normalizedState')));
    expect(source, isNot(contains("'core/")));
    expect(source, isNot(contains('package:provider')));
    expect(source, isNot(contains('package:flutter_bloc')));
  });
}
