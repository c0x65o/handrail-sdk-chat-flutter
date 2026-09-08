import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _conversationId = ConversationId('channel-header');
const _otherConversationId = ConversationId('channel-other');
const _now = '2026-08-27T04:00:00.000Z';

void main() {
  testWidgets('renders loading and then the canonical conversation title',
      (tester) async {
    final pending = Completer<HandrailChatHttpResponse>();
    final client = _client(_HeaderTransport(pending: pending));
    addTearDown(client.dispose);

    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    expect(
      find.byKey(
        const ValueKey<String>('handrail-channel-header-loading'),
      ),
      findsOneWidget,
    );

    pending.complete(_response(_detail(name: 'General')));
    await _pumpUntil(
      tester,
      () => find.text('General').evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-channel-header-title')),
      findsOneWidget,
    );
  });

  testWidgets('renders error, denied, revoked, not-found, and unavailable',
      (tester) async {
    final errorClient = _client(_HeaderTransport(
      responses: Queue.of([_response({}, statusCode: 500)]),
    ));
    addTearDown(errorClient.dispose);
    await tester.pumpWidget(_scopedHost(
      errorClient,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Unable to load conversation').evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-channel-header-retry')),
      findsOneWidget,
    );

    final deniedClient = _client(_HeaderTransport(
      responses: Queue.of([_response({}, statusCode: 403)]),
    ));
    addTearDown(deniedClient.dispose);
    await tester.pumpWidget(_scopedHost(
      deniedClient,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Conversation access denied').evaluate().isNotEmpty,
    );

    final revokedClient = _client(_HeaderTransport(
      responses: Queue.of([_response({}, statusCode: 403)]),
    ));
    revokedClient.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_detail(name: 'Private')),
    );
    addTearDown(revokedClient.dispose);
    await tester.pumpWidget(_scopedHost(
      revokedClient,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Conversation access revoked').evaluate().isNotEmpty,
    );

    final missingClient = _client(_HeaderTransport(
      responses: Queue.of([_response({}, statusCode: 404)]),
    ));
    addTearDown(missingClient.dispose);
    await tester.pumpWidget(_scopedHost(
      missingClient,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Conversation not found').evaluate().isNotEmpty,
    );

    final unavailableClient = _client(_HeaderTransport(
      responses: Queue.of([_response(_detail(name: 'Available'))]),
    ));
    addTearDown(unavailableClient.dispose);
    final controller =
        unavailableClient.conversations.forConversation(_conversationId);
    await tester.pumpWidget(_host(HandrailChannelHeader(
      conversationId: _conversationId,
      controller: controller,
    )));
    await _pumpUntil(
      tester,
      () => find.text('Available').evaluate().isNotEmpty,
    );
    unawaited(controller.dispose());
    await tester.pump();
    expect(find.text('Conversation unavailable'), findsOneWidget);
  });

  testWidgets('updates title live and renders host slots with theme semantics',
      (tester) async {
    final client = _client(_HeaderTransport(
      responses: Queue.of([_response(_detail(name: 'Initial title'))]),
    ));
    addTearDown(client.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        leading: Icon(Icons.arrow_back, key: ValueKey('host-leading')),
        trailing: Icon(Icons.search, key: ValueKey('host-trailing')),
      ),
      theme: ThemeData(
        extensions: const <ThemeExtension<dynamic>>[
          HandrailChatTheme(
            typography: HandrailChatTypography(
              message: TextStyle(fontSize: 14),
              metadata: TextStyle(fontSize: 12),
              conversationTitle: TextStyle(fontSize: 27, color: Colors.purple),
              composer: TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Initial title').evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('host-leading')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-trailing')), findsOneWidget);
    final title = tester.widget<Text>(
      find.byKey(const ValueKey<String>('handrail-channel-header-title')),
    );
    expect(title.style?.fontSize, 27);
    expect(title.style?.color, Colors.purple);
    final titleSemantics = tester.getSemantics(find.byKey(
      const ValueKey<String>('handrail-channel-header-title-semantics'),
    ));
    expect(titleSemantics.label, 'Initial title');
    expect(titleSemantics.flagsCollection.isHeader, isTrue);

    client.normalizedState.hydrateConversationDetail(
      ConversationDetailSnapshot.fromJson(_detail(
        name: 'Renamed live',
        updatedAt: '2026-08-27T04:01:00.000Z',
      )),
    );
    await tester.pump();
    expect(find.text('Renamed live'), findsOneWidget);
    expect(find.text('Initial title'), findsNothing);
    semantics.dispose();
  });

  testWidgets(
      'omits notification work when authorization or private state is absent',
      (tester) async {
    final transport = _PreferenceHeaderTransport(
      detail: _detail(name: 'General'),
      update: (_) async => throw StateError('preference work is unauthorized'),
    );
    final client = _client(transport);
    addTearDown(client.dispose);

    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(conversationId: _conversationId),
    ));
    await _pumpUntil(tester, () => find.text('General').evaluate().isNotEmpty);
    expect(_notificationControls, findsNothing);
    expect(transport.preferenceRequests, isEmpty);

    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(),
      ),
    ));
    await tester.pump();
    expect(_notificationControls, findsNothing);
    expect(transport.preferenceRequests, isEmpty);

    final loading = Completer<HandrailChatHttpResponse>();
    final loadingClient = _client(_HeaderTransport(pending: loading));
    addTearDown(loadingClient.dispose);
    addTearDown(() {
      if (!loading.isCompleted) {
        loading.complete(_response({}, statusCode: 403));
      }
    });
    await tester.pumpWidget(_scopedHost(
      loadingClient,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
        ),
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-channel-header-loading')),
      findsOneWidget,
    );
    expect(_notificationControls, findsNothing);
  });

  testWidgets('sends exact replacement bodies for every notification level',
      (tester) async {
    final transport = _PreferenceHeaderTransport(
      detail: _detail(
        name: 'Preferences',
        notificationPreference: 'mentions',
        mute: const {'muted': true},
      ),
      update: (input) async => _preferenceResponse(input, 'applied'),
    );
    var key = 0;
    final client = _client(
      transport,
      generateIdempotencyKey: () => 'header-notification-${++key}',
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
        ),
      ),
    ));
    await _pumpUntil(tester, () => _notificationControls.evaluate().isNotEmpty);

    for (final level in <String>['all', 'mentions', 'none']) {
      await _selectPopupItem(
        tester,
        buttonKey: 'handrail-channel-notification-level',
        itemKey: 'handrail-channel-notification-$level',
      );
      await _pumpUntil(
        tester,
        () =>
            transport.preferenceRequests.length ==
            <String>['all', 'mentions', 'none'].indexOf(level) + 1,
      );
    }

    expect(
      transport.preferenceRequests.map(_requestBody).toList(),
      [
        for (var index = 0; index < 3; index += 1)
          {
            'operation': 'update_conversation_preference',
            'conversationId': _conversationId.value,
            'expectedPreferenceRevision': index,
            'idempotencyKey': 'header-notification-${index + 1}',
            'notificationPreference': <String>[
              'all',
              'mentions',
              'none'
            ][index],
            'isStarred': false,
            'mute': {'muted': true},
          },
      ],
    );
  });

  testWidgets('sends exact unmuted, indefinite, and mute-until replacements',
      (tester) async {
    const until = IsoTimestamp('2026-08-29T18:30:00.000Z');
    final transport = _PreferenceHeaderTransport(
      detail: _detail(
        name: 'Preferences',
        notificationPreference: 'mentions',
        mute: const {'muted': true},
      ),
      update: (input) async => _preferenceResponse(input, 'applied'),
    );
    var key = 0;
    final client = _client(
      transport,
      generateIdempotencyKey: () => 'header-mute-${++key}',
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(_scopedHost(
      client,
      HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
          muteUntilPicker: (_, __) async => until,
        ),
      ),
    ));
    await _pumpUntil(tester, () => _notificationControls.evaluate().isNotEmpty);

    for (final selection in <String>['unmuted', 'indefinite', 'until']) {
      await _selectPopupItem(
        tester,
        buttonKey: 'handrail-channel-notification-mute',
        itemKey: 'handrail-channel-notification-mute-$selection',
      );
      await _pumpUntil(
        tester,
        () =>
            transport.preferenceRequests.length ==
            <String>['unmuted', 'indefinite', 'until'].indexOf(selection) + 1,
      );
    }

    expect(
      transport.preferenceRequests.map(_requestBody).toList(),
      [
        {
          'operation': 'update_conversation_preference',
          'conversationId': _conversationId.value,
          'expectedPreferenceRevision': 0,
          'idempotencyKey': 'header-mute-1',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
        },
        {
          'operation': 'update_conversation_preference',
          'conversationId': _conversationId.value,
          'expectedPreferenceRevision': 1,
          'idempotencyKey': 'header-mute-2',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': true},
        },
        {
          'operation': 'update_conversation_preference',
          'conversationId': _conversationId.value,
          'expectedPreferenceRevision': 2,
          'idempotencyKey': 'header-mute-3',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': true, 'mutedUntil': until.value},
        },
      ],
    );
  });

  testWidgets('guards pending updates and announces command errors',
      (tester) async {
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _PreferenceHeaderTransport(
      detail: _detail(name: 'Preferences'),
      update: (_) => pending.future,
    );
    final client = _client(
      transport,
      generateIdempotencyKey: () => 'header-pending',
    );
    addTearDown(client.dispose);
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(const HandrailChatHttpResponse(
          statusCode: 403,
          body: '{"error":{"code":"FORBIDDEN","message":"denied"}}',
        ));
      }
    });
    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
        ),
      ),
    ));
    await _pumpUntil(tester, () => _notificationControls.evaluate().isNotEmpty);
    await _selectPopupItem(
      tester,
      buttonKey: 'handrail-channel-notification-level',
      itemKey: 'handrail-channel-notification-none',
    );
    await _pumpUntil(tester, () => transport.preferenceRequests.length == 1);

    expect(
      tester
          .widget<PopupMenuButton<ConversationNotificationPreference>>(
            find.byKey(const ValueKey<String>(
              'handrail-channel-notification-level',
            )),
          )
          .enabled,
      isFalse,
    );
    expect(
      _feedbackSemantics(tester).properties.label,
      'Updating conversation notification settings',
    );
    expect(_feedbackSemantics(tester).properties.liveRegion, isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    expect(transport.preferenceRequests, hasLength(1));

    pending.complete(const HandrailChatHttpResponse(
      statusCode: 403,
      body: '{"error":{"code":"FORBIDDEN","message":"denied"}}',
    ));
    await _pumpUntil(
      tester,
      () => _feedbackSemantics(tester)
          .properties
          .label!
          .startsWith('Unable to update conversation notification settings.'),
    );
    expect(
      _feedbackSemantics(tester).properties.label,
      contains('Chat authentication failed.'),
    );
  });

  testWidgets('reconciles conflicts to canonical controls and revision',
      (tester) async {
    var updates = 0;
    final transport = _PreferenceHeaderTransport(
      detail: _detail(
        name: 'Preferences',
        notificationPreference: 'mentions',
      ),
      update: (input) async {
        updates += 1;
        if (updates == 1) {
          return _preferenceResponse(
            input,
            'preference_revision_conflict',
            statusCode: 409,
            revision: 4,
            canonical: const {
              'notificationPreference': 'all',
              'isStarred': false,
              'mute': {'muted': true},
            },
          );
        }
        return _preferenceResponse(input, 'applied');
      },
    );
    var key = 0;
    final client = _client(
      transport,
      generateIdempotencyKey: () => 'header-conflict-${++key}',
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(_scopedHost(
      client,
      const HandrailChannelHeader(
        conversationId: _conversationId,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
        ),
      ),
    ));
    await _pumpUntil(tester, () => _notificationControls.evaluate().isNotEmpty);
    await _selectPopupItem(
      tester,
      buttonKey: 'handrail-channel-notification-level',
      itemKey: 'handrail-channel-notification-none',
    );
    await _pumpUntil(
      tester,
      () => _feedbackSemantics(tester).properties.label!.contains(
            'changed elsewhere',
          ),
    );

    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-level',
    )));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<ConversationNotificationPreference>>(
            find.byKey(const ValueKey<String>(
              'handrail-channel-notification-all',
            )),
          )
          .checked,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-all',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-mute',
    )));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<dynamic>>(find.byKey(
            const ValueKey<String>(
              'handrail-channel-notification-mute-indefinite',
            ),
          ))
          .checked,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-mute-indefinite',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-level',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'handrail-channel-notification-mentions',
    )));
    await _pumpUntil(tester, () => transport.preferenceRequests.length == 2);

    expect(_requestBody(transport.preferenceRequests[1]), {
      'operation': 'update_conversation_preference',
      'conversationId': _conversationId.value,
      'expectedPreferenceRevision': 4,
      'idempotencyKey': 'header-conflict-2',
      'notificationPreference': 'mentions',
      'isStarred': false,
      'mute': {'muted': true},
    });
  });

  testWidgets('tears down caller-supplied and internally resolved bindings',
      (tester) async {
    final suppliedClient = _client(_HeaderTransport(
      responses: Queue.of([_response(_detail(name: 'Supplied'))]),
    ));
    addTearDown(suppliedClient.dispose);
    final supplied =
        suppliedClient.conversations.forConversation(_conversationId);
    final suppliedKey = GlobalKey<HandrailChannelHeaderState>();
    await tester.pumpWidget(_host(HandrailChannelHeader(
      key: suppliedKey,
      conversationId: _conversationId,
      controller: supplied,
    )));
    await _pumpUntil(
      tester,
      () => find.text('Supplied').evaluate().isNotEmpty,
    );
    expect(suppliedKey.currentState?.debugController, same(supplied));
    await tester.pumpWidget(_host(const SizedBox()));
    expect(supplied.state.isDisposed, isFalse);

    final scopedClient = _client(_HeaderTransport(
      responses: Queue.of([_response(_detail(name: 'Scoped'))]),
    ));
    addTearDown(scopedClient.dispose);
    final scopedKey = GlobalKey<HandrailChannelHeaderState>();
    await tester.pumpWidget(_scopedHost(
      scopedClient,
      HandrailChannelHeader(
        key: scopedKey,
        conversationId: _conversationId,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Scoped').evaluate().isNotEmpty,
    );
    final resolved = scopedKey.currentState!.debugController!;
    expect(
      resolved,
      same(scopedClient.conversations.forConversation(_conversationId)),
    );
    await tester.pumpWidget(_host(const SizedBox()));
    expect(resolved.state.isDisposed, isFalse);
  });

  testWidgets('rejects a supplied controller for another conversation',
      (tester) async {
    final client = _client(_HeaderTransport());
    addTearDown(client.dispose);
    final controller =
        client.conversations.forConversation(_otherConversationId);

    await tester.pumpWidget(_host(HandrailChannelHeader(
      conversationId: _conversationId,
      controller: controller,
    )));
    expect(tester.takeException(), isA<FlutterError>());
  });
}

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: SizedBox(height: 64, child: child)),
    );

