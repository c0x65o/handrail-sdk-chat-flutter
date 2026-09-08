import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _conversationId = ConversationId('conversation-typing');
const _tenantId = TenantId('tenant-typing');
const _currentUserId = UserId('user-current');
const _now = '2026-08-26T20:00:00.000Z';

void main() {
  testWidgets(
      'shows Slack-style names, deduplicates devices, and hides stops and self',
      (tester) async {
    final client = _client();
    final controller = client.conversations.forId(_conversationId);
    final initialState = await controller.refresh();
    expect(
      initialState.isReady,
      isTrue,
      reason: '${initialState.status}: ${initialState.error?.message}',
    );
    final names = <UserId, String>{
      const UserId('user-avery'): 'Avery',
      const UserId('user-blair'): 'Blair',
    };

    await tester.pumpWidget(MaterialApp(
      home: ChatScope(
        client: client,
        child: Scaffold(
          body: HandrailTypingIndicator(
            conversationId: _conversationId,
            controller: controller,
            currentUserId: _currentUserId,
            resolveUser: (userId) async {
              final name = names[userId];
              return name == null
                  ? null
                  : HandrailMemberDirectoryRow(
                      userId: userId,
                      displayName: name,
                    );
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    final indicator = find.byKey(
      const ValueKey<String>('handrail-typing-indicator'),
    );
    final text = find.byKey(
      const ValueKey<String>('handrail-typing-indicator-text'),
    );
    final reservedHeight = tester.getSize(indicator).height;
    expect(tester.widget<Text>(text).data, isEmpty);

    final sentAt = DateTime.now().toUtc();
    client.applyEphemeralSignal(_typing(
      actorUserId: 'user-avery',
      deviceId: 'device-avery-1',
      sessionId: 'session-avery-1',
      sentAt: sentAt,
    ));
    await _pumpUntil(
      tester,
      () => tester.widget<Text>(text).data == 'Avery is typing…',
    );
    expect(tester.getSize(indicator).height, reservedHeight);

    client.applyEphemeralSignal(_typing(
      eventId: 'typing-avery-second-device',
      actorUserId: 'user-avery',
      deviceId: 'device-avery-2',
      sessionId: 'session-avery-2',
      sentAt: sentAt.add(const Duration(milliseconds: 1)),
    ));
    await _pumpUntil(
      tester,
      () => tester.widget<Text>(text).data == 'Avery is typing…',
    );

    client.applyEphemeralSignal(_typing(
      eventId: 'typing-blair',
      actorUserId: 'user-blair',
      deviceId: 'device-blair',
      sessionId: 'session-blair',
      sentAt: sentAt.add(const Duration(milliseconds: 2)),
    ));
    await _pumpUntil(
      tester,
      () => tester.widget<Text>(text).data == 'Avery and Blair are typing…',
    );

    client.applyEphemeralSignal(_typing(
      eventId: 'typing-self',
      actorUserId: _currentUserId.value,
      deviceId: 'device-self',
      sessionId: 'session-self',
      sentAt: sentAt.add(const Duration(milliseconds: 3)),
    ));
    await tester.pump();
    expect(tester.widget<Text>(text).data, 'Avery and Blair are typing…');

    expect(
        client.applyEphemeralSignal(_typing(
          eventId: 'typing-blair-stop',
          actorUserId: 'user-blair',
          deviceId: 'device-blair',
          sessionId: 'session-blair',
          state: TypingSignalState.stop,
          sequence: 2,
          sentAt: sentAt.add(const Duration(milliseconds: 4)),
        )),
        isTrue);
    expect(
      controller.state.typing
          .where((event) => event.payload.actorUserId.value == 'user-blair')
          .single
          .payload
          .state,
      TypingSignalState.stop,
    );
    await tester.pump();
    expect(tester.widget<Text>(text).data, 'Avery is typing…');

    for (final device in <(String, String)>[
      ('device-avery-1', 'session-avery-1'),
      ('device-avery-2', 'session-avery-2'),
    ].indexed) {
      expect(
          client.applyEphemeralSignal(_typing(
            eventId: 'typing-avery-stop-${device.$1}',
            actorUserId: 'user-avery',
            deviceId: device.$2.$1,
            sessionId: device.$2.$2,
            state: TypingSignalState.stop,
            sequence: 2,
            sentAt: sentAt.add(Duration(milliseconds: 5 + device.$1)),
          )),
          isTrue);
    }
    await _pumpUntil(tester, () => tester.widget<Text>(text).data!.isEmpty);
    expect(tester.getSize(indicator).height, reservedHeight);
    await tester.pumpWidget(const SizedBox.shrink());
    await client.dispose();
  });

  testWidgets('uses privacy-safe person counts without a user resolver',
      (tester) async {
    final client = _client();
    final controller = client.conversations.forId(_conversationId);
    final initialState = await controller.refresh();
    expect(
      initialState.isReady,
      isTrue,
      reason: '${initialState.status}: ${initialState.error?.message}',
    );
    await tester.pumpWidget(MaterialApp(
      home: ChatScope(
        client: client,
        child: HandrailTypingIndicator(
          conversationId: _conversationId,
          controller: controller,
          currentUserId: _currentUserId,
        ),
      ),
    ));
    await tester.pump();
    final sentAt = DateTime.now().toUtc();
    for (var index = 1; index <= 3; index += 1) {
      client.applyEphemeralSignal(_typing(
        eventId: 'typing-generic-$index',
        actorUserId: 'user-$index',
        deviceId: 'device-$index',
        sessionId: 'session-$index',
        sentAt: sentAt.add(Duration(milliseconds: index)),
      ));
    }
    await _pumpUntil(
      tester,
      () =>
          tester
              .widget<Text>(find.byKey(
                const ValueKey<String>('handrail-typing-indicator-text'),
              ))
              .data ==
          '3 people are typing…',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await client.dispose();
  });
}

HandrailChatClient _client() => HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'typing-token',
      transport: const _TypingTransport(),
    );

final class _TypingTransport implements HandrailChatHttpTransport {
  const _TypingTransport();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'GET' &&
        request.uri.path.contains('/conversations/')) {
      return HandrailChatHttpResponse(
        statusCode: 200,
        body: jsonEncode(_conversationDetail()),
      );
    }
    return const HandrailChatHttpResponse(statusCode: 404, body: '{}');
  }
}

TypingSignalEvent _typing({
  String eventId = 'typing-avery',
  required String actorUserId,
  required String deviceId,
  required String sessionId,
  required DateTime sentAt,
  TypingSignalState state = TypingSignalState.start,
  int sequence = 1,
}) =>
    TypingSignalEvent(
      eventId: eventId,
      protocolVersion: 4,
      tenantId: _tenantId,
      streamId: _conversationId,
      occurredAt: IsoTimestamp(sentAt.toIso8601String()),
      payload: TypingSignalPayload(
        actorUserId: UserId(actorUserId),
        deviceId: DeviceId(deviceId),
        sessionId: SessionId(sessionId),
        sequence: sequence,
        sentAt: IsoTimestamp(sentAt.toIso8601String()),
        expiresAt: IsoTimestamp(
          sentAt.add(const Duration(minutes: 1)).toIso8601String(),
        ),
        state: state,
        scope: const PublicConversationSignalScope(_conversationId),
      ),
    );

Map<String, Object?> _conversationDetail() => {
      'kind': 'conversation_detail',
      'conversation': {
        'id': _conversationId.value,
        'tenantId': _tenantId.value,
        'type': 'channel',
        'name': 'Typing test',
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': 12,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _tenantId.value,
          'conversationId': _conversationId.value,
          'userId': _currentUserId.value,
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': _conversationId.value,
          'userId': _currentUserId.value,
          'lastReadSequence': 11,
          'updatedAt': _now,
        },
        'currentPreference': {
          'conversationId': _conversationId.value,
          'userId': _currentUserId.value,
          'isStarred': false,
          'notificationPreference': 'all',
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'memberUserIds': [
          _currentUserId.value,
          'user-avery',
          'user-blair',
          'user-1',
          'user-2',
          'user-3',
        ],
        'activeMemberUserIds': [
          _currentUserId.value,
          'user-avery',
          'user-blair',
          'user-1',
          'user-2',
          'user-3',
        ],
      },
      '_meta': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 9,
        'enabledFeatures': {conversationSnapshotFeature: true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    };

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var index = 0; index < 100 && !predicate(); index += 1) {
    await tester.pump();
  }
  expect(predicate(), isTrue);
}
