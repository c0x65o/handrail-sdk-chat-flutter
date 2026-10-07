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
var conversationId = const ConversationId('conversation-composer');
var visible = true;
var account = 0;
late StateSetter updateHost;
final outsideFocus = FocusNode();
final transport = ProbeTransport();
final host = TextEditingController();
final focus = FocusNode();
final storage = BrowserStorage();
final stateNode = html.DivElement()..id = 'accepted-state';
late HandrailChatClient client;
int serial = 0;
bool disabledObserved = false;
final focusChanges = <Map<String, Object?>>[];
void record() {
  final draft = client.draftFor(conversationId);
  if (!focus.canRequestFocus && transport.sendGate != null) disabledObserved = true;
  stateNode.text = jsonEncode({
    'text': host.text,
    'conversation': conversationId.value,
    'visible': visible,
    'account': account,
    'outsideFocus': outsideFocus.hasFocus,
    'focusChanges': focusChanges,
    'selection': [host.selection.baseOffset, host.selection.extentOffset],
    'composing': [host.value.composing.start, host.value.composing.end],
    'focus': focus.hasFocus,
    'canRequestFocus': focus.canRequestFocus,
    'disabledObserved': disabledObserved,
    'durable': jsonEncode({for (final key in html.window.localStorage.keys)
      if (key.endsWith('/queuedDraftIntents')) key: jsonDecode(html.window.localStorage[key]!)}),
    'canonical': transport.canonical,
    'acceptedCanonicalMessages': client.normalizedState.state.canonicalMessages.values
        .map((message) => message.toJson()).toList(),
    'sending': transport.sendGate != null,
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
    localStorage: storage,
    storageIdentity: ApplicationChatStorageIdentity(
        tenantId: const TenantId(_tenantId),
        userId: const UserId(_userId),
        deviceId: const DeviceId('probe-device')),
    commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    generateIdempotencyKey: () => 'probe-key-${++serial}',
    generateDraftDeviceMutationId: () => 'probe-draft-${++serial}',
    generateClientMessageId: () => 'probe-message-${++serial}',
  );
  FocusManager.instance.addListener(() {
    final primary = FocusManager.instance.primaryFocus;
    String? button;
    primary?.context?.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is IconButton) button = widget.tooltip;
      return true;
    });
    focusChanges.add({'editor': primary == focus, 'outside': primary == outsideFocus,
      'scope': primary is FocusScopeNode, 'button': button,
      'canRequestFocus': focus.canRequestFocus});
    record();
  });
  host.addListener(record);
  focus.addListener(record);
  client.conversations
      .forConversation(conversationId)
      .states
      .listen((_) => record());
  html.window.onMessage.listen((event) {
    switch (event.data) {
      case 'hide':
        updateHost(() => visible = false);
      case 'show':
        updateHost(() => visible = true);
      case 'channel':
        updateHost(() => conversationId = const ConversationId('other-channel'));
      case 'thread':
        updateHost(() => conversationId = const ConversationId('other-thread'));
      case 'main':
        updateHost(() => conversationId = const ConversationId('conversation-composer'));
      case 'account':
        account++;
        client.activateStorageIdentity(ApplicationChatStorageIdentity(
          tenantId: const TenantId(_tenantId), userId: UserId('actor-$account'),
          deviceId: const DeviceId('probe-device'))).then((_) => record());
      case 'logout':
        updateHost(() => visible = false);
        client.dispose();
      case 'outside':
        outsideFocus.requestFocus();
      case 'release-draft':
        transport.releaseDraft();
      case 'release-send':
        transport.releaseSend();
      case 'hold-send':
        disabledObserved = false;
        transport.sendGate = Completer<void>();
      case 'fail-send':
        transport.failSend = true;
      case 'hold-draft':
        transport.draftGate = Completer<void>();
    }
    record();
  });
  Timer.periodic(const Duration(milliseconds: 50), (_) => record());
  runApp(MaterialApp(
      home: StatefulBuilder(builder: (context, setHostState) {
        updateHost = setHostState;
        return ChatScope(
          client: client,
          child: Scaffold(
            body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Text('Public composer editing probe',
                      style: TextStyle(fontSize: 24)),
                  TextField(focusNode: outsideFocus, decoration: const InputDecoration(labelText: 'Outside editor')),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                      valueListenable: host,
                      builder: (_, value, __) => Text(
                          'Accepted: ${value.text} | Selection: '
                          '${value.selection.baseOffset},${value.selection.extentOffset} | IME: '
                          '${value.composing.start},${value.composing.end}')),
                  if (visible)
                    HandrailMessageComposer(
                        conversationId: conversationId,
                        controller: host,
                        focusNode: focus,
                        draftDebounce: const Duration(milliseconds: 200)),
                ])),
          ));
      })));
}

class ProbeTransport implements HandrailChatHttpTransport {
  Completer<void>? draftGate;
  bool failSend = false;
  int sequence = 10;
  final canonical = <Map<String, Object?>>[];
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
              : _conversationFixture(conversationId: id, thread: id == 'other-thread'));
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
      if (failSend) {
        failSend = false;
        return _response(400, {'error': {'code': 'REJECTED', 'message': 'Fixture rejection'}});
      }
      canonical.add(body);
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
          'sequence': sequence++,
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

// Browser-local durable adapter; all serialization uses the SDK's record codec.
class BrowserStorage implements ApplicationChatStorage {
  String key(ApplicationChatStorageIdentity identity, ApplicationChatStorageRecordKind kind) =>
      '${identity.tenantId.value}/${identity.userId.value}/${identity.deviceId.value}/${kind.name}';
  @override
  Future<ApplicationChatStorageRecord?> read(ApplicationChatStorageIdentity identity, ApplicationChatStorageRecordKind kind) async {
    final encoded = html.window.localStorage[key(identity, kind)];
    return encoded == null ? null : ApplicationChatStorageRecord.decode(encoded);
  }
  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    html.window.localStorage[key(record.identity, record.kind)] = record.encode();
  }
  @override
  Future<void> remove(ApplicationChatStorageIdentity identity, ApplicationChatStorageRecordKind kind) async {
    html.window.localStorage.remove(key(identity, kind));
  }
  @override
  Future<void> clearForLogout(ApplicationChatStorageIdentity previousIdentity) async {
    for (final kind in ApplicationChatStorageRecordKind.values) {
      await remove(previousIdentity, kind);
    }
  }
  @override
  Future<void> clearForIdentityChange({required ApplicationChatStorageIdentity previousIdentity,
      required ApplicationChatStorageIdentity nextIdentity}) => clearForLogout(previousIdentity);
}
