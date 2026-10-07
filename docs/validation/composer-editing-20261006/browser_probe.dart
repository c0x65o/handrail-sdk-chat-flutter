// Public SDK CanvasKit probe. All HTTP operations terminate in this fixture.
// Browser automation reads accepted controller/draft state, never DOM value alone.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:handrail_chat/ui.dart';
import 'package:handrail_chat/testing.dart';

const _tenantId = 'tenant-composer';
const _userId = 'user-composer';
const _now = '2026-08-26T22:00:00.000Z';
const conversationId = ConversationId('conversation-composer');
final transport = ProbeTransport();
final host = TextEditingController();
final focus = FocusNode();
final stateNode = html.DivElement()..id = 'accepted-state';
late HandrailChatClient client;
int serial = 0;
void record() {
  final draft = client.draftFor(conversationId);
  stateNode.text = jsonEncode({
    'text': host.text,
    'selection': [host.selection.baseOffset, host.selection.extentOffset],
    'composing': [host.value.composing.start, host.value.composing.end],
    'focus': focus.hasFocus,
    'draft': draft?.draft is CanonicalReplacedDraft
        ? (draft!.draft as CanonicalReplacedDraft).content.text
        : null,
    'pending': draft?.isPending,
    'requests': transport.requests,
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
  stateNode.style.display = 'none';
  html.document.body!.append(stateNode);
  client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://fixture.invalid/api/chat'),
    tokenProvider: () async => 'fixture-only',
    transport: transport,
    localStorage: InMemoryApplicationChatStorage(),
    storageIdentity: ApplicationChatStorageIdentity(
        tenantId: const TenantId(_tenantId),
        userId: const UserId(_userId),
        deviceId: const DeviceId('probe-device')),
    commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    generateIdempotencyKey: () => 'probe-key-${++serial}',
    generateDraftDeviceMutationId: () => 'probe-draft-${++serial}',
    generateClientMessageId: () => 'probe-message-${++serial}',
  );
  host.addListener(record);
  focus.addListener(record);
  client.conversations
      .forConversation(conversationId)
      .states
      .listen((_) => record());
  html.window.onMessage.listen((event) {
    switch (event.data) {
      // Public host-controller injection, not a claim of native browser IME input.
      case 'set-public-composing':
        host.value = host.value.copyWith(
          selection: const TextSelection(baseOffset: 4, extentOffset: 6),
          composing: const TextRange(start: 3, end: 8),
        );
      case 'release-draft':
        transport.releaseDraft();
      case 'release-send':
        transport.releaseSend();
      case 'hold-send':
        transport.sendGate = Completer<void>();
      case 'hold-draft':
        transport.draftGate = Completer<void>();
    }
    record();
  });
  Timer.periodic(const Duration(milliseconds: 50), (_) => record());
  runApp(MaterialApp(
      home: ChatScope(
          client: client,
          child: Scaffold(
            body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Text('Public composer editing probe',
                      style: TextStyle(fontSize: 24)),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                      valueListenable: host,
                      builder: (_, value, __) => Text(
                          'Accepted: ${value.text} | Selection: '
                          '${value.selection.baseOffset},${value.selection.extentOffset} | IME: '
                          '${value.composing.start},${value.composing.end}')),
                  if (Uri.base.queryParameters['control'] == '1') ...[
                    TextField(
                        controller: host,
                        focusNode: focus,
                        maxLines: 6,
                        decoration:
                            const InputDecoration(labelText: 'Message input')),
                    IconButton(
                        tooltip: 'Send message',
                        icon: const Icon(Icons.send),
                        onPressed: () {
                          host.clear();
                          focus.requestFocus();
                        }),
                  ] else
                    HandrailMessageComposer(
                        conversationId: conversationId,
                        controller: host,
                        focusNode: focus,
                        draftDebounce: const Duration(milliseconds: 200)),
                ])),
          ))));
}

class ProbeTransport implements HandrailChatHttpTransport {
  Completer<void>? draftGate = Completer<void>();
  Completer<void>? sendGate;
  final requests = <Map<String, Object?>>[];
  void releaseDraft() {
    final gate = draftGate;
    draftGate = null;
    gate?.complete();
  }

  void releaseSend() {
    final gate = sendGate;
    sendGate = null;
    gate?.complete();
  }

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'GET') {
      if (request.uri.path.endsWith('/_meta'))
        return _response(200, {
          'packageVersion': '0.1.31',
          'protocolVersion': 4,
          'schemaVersion': 1,
          'enabledFeatures': {'realtime': true},
          'supportedProtocolRange': {'minimumVersion': 3, 'maximumVersion': 4},
        });
      final parts = request.uri.pathSegments;
      final id = parts[parts.indexOf('conversations') + 1];
      return _response(
          200,
          request.uri.path.endsWith('/messages')
              ? _timelineFixture(conversationId: id)
              : _conversationFixture(conversationId: id));
    }
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    requests.add(body);
    if (body['operation'] == 'synchronize_draft') {
      await draftGate?.future;
      return _response(200, {
        'operation': 'synchronize_draft',
        'intent': body['intent'],
        'reconciliationStatus': 'applied',
        'conversationId': body['conversationId'],
        'baseRevision': body['baseRevision'],
        'deviceMutationId': body['deviceMutationId'],
        'idempotencyKey': body['idempotencyKey'],
        'canonicalRevision': (body['baseRevision'] as int) + 1,
        'canonicalUpdatedAt': _now,
        'draft': {
          'kind': body['intent'] == 'replace' ? 'replaced' : 'clear_tombstone',
          'content': body['content']
        },
      });
    }
    if (body['operation'] == 'send') {
      await sendGate?.future;
      return _response(200, {
        'operation': 'send',
        'reconciliationStatus': 'applied',
        'clientMessageId': body['clientMessageId'],
        'canonicalRevision': 1,
        'message': {
          'id': 'sent-${requests.length}',
          'tenantId': _tenantId,
          'conversationId': body['conversationId'],
          'author': {'type': 'user', 'userId': _userId},
          'sequence': 10,
          'createdAt': _now,
          'updatedAt': _now,
          'revision': {'revision': 1},
          'content': body['content']
        }
      });
    }
    throw StateError('Unexpected fixture operation: ${body['operation']}');
  }
}

Map<String, Object?> _conversationFixture(
        {String conversationId = 'conversation-composer',
        bool thread = false}) =>
    {
      'kind': 'conversation_detail',
      'conversation': {
        'id': conversationId,
        'tenantId': _tenantId,
        'type': thread ? 'thread' : 'channel',
        if (thread) ...{
          'parentConversationId': 'parent-channel',
          'rootMessageId': 'root-message'
        },
        'name': 'Composer fixture',
        'visibility': thread ? 'private' : 'public',
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': 1,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _tenantId,
          'conversationId': conversationId,
          'userId': _userId,
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': conversationId,
          'userId': _userId,
          'lastReadSequence': 1,
          'updatedAt': _now,
        },
        'currentPreference': {
          'conversationId': conversationId,
          'userId': _userId,
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': [_userId],
        'memberUserIds': [_userId],
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

Map<String, Object?> _timelineFixture(
        {String conversationId = 'conversation-composer'}) =>
    {
      'conversationId': conversationId,
      'messages': <Object?>[],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'composer-snapshot-event'},
      },
    };

HandrailChatHttpResponse _response(int statusCode, Object body) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );
