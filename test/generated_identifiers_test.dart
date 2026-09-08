import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('string identifier primitives round-trip their wire values', () {
    const tenantScoped = TenantScopedId('scoped-1');
    const tenant = TenantId('tenant-1');
    const conversation = ConversationId('conversation-1');
    const message = MessageId('message-1');
    const user = UserId('user-1');
    const attachment = AttachmentId('attachment-1');
    const device = DeviceId('device-1');
    const session = SessionId('session-1');
    const timestamp = IsoTimestamp('2026-08-26T12:00:00.000Z');

    expect(TenantScopedId.fromJson(tenantScoped.toJson()), tenantScoped);
    expect(TenantId.fromJson(tenant.toJson()), tenant);
    expect(ConversationId.fromJson(conversation.toJson()), conversation);
    expect(MessageId.fromJson(message.toJson()), message);
    expect(UserId.fromJson(user.toJson()), user);
    expect(AttachmentId.fromJson(attachment.toJson()), attachment);
    expect(DeviceId.fromJson(device.toJson()), device);
    expect(SessionId.fromJson(session.toJson()), session);
    expect(IsoTimestamp.fromJson(timestamp.toJson()), timestamp);

    expect(conversation.toJson(), 'conversation-1');
    expect(timestamp.toJson(), '2026-08-26T12:00:00.000Z');
    expect(const ConversationId('same'), const ConversationId('same'));
    expect(const ConversationId('same'), isNot(const MessageId('same')));
    expect(const TenantScopedId('same'), isNot(const ConversationId('same')));
  });

  test('message sequences round-trip their numeric wire values', () {
    const sequence = MessageSequence(42);

    expect(sequence.value, 42);
    expect(sequence.toJson(), 42);
    expect(MessageSequence.fromJson(sequence.toJson()), sequence);
    expect(const MessageSequence(42), isNot(const MessageSequence(43)));
  });

  test('deserialization rejects mismatched wire types', () {
    expect(() => ConversationId.fromJson(1), throwsFormatException);
    expect(() => MessageSequence.fromJson('1'), throwsFormatException);
  });
}
