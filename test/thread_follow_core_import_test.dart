import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('thread follow contracts are exported from pure core.dart', () {
    final input = FollowThreadInput(
      target: ThreadFollowTarget(id: const ConversationId('thread-core')),
      expectedFollowRevision: 0,
      idempotencyKey: 'thread-follow-core-1',
    );
    expect(input.operation, 'set_thread_follow');
    expect(input.intent, ThreadFollowMutationIntent.follow);
    expect(input.toJson()['target'], {'type': 'thread', 'id': 'thread-core'});
  });
}
