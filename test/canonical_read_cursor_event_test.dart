import 'dart:convert';
import 'dart:io';
import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('canonical read cursor event applies without HTTP reconciliation status',
      () {
    final event = (jsonDecode(File(
                'docs/validation/flutter-named-threads/read-cursor-frames.json')
            .readAsStringSync()) as List)
        .first;
    final payload = ReadCursorUpdatedPayload.fromJson(event['payload']);
    ConversationSnapshotReadState.fromJson(payload.readState.toJson());
    ReadCursorUpdatedEvent.fromJson(event,
        expectedTenantId: const TenantId('chat-lab'));
    final durable = KnownDurableEvent.fromJson(event,
        trustedIdentity: const DurableEventTrustedIdentity(
            tenantId: TenantId('chat-lab'), userId: UserId('alice')));
    final converted = Map<String, Object?>.from(durable.payload.data)
      ..remove('reconciliationStatus');
    ReadCursorUpdatedPayload.fromJson(converted);
    ReadCursorUpdatedEvent.fromJson({...durable.toJson(), 'payload': converted},
        expectedTenantId: const TenantId('chat-lab'));
    final store = NormalizedSnapshotStore();
    addTearDown(store.close);
    final snapshots = jsonDecode(
        File('docs/validation/flutter-named-threads/live-snapshots.json')
            .readAsStringSync());
    store.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(snapshots['parent']));
    expect(store.reduceDurableEvent(durable).status,
        DurableEventReductionStatus.applied);
  });
}
