import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

import 'fixtures/conversation_membership_fixtures.dart';

const _conversationId = ConversationId('conversation-1');
const _timestamp = '2026-08-26T04:30:00.000Z';

void main() {
  testWidgets('debounces search and paginates without duplicate rows', (
    tester,
  ) async {
    final requests = <HandrailMemberDirectorySearchRequest>[];
    final secondPage = Completer<HandrailMemberDirectoryPage>();
    final resources = _resources();
    addTearDown(resources.dispose);

    Future<HandrailMemberDirectoryPage> search(
      HandrailMemberDirectorySearchRequest request,
    ) {
      requests.add(request);
      if (request.query.isEmpty) {
        return Future.value(HandrailMemberDirectoryPage(rows: const []));
      }
      if (request.pageToken == null) {
        return Future.value(
          HandrailMemberDirectoryPage(
            rows: [
              _row('user-a', 'Alice'),
              _row('user-b', 'Bob'),
            ],
            nextPageToken: 'page-2',
          ),
        );
      }
      return secondPage.future;
    }

    await _pumpPicker(
      tester,
      resources: resources,
      search: search,
      debounce: const Duration(milliseconds: 300),
    );
    await tester.pump();
    requests.clear();

    await tester.enterText(_searchField, 'a');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(_searchField, 'al');
    await tester.pump(const Duration(milliseconds: 299));
    expect(requests, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(requests, hasLength(1));
    expect(requests.single.query, 'al');
    expect(requests.single.pageSize, 50);
    expect(requests.single.pageToken, isNull);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey('handrail-member-picker-load-more'),
    ));
    await tester.pump();
    expect(requests.last.pageToken, 'page-2');
    expect(
      find.byKey(const ValueKey('handrail-member-picker-loading-more')),
      findsOneWidget,
    );

    secondPage.complete(
      HandrailMemberDirectoryPage(
        rows: [
          _row('user-b', 'Bob duplicate'),
          _row('user-c', 'Cara'),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Bob duplicate'), findsNothing);
    expect(find.text('Cara'), findsOneWidget);
  });

  testWidgets('a stale request can never replace a newer query', (
    tester,
  ) async {
    final oldSearch = Completer<HandrailMemberDirectoryPage>();
    final newSearch = Completer<HandrailMemberDirectoryPage>();
    final resources = _resources();
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      initialQuery: 'old',
      debounce: Duration.zero,
      search: (request) =>
          request.query == 'old' ? oldSearch.future : newSearch.future,
    );
    await tester.enterText(_searchField, 'new');
    await tester.pump();

    newSearch.complete(
      HandrailMemberDirectoryPage(
        rows: [_row('user-new', 'New result')],
      ),
    );
    await tester.pump();
    expect(find.text('New result'), findsOneWidget);

    oldSearch.complete(
      HandrailMemberDirectoryPage(
        rows: [_row('user-old', 'Stale result')],
      ),
    );
    await tester.pump();
    expect(find.text('New result'), findsOneWidget);
    expect(find.text('Stale result'), findsNothing);
  });

  testWidgets('renders selected, existing-member, and disabled rows distinctly',
      (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final resources = _resources();
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      selectedUserIds: {const UserId('user-a')},
      search: (_) async => HandrailMemberDirectoryPage(
        rows: [
          _row('user-a', 'Alice'),
          _row('user-b', 'Existing Bob'),
          _row(
            'user-disabled',
            'Disabled Dana',
            disabled: true,
            disabledReason: 'Outside this project',
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Selected'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('Outside this project'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Alice, selected, not a member')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp('Existing Bob, not selected, existing member, role owner'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp('Disabled Dana.*disabled.*Outside this project'),
      ),
      findsOneWidget,
    );

    final disabledCheckbox = tester.widget<Checkbox>(
      find.descendant(
        of: _rowFinder('user-disabled'),
        matching: find.byType(Checkbox),
      ),
    );
    expect(disabledCheckbox.onChanged, isNull);
    semantics.dispose();
  });

  testWidgets(
      'delegates add, remove, and role changes with canonical revisions', (
    tester,
  ) async {
    Object? responseParseError;
    final resources = _resources(
      onRequest: (request) async {
        final input = _body(request);
        final response = appliedMembershipFixture(input);
        try {
          ConversationMembershipMutationResult.fromJson(
            response,
            expectedInput: ConversationMembershipMutationInput.fromJson(input),
          );
        } catch (error) {
          responseParseError = error;
        }
        return _response(response);
      },
    );
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      authorization: const HandrailMemberPickerAuthorization(
        canAddMembers: true,
        canRemoveMembers: true,
        canChangeMemberRoles: true,
      ),
      defaultAddRole: ConversationMembershipMemberRole.moderator,
      roleOptions: const [
        ConversationMembershipMemberRole.member,
        ConversationMembershipMemberRole.moderator,
      ],
      search: (_) async => HandrailMemberDirectoryPage(
        rows: [
          _row('user-c', 'Cara'),
          _row('user-b', 'Bob'),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(_addButton('user-c'));
    await _pumpUntil(tester, () => resources.transport.requests.length == 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(responseParseError, isNull);
    expect(
      resources.store.state.memberListRevisions[_conversationId],
      5,
    );
    expect(_removeButton('user-c'), findsOneWidget);
    expect(resources.transport.requests, hasLength(1));
    expect(_body(resources.transport.requests[0]),
        containsPair('intent', 'add_member'));
    expect(
      _body(resources.transport.requests[0]),
      containsPair('expectedMemberListRevision', 4),
    );
    expect(
      _body(resources.transport.requests[0]),
      containsPair('requestedRole', 'moderator'),
    );

    await tester.tap(_removeButton('user-c'));
    await _pumpUntil(
      tester,
      () => _addButton('user-c').evaluate().isNotEmpty,
    );
    expect(resources.transport.requests, hasLength(2));
    expect(
      _body(resources.transport.requests[1]),
      containsPair('intent', 'remove_member'),
    );
    expect(
      _body(resources.transport.requests[1]),
      containsPair('expectedMemberListRevision', 5),
    );

    await tester.tap(_roleButton('user-b'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('moderator').last);
    await _pumpUntil(tester, () => resources.transport.requests.length == 3);
    expect(resources.transport.requests, hasLength(3));
    expect(
      _body(resources.transport.requests[2]),
      containsPair('intent', 'change_member_role'),
    );
    expect(
      _body(resources.transport.requests[2]),
      containsPair('expectedMemberListRevision', 6),
    );
    expect(
      _body(resources.transport.requests[2]),
      containsPair('requestedRole', 'moderator'),
    );
  });

  testWidgets('unauthorized actions are non-invokable by pointer or keyboard', (
    tester,
  ) async {
    final resources = _resources(
      onRequest: (_) async => throw StateError('must not dispatch'),
    );
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      authorization: const HandrailMemberPickerAuthorization(),
      roleOptions: const [ConversationMembershipMemberRole.moderator],
      search: (_) async => HandrailMemberDirectoryPage(
        rows: [
          _row('user-c', 'Cara'),
          _row('user-b', 'Bob'),
        ],
      ),
    );
    await tester.pump();

    expect(tester.widget<IconButton>(_addButton('user-c')).onPressed, isNull);
    expect(
      tester.widget<IconButton>(_removeButton('user-b')).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButton<ConversationMembershipMemberRole>>(
            _roleButton('user-b'),
          )
          .onChanged,
      isNull,
    );

    await tester.tap(_addButton('user-c'), warnIfMissed: false);
    await tester.tap(_removeButton('user-b'), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(resources.transport.requests, isEmpty);
  });

  testWidgets('shows initial loading, empty, and retryable error states', (
    tester,
  ) async {
    final initial = Completer<HandrailMemberDirectoryPage>();
    var failingAttempts = 0;
    final resources = _resources();
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      debounce: Duration.zero,
      search: (request) {
        if (request.query.isEmpty) return initial.future;
        failingAttempts += 1;
        if (failingAttempts == 1) {
          return Future<HandrailMemberDirectoryPage>.error(
            StateError('directory unavailable'),
          );
        }
        return Future.value(
          HandrailMemberDirectoryPage(
            rows: [_row('user-retry', 'Recovered Riley')],
          ),
        );
      },
    );
    expect(
      find.byKey(const ValueKey('handrail-member-picker-initial-loading')),
      findsOneWidget,
    );

    initial.complete(HandrailMemberDirectoryPage(rows: const []));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('handrail-member-picker-empty')),
      findsOneWidget,
    );

    await tester.enterText(_searchField, 'retry');
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('handrail-member-picker-error')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(
      const ValueKey('handrail-member-picker-retry'),
    ));
    await tester.pump();
    await tester.pump();
    expect(failingAttempts, 2);
    expect(find.text('Recovered Riley'), findsOneWidget);
  });

  testWidgets('supports row keyboard navigation, activation, and semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final selections = <Set<UserId>>[];
    final resources = _resources();
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      onSelectionChanged: selections.add,
      search: (_) async => HandrailMemberDirectoryPage(
        rows: [
          _row('user-a', 'Alice'),
          _row('user-b', 'Bob'),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel('Search member directory'),
      findsOneWidget,
    );
    final firstFocus = tester.widget<Focus>(
      find
          .ancestor(
            of: _rowFinder('user-a'),
            matching: find.byType(Focus),
          )
          .first,
    );
    firstFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(selections.last, contains(const UserId('user-a')));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selections.last,
        containsAll(const [UserId('user-a'), UserId('user-b')]));
    expect(
      find.bySemanticsLabel(
          RegExp('Bob, selected, existing member, role owner')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('disposal releases rows and ignores late directory results', (
    tester,
  ) async {
    final pickerKey = GlobalKey<HandrailMemberPickerState>();
    final lateSearch = Completer<HandrailMemberDirectoryPage>();
    final resources = _resources();
    addTearDown(resources.dispose);

    await _pumpPicker(
      tester,
      resources: resources,
      pickerKey: pickerKey,
      debounce: Duration.zero,
      search: (request) {
        if (request.query == 'late') return lateSearch.future;
        return Future.value(
          HandrailMemberDirectoryPage(
            rows: [_row('user-a', 'Alice')],
          ),
        );
      },
    );
    await tester.pump();
    final state = pickerKey.currentState!;
    expect(state.debugRetainedDirectoryRowCount, 1);

    await tester.enterText(_searchField, 'late');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(state.debugRetainedDirectoryRowCount, 0);

    lateSearch.complete(
      HandrailMemberDirectoryPage(
        rows: [_row('user-late', 'Late result')],
      ),
    );
    await tester.pump();
    expect(state.debugRetainedDirectoryRowCount, 0);
  });
}

Finder get _searchField => find.byKey(
      const ValueKey('handrail-member-picker-search'),
    );

Finder _rowFinder(String userId) =>
    find.byKey(ValueKey('handrail-member-row-$userId'));

Finder _addButton(String userId) =>
    find.byKey(ValueKey('handrail-member-add-$userId'));

Finder _removeButton(String userId) =>
    find.byKey(ValueKey('handrail-member-remove-$userId'));

Finder _roleButton(String userId) =>
    find.byKey(ValueKey('handrail-member-role-$userId'));

Future<void> _pumpPicker(
  WidgetTester tester, {
  required _Resources resources,
  required HandrailMemberDirectorySearchDelegate search,
  GlobalKey<HandrailMemberPickerState>? pickerKey,
  Duration debounce = const Duration(milliseconds: 300),
  String initialQuery = '',
  Set<UserId> selectedUserIds = const <UserId>{},
  ValueChanged<Set<UserId>>? onSelectionChanged,
  HandrailMemberPickerAuthorization authorization =
      const HandrailMemberPickerAuthorization(),
  ConversationMembershipMemberRole defaultAddRole =
      ConversationMembershipMemberRole.member,
  List<ConversationMembershipMemberRole> roleOptions = const [
    ConversationMembershipMemberRole.member,
  ],
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HandrailMemberPicker(
          key: pickerKey,
          client: resources.client,
          conversationId: _conversationId,
          searchDirectory: search,
          authorization: authorization,
          searchDebounce: debounce,
          initialQuery: initialQuery,
          selectedUserIds: selectedUserIds,
          onSelectionChanged: onSelectionChanged,
          defaultAddRole: defaultAddRole,
          roleOptions: roleOptions,
        ),
      ),
    ),
  );
}

HandrailMemberDirectoryRow _row(
  String userId,
  String name, {
  bool disabled = false,
  String? disabledReason,
}) =>
    HandrailMemberDirectoryRow(
      userId: UserId(userId),
      displayName: name,
      disabled: disabled,
      disabledReason: disabledReason,
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 50; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) {
      await tester.pump();
      return;
    }
  }
  fail('Widget condition was not reached.');
}

_Resources _resources({
  Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)? onRequest,
}) {
  final store = NormalizedSnapshotStore()
    ..hydrateConversationDetail(_conversationDetail());
  _installCanonicalMembership(store);
  final transport = _RecordingTransport(
    onRequest ?? (_) async => throw StateError('Unexpected HTTP request'),
  );
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.test/api'),
    tokenProvider: () async => 'token',
    transport: transport,
    normalizedSnapshotStore: store,
    commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
    generateIdempotencyKey: () => 'picker-command-id',
  );
  return _Resources(store: store, client: client, transport: transport);
}