Widget _scopedHost(
  HandrailChatClient client,
  Widget child, {
  ThemeData? theme,
}) =>
    MaterialApp(
      theme: theme,
      home: ChatScope(
        key: ValueKey<Object>(client),
        client: client,
        child: Scaffold(body: SizedBox(height: 64, child: child)),
      ),
    );

HandrailChatClient _client(
  HandrailChatHttpTransport transport, {
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'header-test-token',
      transport: transport,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: generateIdempotencyKey,
      conversationPreferenceClock: () => const IsoTimestamp(_now),
    );

Map<String, Object?> _detail({
  required String name,
  String updatedAt = _now,
  String notificationPreference = 'all',
  Map<String, Object?> mute = const {'muted': false},
  bool includePreference = true,
}) =>
    {
      'kind': 'conversation_detail',
      'conversation': {
        'id': _conversationId.value,
        'tenantId': 'tenant-header',
        'type': 'channel',
        'name': name,
        'visibility': 'public',
        'createdAt': _now,
        'updatedAt': updatedAt,
        'latestSequence': 0,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-header',
          'conversationId': _conversationId.value,
          'userId': 'user-header',
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': updatedAt,
        },
        'currentReadState': {
          'conversationId': _conversationId.value,
          'userId': 'user-header',
          'lastReadSequence': 0,
          'updatedAt': updatedAt,
        },
        if (includePreference)
          'currentPreference': {
            'conversationId': _conversationId.value,
            'userId': 'user-header',
            'notificationPreference': notificationPreference,
            'isStarred': false,
            'mute': mute,
            'updatedAt': updatedAt,
          },
        'activeMemberUserIds': ['user-header'],
        'memberUserIds': ['user-header'],
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

HandrailChatHttpResponse _response(Object body, {int statusCode = 200}) =>
    HandrailChatHttpResponse(statusCode: statusCode, body: jsonEncode(body));

final class _HeaderTransport implements HandrailChatHttpTransport {
  _HeaderTransport({Queue<HandrailChatHttpResponse>? responses, this.pending})
      : responses = responses ?? Queue<HandrailChatHttpResponse>();

  final Queue<HandrailChatHttpResponse> responses;
  final Completer<HandrailChatHttpResponse>? pending;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    if (pending case final pending?) return pending.future;
    if (responses.isNotEmpty) return Future.value(responses.removeFirst());
    return Future.value(_response({}, statusCode: 500));
  }
}

final class _PreferenceHeaderTransport implements HandrailChatHttpTransport {
  _PreferenceHeaderTransport({required this.detail, required this.update});

  final Map<String, Object?> detail;
  final Future<HandrailChatHttpResponse> Function(Map<String, Object?> input)
      update;
  final List<HandrailChatHttpRequest> requests = [];

  List<HandrailChatHttpRequest> get preferenceRequests => requests
      .where((request) => request.method == 'PATCH')
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    if (request.method == 'GET') return Future.value(_response(detail));
    if (request.method == 'PATCH') return update(_requestBody(request));
    return Future.value(_response({}, statusCode: 400));
  }
}

