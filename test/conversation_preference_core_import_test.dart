import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('conversation preference contracts are available from pure core.dart', () {
    final input = UpdateConversationPreferenceInput(
      conversationId: const ConversationId('conversation-core'),
      expectedPreferenceRevision: 0,
      idempotencyKey: 'core-preference-1',
      preference: const ConversationPreferenceDesiredState(
        notificationPreference: ConversationNotificationPreference.all,
        isStarred: true,
        mute: UnmutedConversationPreference(),
      ),
    );
    expect(input.operation, 'update_conversation_preference');
    expect(input.toJson()['notificationPreference'], 'all');
    expect(input.toJson()['isStarred'], isTrue);
  });
}