void _installCanonicalMembership(NormalizedSnapshotStore store) {
  final input = ConversationMembershipMutationInput(
    intent: ConversationMembershipMutationIntent.addMember,
    conversationId: _conversationId,
    expectedMemberListRevision: 3,
    idempotencyKey: 'seed-membership',
    targetUserId: const UserId('user-b'),
    requestedRole: ConversationMembershipMemberRole.owner,
  );
  store.reconcileConversationMembership(
    ConversationMembershipMutationResult.fromJson(
      {
        'operation': 'mutate_conversation_membership',
        'intent': 'add_member',
        'reconciliationStatus': 'applied',
        'conversationId': _conversationId.value,
        'expectedMemberListRevision': 3,
        'memberListRevision': 4,
        'memberUserId': 'user-b',
        'targetUserId': 'user-b',
        'requestedRole': 'owner',
        'members': [
          membershipMember('user-actor', 'member'),
          membershipMember('user-b', 'owner'),
        ],
      },
      expectedInput: input,
    ),
  );
}

ConversationDetailSnapshot _conversationDetail() =>
    ConversationDetailSnapshot.fromJson({
      'kind': 'conversation_detail',
      'conversation': {
        'id': _conversationId.value,
        'tenantId': 'tenant-1',
        'type': 'channel',
        'name': 'Picker test',
        'visibility': 'public',
        'createdAt': _timestamp,
        'updatedAt': _timestamp,
        'latestSequence': 1,
        'activityAt': _timestamp,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': 'tenant-1',
          'conversationId': _conversationId.value,
          'userId': 'user-actor',
          'role': 'member',
          'state': 'active',
          'joinedAt': _timestamp,
          'updatedAt': _timestamp,
        },
        'currentReadState': {
          'conversationId': _conversationId.value,
          'userId': 'user-actor',
          'lastReadSequence': 1,
          'updatedAt': _timestamp,
        },
        'memberUserIds': ['user-actor', 'user-b'],
        'currentPreference': {
          'conversationId': _conversationId.value,
          'userId': 'user-actor',
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _timestamp,
        },
        'activeMemberUserIds': ['user-actor', 'user-b'],
      },
      '_meta': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 9,
        'enabledFeatures': {
          'threads': true,
          conversationSnapshotFeature: true,
        },
        'supportedProtocolRange': {
          'minimumVersion': 1,
          'maximumVersion': 4,
        },
        'feature': {
          'name': conversationSnapshotFeature,
          'version': conversationSnapshotVersion,
        },
      },
    });

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    Map<String, Object?>.from(
      jsonDecode(request.body!) as Map<Object?, Object?>,
    );

HandrailChatHttpResponse _response(Object? body) => HandrailChatHttpResponse(
      statusCode: 200,
      body: jsonEncode(body),
    );

final class _RecordingTransport implements HandrailChatHttpTransport {
  _RecordingTransport(this.onRequest);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      onRequest;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return onRequest(request);
  }
}

final class _Resources {
  const _Resources({
    required this.store,
    required this.client,
    required this.transport,
  });

  final NormalizedSnapshotStore store;
  final HandrailChatClient client;
  final _RecordingTransport transport;

  Future<void> dispose() async {
    await client.dispose();
    await store.close();
  }
}