Map<String, Object?> _requestBody(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

HandrailChatHttpResponse _preferenceResponse(
  Map<String, Object?> input,
  String status, {
  int statusCode = 200,
  int? revision,
  Map<String, Object?>? canonical,
}) {
  final desired = <String, Object?>{
    'notificationPreference': input['notificationPreference'],
    'isStarred': input['isStarred'],
    'mute': input['mute'],
  };
  final expected = input['expectedPreferenceRevision']! as int;
  return _response({
    'operation': 'update_conversation_preference',
    'reconciliationStatus': status,
    'conversationId': input['conversationId'],
    'expectedPreferenceRevision': expected,
    'idempotencyKey': input['idempotencyKey'],
    'requestedPreference': desired,
    'preferenceRevision': revision ?? expected + 1,
    'preference': {
      ...?canonical,
      if (canonical == null) ...desired,
      'updatedAt': '2026-08-27T05:00:00.000Z',
    },
  }, statusCode: statusCode);
}

Finder get _notificationControls => find.byKey(
      const ValueKey<String>('handrail-channel-notification-controls'),
    );

Finder get _notificationFeedback => find.byKey(
      const ValueKey<String>('handrail-channel-notification-feedback'),
    );

Semantics _feedbackSemantics(WidgetTester tester) =>
    tester.widget<Semantics>(_notificationFeedback);

Future<void> _selectPopupItem(
  WidgetTester tester, {
  required String buttonKey,
  required String itemKey,
}) async {
  await tester.tap(find.byKey(ValueKey<String>(buttonKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>(itemKey)));
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt += 1) {
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}
