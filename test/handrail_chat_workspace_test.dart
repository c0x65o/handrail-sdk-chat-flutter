import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';
import 'package:handrail_chat/src/testing/fake_chat_realtime.dart' show FakeChatRealtimeNetwork;
import 'package:handrail_chat/src/testing/in_memory_application_chat_storage.dart';

import 'reply_style_runtime_test.dart' as style;
import 'widget_evidence.dart';
import 'reply_style_client_test.dart' as realtime;

import 'fixtures/conversation_list_fixtures.dart';
import 'fixtures/conversation_creation_fixtures.dart';
import 'fixtures/message_search_fixtures.dart';
import 'fixtures/thread_creation_fixtures.dart';
import 'fixtures/draft_mutation_fixtures.dart';

part 'handrail_reply_routing_cases.dart';
part 'handrail_named_thread_cases.dart';
part 'handrail_thread_discovery_cases.dart';

const _alpha = ConversationId('alpha');
const _beta = ConversationId('beta');
const _root = MessageId('root-alpha');
const _thread = ConversationId('thread-alpha');
const _tenant = 'tenant-from-session';
const _user = 'user-current';
const _now = '2026-08-26T23:30:00.000Z';

void main() {
  replyRoutingTests();
  namedThreadTests();
  threadDiscoveryTests();
  for (final width in [320.0, 390.0, 1400.0]) {
    testWidgets(
      'full workspace header fits and preserves navigation at $width',
      (tester) async {
        final http = _HeaderDiscoveryTransport();
        final client = await _namedClient(tester, http);
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(width < 600 ? 2 : 1)),
              child: child!,
            ),
            home: ChatScope(
              client: client,
              child: Scaffold(
                body: HandrailChatWorkspace(
                  initialConversationId: _alpha,
                  notificationControls:
                      const HandrailChannelNotificationControls(
                        authorized: true,
                      ),
                  messageSearch: (_) async =>
                      HandrailMessageSearchPage(hits: const []),
                  members: HandrailWorkspaceMemberConfiguration(
                    searchDirectory: (_) async =>
                        HandrailMemberDirectoryPage(rows: const []),
                    authorization: const HandrailMemberPickerAuthorization(
                      canAddMembers: true,
                      canRemoveMembers: true,
                      canChangeMemberRoles: true,
                    ),
                  ),
                  huddleController: (client, id) =>
                      client.huddles.forConversation(id),
                ),
              ),
            ),
          ),
        );
        final header = find.byKey(const ValueKey('handrail-channel-header'));
        final level = find.byKey(
          const ValueKey('handrail-channel-notification-level'),
        );
        final mute = find.byKey(
          const ValueKey('handrail-channel-notification-mute'),
        );
        await _pumpUntil(tester, () => level.evaluate().isNotEmpty);
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(of: header, matching: find.text('Alpha')),
          findsOneWidget,
        );
        for (final action in [
          'threads',
          'search',
          'members',
          'huddle',
          'settings',
        ]) {
          final trigger = find.byKey(ValueKey('handrail-workspace-$action'));
          expect(trigger.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(trigger).shortestSide,
            greaterThanOrEqualTo(48),
          );
          expect(
            tester.getRect(header).contains(tester.getCenter(trigger)),
            isTrue,
          );
        }
        if (width >= 600) {
          expect(
            tester.getCenter(level).dy,
            tester.getCenter(find.byTooltip('Browse channel threads')).dy,
          );
        } else {
          expect(
            find.byTooltip('Back to conversations').hitTestable(),
            findsOneWidget,
          );
        }
        final input = find.byKey(
          const ValueKey('handrail-message-composer-input'),
        );
        await tester.enterText(input, 'Retain full header draft');
        final composer = tester.state<HandrailMessageComposerState>(
          find.byType(HandrailMessageComposer),
        );
        final focus = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('handrail-workspace-threads')),
            )
            .focusNode!;
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpUntil(
          tester,
          () => find.text('Canonical launch').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Canonical launch'));
        await _pumpUntil(
          tester,
          () => find.text('Thread reply').evaluate().isNotEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Back to threads'));
        await _pumpUntil(
          tester,
          () => find.text('Canonical launch').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('Back to channel'));
        await _pumpUntil(tester, () => focus.hasFocus);
        expect(
          tester.state<HandrailMessageComposerState>(
            find.byType(HandrailMessageComposer),
          ),
          same(composer),
        );
        expect(
          tester.widget<TextField>(input).controller!.text,
          'Retain full header draft',
        );
        await tester.tap(find.byTooltip('Open workspace settings'));
        await tester.pumpAndSettle();
        expect(find.text('Reply and thread style'), findsOneWidget);
        await tester.tap(find.text('Close settings'));
        await tester.pumpAndSettle();
        http.pendingPreference = Completer<void>();
        await tester.tap(level);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('handrail-channel-notification-mentions')),
        );
        await _pumpUntil(tester, () => http.preferenceWrites.length == 1);
        expect(tester.widget<PopupMenuButton<dynamic>>(level).enabled, isFalse);
        expect(tester.widget<PopupMenuButton<dynamic>>(mute).enabled, isFalse);
        final feedback = tester.widget<Semantics>(
          find.byKey(const ValueKey('handrail-channel-notification-feedback')),
        );
        expect(feedback.properties.liveRegion, isTrue);
        expect(
          feedback.properties.label,
          'Updating conversation notification settings',
        );
        expect(tester.takeException(), isNull);
        http.pendingPreference!.complete();
        await _pumpUntil(
          tester,
          () => find.byTooltip('Notifications: Mentions').evaluate().isNotEmpty,
        );
        await tester.tap(mute);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey('handrail-channel-notification-mute-indefinite'),
          ),
        );
        await _pumpUntil(tester, () => http.preferenceWrites.length == 2);
        await tester.pumpAndSettle();
        expect(
          http.preferenceWrites.last['notificationPreference'],
          'mentions',
        );
        expect(http.preferenceWrites.last['mute'], {'muted': true});
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'settings entry works empty at large text and closes with its workspace',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final transport = _WorkspaceTransport(
        listResponses: Queue.of([_jsonResponse(conversationListPage())]),
      );
      final client = _client(transport);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        unawaited(client.dispose().then((_) => closed = true));
        await _pumpUntil(tester, () => closed);
      });
      var showWorkspace = true;
      late StateSetter updateHost;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: ChatScope(
            client: client,
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  updateHost = setState;
                  return showWorkspace
                      ? const HandrailChatWorkspace()
                      : const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('No conversations').evaluate().isNotEmpty,
      );
      final trigger = find.byTooltip('Open workspace settings');
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('handrail-workspace-settings')),
            )
            .getSemanticsData()
            .tooltip,
        'Open workspace settings',
      );
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('Workspace settings'), findsOneWidget);
      expect(find.text('Reply and thread style'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      updateHost(() => showWorkspace = false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(client.replyStyles.state.isDisposed, isFalse);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final width in [1100.0, 390.0]) {
    testWidgets(
      'settings overlay retains composition, thread and queued intents at $width',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final storage = InMemoryApplicationChatStorage();
        final identity = ApplicationChatStorageIdentity(
          tenantId: const TenantId(_tenant),
          userId: const UserId(_user),
          deviceId: const DeviceId('device-1'),
        );
        final network = FakeChatRealtimeNetwork(isOnline: false);
        final socket = realtime.Socket();
        final session = ChatRealtimeSessionTransport(
          endpoint: Uri.parse('https://chat.example.test/api/chat'),
          clientPackageVersion: '0.1.19',
          protocolVersion: 4,
          tokenProvider: () => 'token',
          socketFactory: (_, __) => socket,
          network: network,
        );
        final transport = _SettingsWorkspaceTransport();
        var keys = 0;
        final client = HandrailChatClient(
          apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
          tokenProvider: () async => 'workspace-token',
          transport: transport,
          localStorage: storage,
          storageIdentity: identity,
          realtimeSession: session,
          generateIdempotencyKey: () => 'settings-workspace-${++keys}',
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          var closed = false;
          unawaited(client.dispose().then((_) => closed = true));
          await _pumpUntil(tester, () => closed);
          await tester.runAsync(() async {
            await session.dispose();
            await socket.framesController.close();
            await network.dispose();
          });
        });
        client.setApplicationForeground(false);
        await tester.runAsync(() => client.activateStorageIdentity(identity));
        // Queue actual persisted sends for both destinations before reconnecting.
        for (final destination in [_alpha, _thread]) {
          final queued = await tester.runAsync(
            () => client.sendMessage(
              ChatSendMessageInput(
                conversationId: destination,
                content: MessageContent.fromJson({
                  'format': 'plain',
                  'text': 'Queued Friday',
                }),
                replyTo: MessageReplyReference(
                  messageId: _root,
                  notifyAuthor: false,
                ),
              ),
            ),
          );
          expect(queued, isA<ChatCommandQueued<SendMessageResult>>());
        }
        await tester.runAsync(client.initialize);
        network.setOnline(true);
        await tester.runAsync(session.start);
        socket.accept(
          identity: const ChatReplyStyleIdentity(
            tenantId: TenantId(_tenant),
            userId: UserId(_user),
          ),
        );
        await _pumpUntil(tester, () => client.replyStyles.state.canEdit);
        _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
        // Real draft runtime and existing storage adapter; message pumps stay paused.
        for (final destination in [_alpha, _thread]) {
          unawaited(
            client.synchronizeDraft(
              ChatReplaceDraftInput(
                conversationId: destination,
                baseRevision: 0,
                content: DraftContent.fromJson({
                  'format': 'markdown',
                  'text': 'Draft for ${destination.value}',
                  'attachments': [
                    {'attachmentId': 'schedule'},
                  ],
                  'replyTo': {'messageId': _root.value, 'notifyAuthor': false},
                }),
                deviceMutationId: 'draft-${destination.value}',
                idempotencyKey: 'draft-${destination.value}',
              ),
            ),
          );
        }
        await _pumpUntil(tester, () => client.draftFor(_thread) != null);
        final workspaceKey = GlobalKey<HandrailChatWorkspaceState>();
        await tester.pumpWidget(
          _host(
            client,
            width: width,
            height: 850,
            child: HandrailChatWorkspace(
              key: workspaceKey,
              initialConversationId: _alpha,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('handrail-reply-root-alpha'))
              .evaluate()
              .isNotEmpty,
          diagnostic: () =>
              'texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()} requests=${transport.requests.map((r) => '${r.method} ${r.uri.path}').toList()}',
        );
        await tester.tap(
          find.byKey(const ValueKey('handrail-reply-root-alpha')),
        );
        await _pumpUntil(
          tester,
          () => find.byType(HandrailThreadView).evaluate().isNotEmpty,
        );
        client.setApplicationForeground(false);
        final threadFinder = find.byType(HandrailThreadView);
        final handle = tester
            .widget<HandrailThreadView>(threadFinder)
            .openHandle!;
        final threadElement = tester.element(threadFinder);
        final composers = find.byType(HandrailMessageComposer);
        final composerElements = tester.elementList(composers).toList();
        expect(composerElements, isNotEmpty);
        final composerStates = tester
            .stateList<HandrailMessageComposerState>(composers)
            .toList();
        for (final composer in composerStates) {
          expect(composer.replyTo?.notifyAuthor, isFalse);
        }
        final visibleDestinations = width < 720 ? [_thread] : [_alpha, _thread];
        for (final id in visibleDestinations) {
          expect(find.text('Draft for ${id.value}'), findsOneWidget);
        }
        expect(
          find.text('schedule'),
          findsNWidgets(visibleDestinations.length),
        );
        final drafts = {
          for (final id in [_alpha, _thread])
            id: client.draftFor(id)!.draft.toJson(),
        };
        expect(client.queuedSendMessages, hasLength(2));
        final requests = client.queuedSendMessages
            .map((send) => send.request.toJson())
            .toList();
        final encoded = await tester.runAsync(
          () => storage.readEncoded(
            identity,
            ApplicationChatStorageRecordKind.queuedSendMessageIntents,
          ),
        );
        final createCount = transport.requests
            .where((r) => r.uri.path.endsWith('/thread'))
            .length;
        final sendCount = transport.requests
            .where(
              (r) => r.method == 'POST' && r.uri.path.endsWith('/messages'),
            )
            .length;
        for (final choice in ['Discord-style', 'Current']) {
          final trigger = find.byKey(
            const ValueKey('handrail-workspace-settings'),
          );
          expect(trigger, findsOneWidget);
          tester.widget<IconButton>(trigger).focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.ensureVisible(find.text(choice));
          await tester.tap(find.text(choice));
          await _pumpUntil(
            tester,
            () =>
                client.replyStyles.state.effectiveStyle ==
                (choice == 'Current' ? ReplyStyle.current : ReplyStyle.discord),
          );
          // Assert while the dialog covers the still-mounted subtree.
          expect(
            tester.element(
              find.byType(HandrailThreadView, skipOffstage: false),
            ),
            same(threadElement),
          );
          expect(handle.isReleased, isFalse);
          expect(handle.conversationId, _thread);
          expect(handle.state.parentConversationId, _alpha);
          expect(handle.rootMessageId, _root);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            tester.widget<IconButton>(trigger).focusNode!.hasFocus,
            isTrue,
          );
          expect(tester.elementList(composers).toList(), composerElements);
          for (final id in visibleDestinations) {
            expect(find.text('Draft for ${id.value}'), findsOneWidget);
          }
          expect(
            find.text('schedule'),
            findsNWidgets(visibleDestinations.length),
          );
          for (final composer in composerStates) {
            expect(composer.replyTo?.messageId, _root);
            expect(composer.replyTo?.notifyAuthor, isFalse);
          }
          for (final id in [_alpha, _thread]) {
            expect(client.draftFor(id)!.draft.toJson(), drafts[id]);
          }
          expect(
            client.queuedSendMessages
                .map((send) => send.request.toJson())
                .toList(),
            requests,
          );
          expect(
            await tester.runAsync(
              () => storage.readEncoded(
                identity,
                ApplicationChatStorageRecordKind.queuedSendMessageIntents,
              ),
            ),
            encoded,
          );
          expect(workspaceKey.currentState!.selectedConversationId, _alpha);
          expect(handle.isReleased, isFalse);
        }
        expect(
          transport.requests
              .where((r) => r.uri.path.endsWith('/thread'))
              .length,
          createCount,
        );
        expect(
          transport.requests
              .where(
                (r) => r.method == 'POST' && r.uri.path.endsWith('/messages'),
              )
              .length,
          sendCount,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
      'negotiated client search appears after readiness, paginates, and opens hits',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WorkspaceTransport(
      enabledFeatures: const <String, bool>{messageSearchFeature: true},
      messageSearchResponses: Queue.of([
        _jsonResponse(messageSearchResponseFixture),
        _jsonResponse(const <String, Object?>{'hits': <Object?>[]}),
      ]),
    );
    final client = _client(
      transport,
      requestedCapabilities: const <String, bool>{messageSearchFeature: true},
    );
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final openedHits = <HandrailMessageSearchHit>[];

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        initialConversationId: _alpha,
        delegates: ChatApplicationDelegates(
          openMessageSearchHit: (hit) async {
            openedHits.add(hit);
            return ChatApplicationDelegateResult.handled;
          },
        ),
      ),
    ));
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-search')),
      findsNothing,
    );

    await client.initialize();
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-workspace-search'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-search')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-message-search-field')),
      'Café order',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await _pumpUntil(tester, () => transport.messageSearchRequests.length == 1);

    expect(
      jsonDecode(transport.messageSearchRequests.first.body!),
      const <String, Object?>{'query': 'Café order', 'pageSize': 50},
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>(
            'handrail-message-search-hit-message-0',
          ))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>(
        'handrail-message-search-hit-message-0',
      )),
    );
    await _pumpUntil(tester, () => openedHits.isNotEmpty);
    expect(
      (openedHits.single as HandrailMessageSearchMessageHit).messageId,
      const MessageId('message-1'),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-message-search-load-more')),
    );
    await _pumpUntil(tester, () => transport.messageSearchRequests.length == 2);
    expect(
      jsonDecode(transport.messageSearchRequests.last.body!),
      const <String, Object?>{
        'query': 'Café order',
        'pageSize': 50,
        'cursor': 'opaque.page.3',
      },
    );
  });

  testWidgets('explicit search override wins over negotiated client transport',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WorkspaceTransport(
      enabledFeatures: const <String, bool>{messageSearchFeature: true},
    );
    final client = _client(
      transport,
      requestedCapabilities: const <String, bool>{messageSearchFeature: true},
    );
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    await client.initialize();
    final overrideRequests = <HandrailMessageSearchRequest>[];

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        initialConversationId: _alpha,
        messageSearch: (request) async {
          overrideRequests.add(request);
          return HandrailMessageSearchPage(hits: const []);
        },
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-workspace-search'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-search')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-message-search-field')),
      'host boundary',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await _pumpUntil(tester, () => overrideRequests.length == 1);

    expect(overrideRequests.single.query, 'host boundary');
    expect(transport.messageSearchRequests, isEmpty);
  });

  testWidgets('default search stays absent when capability is not negotiated',
      (tester) async {
    final transport = _WorkspaceTransport(
      enabledFeatures: const <String, bool>{messageSearchFeature: false},
    );
    final client = _client(
      transport,
      requestedCapabilities: const <String, bool>{messageSearchFeature: true},
    );
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    await client.initialize();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: const HandrailChatWorkspace(initialConversationId: _alpha),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Alpha').evaluate().isNotEmpty,
    );

    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-search')),
      findsNothing,
    );
    expect(transport.messageSearchRequests, isEmpty);
  });

  testWidgets('threads explicit notification authorization to the header',
      (tester) async {
    final transport = _WorkspaceTransport();
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: const HandrailChatWorkspace(initialConversationId: _alpha),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Alpha').evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-notification-controls',
      )),
      findsNothing,
    );

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: const HandrailChatWorkspace(
        initialConversationId: _alpha,
        notificationControls: HandrailChannelNotificationControls(),
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-notification-controls',
      )),
      findsNothing,
    );

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: const HandrailChatWorkspace(
        initialConversationId: _alpha,
        notificationControls: HandrailChannelNotificationControls(
          authorized: true,
        ),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>(
            'handrail-channel-notification-controls',
          ))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-channels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-notification-controls',
      )),
      findsOneWidget,
    );
  });

  testWidgets(
      'omitted or denied direct creation renders no action or directory work',
      (tester) async {
    var directorySearches = 0;
    Future<HandrailMemberDirectoryPage> searchDirectory(
      HandrailMemberDirectorySearchRequest request,
    ) async {
      directorySearches += 1;
      return HandrailMemberDirectoryPage(rows: const []);
    }

    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isEmpty);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-direct')),
      findsNothing,
    );
    expect(directorySearches, 0);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
        directCreation: HandrailWorkspaceDirectCreationConfiguration(
          searchDirectory: searchDirectory,
        ),
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-create-direct')),
      findsNothing,
    );
    expect(directorySearches, 0);
    expect(find.text('No conversations'), findsOneWidget);
  });

  testWidgets(
      'searches one user, creates a direct, and navigates narrow layout to the authoritative ID',
      (tester) async {
    const selectedUserId = UserId('user-ada');
    const returnedId = ConversationId('server-created-direct');
    final searches = <HandrailMemberDirectorySearchRequest>[];
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
      createDirect: (request) async {
        final body = _requestBody(request);
        return _jsonResponse(_directCreationResult(
          body,
          conversationId: returnedId,
          status: 'created',
        ));
      },
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 480,
      child: HandrailChatWorkspace(
        key: key,
        directCreation: HandrailWorkspaceDirectCreationConfiguration(
          authorized: true,
          searchDirectory: (request) async {
            searches.add(request);
            return HandrailMemberDirectoryPage(
              rows: request.query == 'Ada'
                  ? const [
                      HandrailMemberDirectoryRow(
                        userId: selectedUserId,
                        displayName: 'Ada Lovelace',
                        subtitle: 'Engineering',
                      ),
                      HandrailMemberDirectoryRow(
                        userId: UserId('user-disabled'),
                        displayName: 'Unavailable User',
                        disabled: true,
                      ),
                    ]
                  : const [],
            );
          },
        ),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-direct'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-direct')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-create-direct-search')),
      'Ada',
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey<String>('handrail-create-direct-user-user-ada'),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(searches.any((request) => request.query == 'Ada'), isTrue);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('handrail-create-direct-user-user-ada'),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-direct-submit')),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-direct-dialog'))
          .evaluate()
          .isEmpty,
    );

    final request = transport.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          request.uri.path.endsWith('/conversations'),
    );
    expect(_requestBody(request), {
      'operation': 'create_conversation',
      'type': 'direct',
      'visibility': 'private',
      'intendedMemberUserIds': [selectedUserId.value],
      'idempotencyKey': 'workspace-idempotency-key',
      'clientRequestId': 'workspace-client-request',
    });
    expect(
      find.byKey(
        const ValueKey<String>('handrail-workspace-conversation-page'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-create-direct-dialog')),
      findsNothing,
    );
  });

  testWidgets(
      'existing equivalent direct selects the returned authoritative ID on wide layouts',
      (tester) async {
    const selectedUserId = UserId('user-grace');
    const returnedId = ConversationId('server-existing-equivalent-direct');
    final transport = _WorkspaceTransport(
      createDirect: (request) async => _jsonResponse(_directCreationResult(
        _requestBody(request),
        conversationId: returnedId,
        status: 'existing_equivalent',
      )),
    );
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _alpha,
        directCreation: HandrailWorkspaceDirectCreationConfiguration(
          authorized: true,
          searchDirectory: (_) async => HandrailMemberDirectoryPage(
            rows: const [
              HandrailMemberDirectoryRow(
                userId: selectedUserId,
                displayName: 'Grace Hopper',
              ),
            ],
          ),
        ),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-direct'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-direct')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey<String>('handrail-create-direct-user-user-grace'),
          )
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('handrail-create-direct-user-user-grace'),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-direct-submit')),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-direct-dialog'))
          .evaluate()
          .isEmpty,
    );

    expect(key.currentState?.selectedConversationId, returnedId);
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-workspace-timeline-server-existing-equivalent-direct',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-create-direct-dialog')),
      findsNothing,
    );
  });

  testWidgets(
      'omitted or denied group-direct authorization renders no action or directory work',
      (tester) async {
    var directorySearches = 0;
    Future<HandrailMemberDirectoryPage> searchDirectory(
      HandrailMemberDirectorySearchRequest request,
    ) async {
      directorySearches += 1;
      return HandrailMemberDirectoryPage(rows: const []);
    }

    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isEmpty);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-group-direct')),
      findsNothing,
    );
    expect(directorySearches, 0);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
        groupDirectCreation: HandrailWorkspaceGroupDirectCreationConfiguration(
          searchDirectory: searchDirectory,
        ),
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-create-group-direct')),
      findsNothing,
    );
    expect(directorySearches, 0);
    expect(find.text('No conversations'), findsOneWidget);
  });

  testWidgets(
      'group-direct directory retries, pages without duplicates, and supports removal',
      (tester) async {
    const ada = HandrailMemberDirectoryRow(
      userId: UserId('user-ada'),
      displayName: 'Ada Lovelace',
    );
    const grace = HandrailMemberDirectoryRow(
      userId: UserId('user-grace'),
      displayName: 'Grace Hopper',
    );
    var searches = 0;
    final requests = <HandrailMemberDirectorySearchRequest>[];
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
    );
    final client = _client(transport);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        groupDirectCreation: HandrailWorkspaceGroupDirectCreationConfiguration(
          authorized: true,
          searchDirectory: (request) async {
            searches += 1;
            requests.add(request);
            if (searches == 1) throw StateError('directory unavailable');
            if (request.pageToken == null) {
              return HandrailMemberDirectoryPage(
                rows: const [
                  ada,
                  ada,
                  HandrailMemberDirectoryRow(
                    userId: UserId('user-disabled'),
                    displayName: 'Unavailable User',
                    disabled: true,
                    disabledReason: 'Not eligible',
                  ),
                ],
                nextPageToken: 'next-page',
              );
            }
            return HandrailMemberDirectoryPage(
              rows: const [ada, grace],
              nextPageToken: 'next-page',
            );
          },
        ),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-group-direct'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-group-direct')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-group-direct-retry'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-group-direct-retry')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey<String>(
                'handrail-create-group-direct-user-user-ada'),
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-user-user-ada'),
      ),
      findsOneWidget,
    );
    final disabled = tester.widget<ListTile>(
      find.byKey(
        const ValueKey<String>(
          'handrail-create-group-direct-user-user-disabled',
        ),
      ),
    );
    expect(disabled.enabled, isFalse);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-user-user-ada'),
      ),
    );
    await tester.pump();
    final submit = find.byKey(
      const ValueKey<String>('handrail-create-group-direct-submit'),
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(
      transport.requests.where((request) => request.method == 'POST'),
      isEmpty,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-create-group-direct-selected-user-ada',
        ),
      ),
      findsOneWidget,
    );

    final searchesBeforeTyping = searches;
    await tester.enterText(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-search'),
      ),
      'Ada',
    );
    await tester.pump(const Duration(milliseconds: 299));
    expect(searches, searchesBeforeTyping);
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-create-group-direct-selected-user-ada',
        ),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 1));
    await _pumpUntil(tester, () => searches == searchesBeforeTyping + 1);
    expect(requests.last.query, 'Ada');

    await tester.tap(find.text('Load more'));
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey<String>(
              'handrail-create-group-direct-user-user-grace',
            ),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-user-user-ada'),
      ),
      findsOneWidget,
    );
    expect(requests.last.pageToken, 'next-page');
    expect(find.text('Load more'), findsNothing);

    final chip = tester.widget<InputChip>(
      find.byKey(
        const ValueKey<String>(
          'handrail-create-group-direct-selected-user-ada',
        ),
      ),
    );
    chip.onDeleted!();
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-create-group-direct-selected-user-ada',
        ),
      ),
      findsNothing,
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
  });

  testWidgets(
      'creates a group direct once and navigates narrow layout to the authoritative ID',
      (tester) async {
    const adaId = UserId('user-ada');
    const graceId = UserId('user-grace');
    const returnedId = ConversationId('server-created-group-direct');
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
      createGroupDirect: (request) async =>
          _jsonResponse(_groupDirectCreationResult(
        _requestBody(request),
        conversationId: returnedId,
        status: 'created',
      )),
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 480,
      child: HandrailChatWorkspace(
        key: key,
        groupDirectCreation: HandrailWorkspaceGroupDirectCreationConfiguration(
          authorized: true,
          searchDirectory: (_) async => HandrailMemberDirectoryPage(
            rows: const [
              HandrailMemberDirectoryRow(
                userId: graceId,
                displayName: 'Grace Hopper',
              ),
              HandrailMemberDirectoryRow(
                userId: adaId,
                displayName: 'Ada Lovelace',
              ),
            ],
          ),
        ),
      ),
    ));
    await _selectGroupDirectUsers(tester, const [graceId, adaId]);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-submit'),
      ),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );

    final creationRequests = transport.requests.where(
      (request) =>
          request.method == 'POST' &&
          request.uri.path.endsWith('/conversations'),
    );
    expect(creationRequests, hasLength(1));
    expect(_requestBody(creationRequests.single), {
      'operation': 'create_conversation',
      'type': 'group_direct',
      'visibility': 'private',
      'intendedMemberUserIds': [adaId.value, graceId.value],
      'idempotencyKey': 'workspace-idempotency-key',
      'clientRequestId': 'workspace-client-request',
    });
    expect(
      find.byKey(
        const ValueKey<String>('handrail-workspace-conversation-page'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'group-direct pending state suppresses duplicates and failures remain retryable',
      (tester) async {
    const adaId = UserId('user-ada');
    const graceId = UserId('user-grace');
    const returnedId =
        ConversationId('server-existing-equivalent-group-direct');
    final pending = Completer<HandrailChatHttpResponse>();
    var attempts = 0;
    final transport = _WorkspaceTransport(
      createGroupDirect: (request) {
        attempts += 1;
        if (attempts == 1) return pending.future;
        return Future.value(_jsonResponse(_groupDirectCreationResult(
          _requestBody(request),
          conversationId: returnedId,
          status: 'existing_equivalent',
        )));
      },
    );
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _alpha,
        groupDirectCreation: HandrailWorkspaceGroupDirectCreationConfiguration(
          authorized: true,
          searchDirectory: (_) async => HandrailMemberDirectoryPage(
            rows: const [
              HandrailMemberDirectoryRow(
                userId: adaId,
                displayName: 'Ada Lovelace',
              ),
              HandrailMemberDirectoryRow(
                userId: graceId,
                displayName: 'Grace Hopper',
              ),
            ],
          ),
        ),
      ),
    ));
    await _selectGroupDirectUsers(tester, const [adaId, graceId]);
    final submit = find.byKey(
      const ValueKey<String>('handrail-create-group-direct-submit'),
    );
    await tester.tap(submit);
    await _pumpUntil(tester, () => attempts == 1);
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-progress'),
      ),
      findsOneWidget,
    );
    await tester.tap(submit, warnIfMissed: false);
    await tester.pump();
    expect(attempts, 1);

    pending.complete(
      _jsonResponse(const {'error': 'sensitive server detail'},
          statusCode: 500),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-group-direct-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('Try again.'), findsOneWidget);
    expect(find.textContaining('sensitive server detail'), findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('handrail-create-group-direct-dialog'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    await tester.tap(submit);
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );
    expect(attempts, 2);
    expect(key.currentState?.selectedConversationId, returnedId);
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-workspace-timeline-server-existing-equivalent-group-direct',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'requires explicit host authorization and keeps creation usable when empty',
      (tester) async {
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
      ),
    ));
    await _pumpUntil(tester, () => controller.state.isEmpty);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
      findsNothing,
    );
    expect(find.text('No conversations'), findsOneWidget);

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: controller,
        canCreateChannels: true,
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
      findsOneWidget,
    );
    expect(find.text('No channels'), findsOneWidget);
  });

  testWidgets(
      'creates an entity-scoped public channel and selects its authoritative ID on narrow layouts',
      (tester) async {
    const entity = HostEntityReference(type: 'project', id: 'project-42');
    const returnedId = ConversationId('server-public-channel');
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([
        _jsonResponse(conversationListPage(
          scope: {
            'type': 'entity',
            'entity': entity.toJson(),
          },
        )),
      ]),
      createChannel: (request) async {
        final body = _requestBody(request);
        return _jsonResponse(_channelCreationResult(
          id: returnedId,
          name: body['name']! as String,
          visibility: body['visibility']! as String,
          clientRequestId: body['clientRequestId']! as String,
          entity: entity,
        ));
      },
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 480,
      child: HandrailChatWorkspace.forEntity(
        key: key,
        entity: entity,
        canCreateChannels: true,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-channel'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-create-channel-name')),
      'Launch planning',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel-submit')),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );

    final request = transport.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          request.uri.path.endsWith('/conversations'),
    );
    expect(_requestBody(request), {
      'operation': 'create_conversation',
      'type': 'channel',
      'name': 'Launch planning',
      'visibility': 'public',
      'entity': entity.toJson(),
      'idempotencyKey': 'workspace-idempotency-key',
      'clientRequestId': 'workspace-client-request',
    });
    expect(
      find.byKey(
        const ValueKey<String>('handrail-workspace-conversation-page'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel-dialog')),
      findsNothing,
    );
  });

  testWidgets('creates a private channel with the exact authored request',
      (tester) async {
    const returnedId = ConversationId('server-private-channel');
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
      createChannel: (request) async {
        final body = _requestBody(request);
        return _jsonResponse(_channelCreationResult(
          id: returnedId,
          name: body['name']! as String,
          visibility: body['visibility']! as String,
          clientRequestId: body['clientRequestId']! as String,
        ));
      },
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        key: key,
        canCreateChannels: true,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-channel'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-create-channel-name')),
      'Incident leads',
    );
    await tester.tap(find.text('Private'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel-submit')),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == returnedId,
    );

    final request = transport.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          request.uri.path.endsWith('/conversations'),
    );
    expect(_requestBody(request), {
      'operation': 'create_conversation',
      'type': 'channel',
      'name': 'Incident leads',
      'visibility': 'private',
      'idempotencyKey': 'workspace-idempotency-key',
      'clientRequestId': 'workspace-client-request',
    });
  });

  testWidgets(
      'validates names, disables duplicate submission, and keeps failures actionable',
      (tester) async {
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([_jsonResponse(conversationListPage())]),
      createChannel: (_) => pending.future,
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(
        key: key,
        canCreateChannels: true,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-channel'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
    );
    await tester.pump();
    final submit = find.byKey(
      const ValueKey<String>('handrail-create-channel-submit'),
    );
    await tester.tap(submit);
    await tester.pump();
    expect(find.text('Enter a channel name.'), findsOneWidget);
    expect(
      transport.requests.where((request) => request.method == 'POST'),
      isEmpty,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-create-channel-name')),
      'Operations',
    );
    await tester.tap(submit);
    await _pumpUntil(
      tester,
      () => transport.requests.any((request) => request.method == 'POST'),
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel-progress')),
      findsOneWidget,
    );
    await tester.tap(submit);
    await tester.pump();
    expect(
      transport.requests.where((request) => request.method == 'POST'),
      hasLength(1),
    );

    pending.complete(
      _jsonResponse(const {'error': 'sensitive server detail'},
          statusCode: 500),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-channel-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.textContaining('Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('sensitive server detail'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel-dialog')),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    expect(key.currentState?.selectedConversationId, isNull);
  });

  testWidgets(
      'selects deterministically, switches channels, and adapts without routing',
      (tester) async {
    final transport = _WorkspaceTransport();
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    _seedConversation(client, _beta, 'Beta', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(key: key),
    ));
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == _alpha,
    );

    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-wide')),
      findsOneWidget,
    );
    expect(find.text('Alpha message'), findsOneWidget);
    expect(find.byType(HandrailChannelList), findsOneWidget);
    expect(find.byType(HandrailChannelHeader), findsOneWidget);
    expect(find.byType(HandrailMessageTimeline), findsOneWidget);
    expect(find.byType(HandrailMessageComposer), findsOneWidget);

    await tester.tap(find.text('Beta'));
    await _pumpUntil(
        tester, () => find.text('Beta message').evaluate().isNotEmpty);
    expect(key.currentState!.selectedConversationId, _beta);

    await tester.pumpWidget(_host(
      client,
      width: 480,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _beta,
      ),
    ));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-narrow')),
      findsOneWidget,
    );
    expect(
      find.byKey(
          const ValueKey<String>('handrail-workspace-conversation-page')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('handrail-workspace-back')),
          )
          .tooltip,
      'Back to conversations',
    );
    expect(
      find.ancestor(
        of: find.byKey(
          const ValueKey<String>('handrail-workspace-back'),
        ),
        matching: find.byType(HandrailChannelHeader),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-back')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-channel-page')),
      findsOneWidget,
    );
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(
      find.byKey(
          const ValueKey<String>('handrail-workspace-conversation-page')),
      findsOneWidget,
    );
    expect(key.currentState!.selectedConversationId, _alpha);

    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-thread-root-alpha'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-thread-root-alpha')),
    );
    await _pumpUntil(
      tester,
      () => find.byType(HandrailThreadView).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-panel-page')),
      findsOneWidget,
    );
  });

  testWidgets('supports 320px workspace navigation at 200 percent text scale',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const rawFailure = 'private upstream trace and request body';
    var searchAttempts = 0;
    final transport = _WorkspaceTransport();
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    _seedConversation(client, _beta, 'Beta', latestSequence: 1);
    addTearDown(client.dispose);
    final semantics = tester.ensureSemantics();
    void expectSemantics(Finder finder, String label) {
      final node = tester.getSemantics(finder);
      expect(<String>[node.label, node.tooltip], anyElement(contains(label)));
    }

    await tester.pumpWidget(_host(
      client,
      width: 320,
      height: 640,
      textScaler: const TextScaler.linear(2),
      child: HandrailChatWorkspace(
        initialConversationId: _alpha,
        messageSearch: (_) async {
          searchAttempts += 1;
          if (searchAttempts == 1) throw StateError(rawFailure);
          return HandrailMessageSearchPage(hits: const []);
        },
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Alpha message').evaluate().isNotEmpty,
    );

    final back = find.byKey(
      const ValueKey<String>('handrail-workspace-back'),
    );
    expectSemantics(back, 'Back to conversations');
    await tester.tap(back);
    await tester.pump();
    expectSemantics(
      find.byKey(const ValueKey<String>(
        'handrail-channel-public-channels-beta-semantics',
      )),
      'Beta, not selected',
    );
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>(
          'handrail-channel-public-channels-alpha-semantics',
        )),
      ),
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>(
        'handrail-channel-public-channels-beta-semantics',
      )),
    );
    await _pumpUntil(
      tester,
      () => find.text('Beta message').evaluate().isNotEmpty,
    );
    expectSemantics(
      find.byKey(const ValueKey<String>(
        'handrail-workspace-composer-beta',
      )),
      'Message composer',
    );
    final send = find.byKey(
      const ValueKey<String>('handrail-message-composer-send'),
    );
    expectSemantics(send, 'Send message');

    final input = find.byKey(
      const ValueKey<String>('handrail-message-composer-input'),
    );
    expectSemantics(input, 'Message input');

    final search = find.byKey(
      const ValueKey<String>('handrail-workspace-search'),
    );
    expectSemantics(search, 'Search messages');
    await tester.tap(search);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-workspace-panel-page')),
      findsOneWidget,
    );
    final searchInput = find.byKey(
      const ValueKey<String>('handrail-message-search-field'),
    );
    expectSemantics(searchInput, 'Search conversations and messages');
    await tester.enterText(searchInput, 'private project');
    await tester.pump(const Duration(milliseconds: 301));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-message-search-error'))
          .evaluate()
          .isNotEmpty,
    );
    final retry = find.byKey(
      const ValueKey<String>('handrail-message-search-retry'),
    );
    expectSemantics(retry, 'Retry');
    expect(find.text('Could not search messages.'), findsOneWidget);
    expect(find.textContaining(rawFailure), findsNothing);

    await tester.tap(retry);
    await _pumpUntil(
      tester,
      () =>
          searchAttempts == 2 &&
          find
              .byKey(const ValueKey<String>('handrail-message-search-empty'))
              .evaluate()
              .isNotEmpty,
    );
    expect(_primaryFocusIsWithin(tester, searchInput), isTrue);
    final close = find.byKey(
      const ValueKey<String>('handrail-workspace-close-panel'),
    );
    expectSemantics(close, 'Close panel');

    await tester.tap(close);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>('handrail-workspace-search')),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('opens a thread panel from a zero-reply message', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WorkspaceTransport(includeThreadSummary: false);
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: const HandrailChatWorkspace(initialConversationId: _alpha),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-reply-root-alpha'))
          .evaluate()
          .isNotEmpty,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-reply-root-alpha')),
    );
    await _pumpUntil(
      tester,
      () => find.byType(HandrailThreadView).evaluate().isNotEmpty,
    );

    final thread = tester.widget<HandrailThreadView>(
      find.byType(HandrailThreadView),
    );
    expect(thread.rootMessageId, _root);
    expect(
      transport.requests.any(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/messages/${_root.value}/thread'),
      ),
      isTrue,
    );
  });

  testWidgets('forward picker cancel sends no command and keeps selection',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WorkspaceTransport();
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _alpha,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-forward-root-alpha'))
          .evaluate()
          .isNotEmpty,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-root-alpha')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-dialog')),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-cancel')),
    );
    await tester.pumpAndSettle();

    expect(
      transport.requests.where(
        (request) => request.uri.path.endsWith('/messages/forward'),
      ),
      isEmpty,
    );
    expect(key.currentState!.selectedConversationId, _alpha);
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-dialog')),
      findsNothing,
    );
  });

  testWidgets(
      'forward sends exact identities once and selects authoritative result',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<HandrailChatHttpResponse>();
    final transport = _WorkspaceTransport(
      forwardMessage: (_) => pending.future,
      includeForwardedMessage: true,
    );
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _alpha,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-forward-root-alpha'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-root-alpha')),
    );
    await tester.pump();
    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-forward-destination-beta'),
    ));
    await tester.pump();
    final submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('handrail-forward-submit')),
    );
    submit.onPressed!();
    submit.onPressed!();
    await _pumpUntil(
      tester,
      () => transport.forwardMessageRequests.length == 1,
    );

    final request = transport.forwardMessageRequests.single;
    expect(_requestBody(request), <String, Object?>{
      'operation': 'forward_message.v1',
      'sourceMessageId': _root.value,
      'destinationConversationId': _beta.value,
      'clientCorrelationId': 'workspace-forward-correlation',
      'idempotencyKey': 'workspace-idempotency-key',
    });
    expect(key.currentState!.selectedConversationId, _alpha);
    expect(
      find.byKey(const ValueKey<String>('handrail-forward-progress')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Forwarding message'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('handrail-forward-submit')),
          )
          .onPressed,
      isNull,
    );

    pending.complete(_jsonResponse(_forwardResult(_requestBody(request))));
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == _beta,
    );
    await _pumpUntil(
      tester,
      () => find.text('Forwarded Alpha message').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('handrail-forward-dialog')),
      findsNothing,
    );
    expect(find.text('Beta'), findsWidgets);
    expect(transport.forwardMessageRequests, hasLength(1));
    semantics.dispose();
  });

  testWidgets(
      'forward failure is sanitized, stays put, and can be retried safely',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const rawFailure = 'upstream request body and transport trace';
    var attempts = 0;
    final transport = _WorkspaceTransport(
      includeForwardedMessage: true,
      forwardMessage: (request) async {
        attempts += 1;
        if (attempts == 1) {
          return _jsonResponse(
            const <String, Object?>{'error': rawFailure},
            statusCode: 500,
          );
        }
        return _jsonResponse(_forwardResult(_requestBody(request)));
      },
    );
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final key = GlobalKey<HandrailChatWorkspaceState>();
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        key: key,
        initialConversationId: _alpha,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-forward-root-alpha'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-root-alpha')),
    );
    await tester.pump();
    await tester.tap(find.byKey(
      const ValueKey<String>('handrail-forward-destination-beta'),
    ));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-submit')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-forward-error'))
          .evaluate()
          .isNotEmpty,
    );

    expect(key.currentState!.selectedConversationId, _alpha);
    expect(
      find.bySemanticsLabel("Message couldn't be forwarded. Try again."),
      findsOneWidget,
    );
    expect(find.textContaining(rawFailure), findsNothing);
    final retry = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('handrail-forward-submit')),
    );
    expect(retry.onPressed, isNotNull);
    expect(retry.focusNode!.hasFocus, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-forward-submit')),
    );
    await _pumpUntil(
      tester,
      () => key.currentState?.selectedConversationId == _beta,
    );

    expect(transport.forwardMessageRequests, hasLength(2));
    expect(find.textContaining(rawFailure), findsNothing);
    expect(find.text('Forwarded Alpha message'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('forwards host mention configuration to the composer',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _client(_WorkspaceTransport());
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    await client.initialize();
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(controller.dispose);
    final mentions = HandrailMessageMentionConfiguration(
      searchDirectory: (_) async => HandrailMemberDirectoryPage(rows: const []),
      resolveUser: (_) async => null,
    );

    await tester.pumpWidget(_host(
      client,
      width: 1200,
      child: HandrailChatWorkspace(
        initialConversationId: _alpha,
        conversationListController: controller,
        mentions: mentions,
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.byType(HandrailMessageComposer).evaluate().isNotEmpty,
      diagnostic: () =>
          'list=${controller.state.status}/${controller.state.error?.message}',
    );

    expect(
      tester
          .widget<HandrailMessageComposer>(
            find.byType(HandrailMessageComposer),
          )
          .mentions,
      same(mentions),
    );
  });

  testWidgets(
      'propagates overrides and exposes configured search, member, reaction, huddle, and thread surfaces',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WorkspaceTransport();
    final client = _client(transport);
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(controller.dispose);
    final delegatedThreads = <ConversationId>[];
    final delegates = ChatApplicationDelegates(
      openThread: (threadId) async {
        delegatedThreads.add(threadId);
        return ChatApplicationDelegateResult.handled;
      },
      openMessageSearchHit: (_) async => ChatApplicationDelegateResult.handled,
    );
    final observedSpacing = <double>[];
    final builders = ChatWidgetBuilders(
      channel: (context, input) => Text('Channel ${input.item.displayName}'),
      message: (context, input) {
        observedSpacing.add(HandrailChatTheme.of(context).spacing.large);
        return Text('Built ${input.message.content?.text}');
      },
      emptyConversation: (_, __) => const Text('Built empty'),
      loading: (_, input) => Text('Built loading ${input.target.name}'),
      error: (_, input) => Text('Built error ${input.message}'),
    );
    final members = HandrailWorkspaceMemberConfiguration(
      searchDirectory: (_) async => HandrailMemberDirectoryPage(rows: const []),
      authorization: const HandrailMemberPickerAuthorization(),
    );
    final key = GlobalKey<HandrailChatWorkspaceState>();

    Widget workspace(ChatApplicationDelegates currentDelegates) => _host(
          client,
          width: 1200,
          child: HandrailChatWorkspace(
            key: key,
            initialConversationId: _alpha,
            conversationListController: controller,
            builders: builders,
            delegates: currentDelegates,
            theme: const HandrailChatTheme(
              spacing: HandrailChatSpacing(large: 41),
            ),
            messageSearch: (_) async =>
                HandrailMessageSearchPage(hits: const []),
            members: members,
            availableReactions: const [
              HandrailReactionOption(reactionKey: 'wave', label: 'Wave'),
            ],
            huddleController: (client, conversationId) =>
                client.huddles.forConversation(conversationId),
          ),
        );

    await tester.pumpWidget(workspace(delegates));
    await _pumpUntil(
        tester, () => find.text('Built Alpha message').evaluate().isNotEmpty);
    expect(find.text('Channel Alpha'), findsOneWidget);
    expect(observedSpacing, contains(41));
    expect(key.currentState!.debugOwnsConversationListController, isFalse);
    expect(key.currentState!.debugConversationListController, same(controller));
    final composer = tester.widget<HandrailMessageComposer>(
      find.byType(HandrailMessageComposer),
    );
    expect(composer.delegates, same(delegates));
    for (final action in <String>['search', 'members', 'huddle']) {
      expect(
        find.ancestor(
          of: find.byKey(ValueKey<String>('handrail-workspace-$action')),
          matching: find.byType(HandrailChannelHeader),
        ),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-search')),
    );
    await tester.pump();
    final search = tester.widget<HandrailMessageSearch>(
      find.byType(HandrailMessageSearch),
    );
    expect(search.applicationDelegates, same(delegates));
    await _closePanel(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-members')),
    );
    await tester.pump();
    expect(find.byType(HandrailMemberPicker), findsOneWidget);
    await _closePanel(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-add-reaction-root-alpha')),
    );
    await tester.pump();
    expect(find.byType(HandrailReactionPicker), findsOneWidget);
    expect(find.text('Wave'), findsOneWidget);
    await _closePanel(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-huddle')),
    );
    await tester.pump();
    expect(find.byType(HandrailHuddlePanel), findsOneWidget);
    await _closePanel(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-thread-root-alpha')),
    );
    await _pumpUntil(
      tester,
      () => delegatedThreads.isNotEmpty,
      diagnostic: () =>
          'thread=${client.threads.forRoot(_root).state}; requests='
          '${transport.requests.map((request) => '${request.method} ${request.uri.path}').toList()}',
    );
    expect(delegatedThreads, [_thread]);
    expect(find.byType(HandrailThreadView), findsNothing);

    await tester.pumpWidget(workspace(const ChatApplicationDelegates()));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-thread-root-alpha')),
    );
    await _pumpUntil(
        tester, () => find.byType(HandrailThreadView).evaluate().isNotEmpty);
    await _pumpUntil(
        tester, () => find.text('Built Thread reply').evaluate().isNotEmpty);
    final thread = tester.widget<HandrailThreadView>(
      find.byType(HandrailThreadView),
    );
    expect(thread.builders, same(builders));
  });

  testWidgets(
      'renders loading, retryable error, access, and unavailable states',
      (tester) async {
    final pending = Completer<HandrailChatHttpResponse>();
    final loadingTransport = _WorkspaceTransport(listPending: pending);
    final loadingClient = _client(loadingTransport);
    addTearDown(loadingClient.dispose);
    final builders = ChatWidgetBuilders(
      loading: (_, input) => Text('Loading ${input.target.name}'),
      error: (context, input) => Column(
        children: [
          Text('Error ${input.message}'),
          TextButton(
            onPressed: input.conversationListActions?.retry,
            child: const Text('Retry workspace'),
          ),
        ],
      ),
    );
    await tester.pumpWidget(_host(
      loadingClient,
      width: 900,
      child: HandrailChatWorkspace(builders: builders),
    ));
    expect(find.text('Loading conversationList'), findsOneWidget);
    pending.complete(_jsonResponse(conversationListPage()));
    await _pumpUntil(
        tester, () => find.text('No conversations').evaluate().isNotEmpty);

    final retryTransport = _WorkspaceTransport(
      listResponses: Queue.of([
        _jsonResponse(const {'error': 'failed'}, statusCode: 500),
        _jsonResponse(_listPage()),
      ]),
    );
    final retryClient = _client(retryTransport);
    addTearDown(retryClient.dispose);
    final retryController = ChatConversationListController(
      client: retryClient,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(retryController.dispose);
    await tester.pumpWidget(_host(
      retryClient,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: retryController,
        builders: builders,
      ),
    ));
    await _pumpUntil(
      tester,
      () => retryController.state.status == ChatConversationListStatus.error,
      diagnostic: () => 'state=${retryController.state.status}; '
          'requests=${retryTransport.requests.length}',
    );
    expect(find.textContaining('Error '), findsOneWidget);
    await tester.tap(find.text('Retry workspace'));
    await _pumpUntil(tester,
        () => find.byType(HandrailMessageComposer).evaluate().isNotEmpty);

    final deniedClient = _client(_WorkspaceTransport(
      listResponses: Queue.of([
        _jsonResponse(const {'error': 'denied'}, statusCode: 403),
      ]),
    ));
    addTearDown(deniedClient.dispose);
    final deniedKey = GlobalKey<HandrailChatWorkspaceState>();
    await tester.pumpWidget(_host(
      deniedClient,
      width: 900,
      child: HandrailChatWorkspace(key: deniedKey),
    ));
    await _pumpUntil(
      tester,
      () =>
          deniedKey
              .currentState?.debugConversationListController?.state.status ==
          ChatConversationListStatus.accessDenied,
      diagnostic: () =>
          'state=${deniedKey.currentState?.debugConversationListController?.state.status}',
    );
    expect(find.text('Chat access denied'), findsOneWidget);

    final revokedTransport = _WorkspaceTransport(
      listResponses: Queue.of([
        _jsonResponse(_listPage()),
        _jsonResponse(const {'error': 'revoked'}, statusCode: 403),
      ]),
    );
    final revokedClient = _client(revokedTransport);
    addTearDown(revokedClient.dispose);
    final revokedController = ChatConversationListController(
      client: revokedClient,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(revokedController.dispose);
    await tester.pumpWidget(_host(
      revokedClient,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: revokedController,
      ),
    ));
    await _pumpUntil(tester, () => revokedController.state.isReady);
    await tester.runAsync(revokedController.refresh);
    await tester.pump();
    expect(find.text('Chat access revoked'), findsOneWidget);

    final disposedClient = _client(_WorkspaceTransport());
    addTearDown(disposedClient.dispose);
    final disposedController = ChatConversationListController(
      client: disposedClient,
      scope: const OrganizationConversationSnapshotScope(),
    );
    await tester.pumpWidget(_host(
      disposedClient,
      width: 900,
      child: HandrailChatWorkspace(
        conversationListController: disposedController,
      ),
    ));
    await _pumpUntil(tester, () => disposedController.state.isReady);
    await disposedController.dispose();
    await tester.pump();
    expect(find.text('Chat unavailable'), findsOneWidget);
  });

  testWidgets(
      'keeps keyboard traversal ordered from navigation through actions',
      (tester) async {
    final client = _client(_WorkspaceTransport());
    _seedConversation(client, _alpha, 'Alpha', latestSequence: 1);
    addTearDown(client.dispose);
    await tester.pumpWidget(_host(
      client,
      width: 1100,
      child: HandrailChatWorkspace(
        initialConversationId: _alpha,
        messageSearch: (_) async => HandrailMessageSearchPage(hits: const []),
        members: HandrailWorkspaceMemberConfiguration(
          searchDirectory: (_) async =>
              HandrailMemberDirectoryPage(rows: const []),
          authorization: const HandrailMemberPickerAuthorization(),
        ),
        huddleController: (client, id) => client.huddles.forConversation(id),
      ),
    ));
    await _pumpUntil(
      tester,
      () =>
          find.text('Alpha message').evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey<String>(
                'handrail-channel-public-channels-alpha',
              ))
              .evaluate()
              .isNotEmpty &&
          find
              .byKey(const ValueKey<String>(
                'handrail-channel-public-channels-beta',
              ))
              .evaluate()
              .isNotEmpty,
    );

    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>(
          'handrail-channel-public-channels-alpha',
        )),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>(
          'handrail-channel-public-channels-alpha-star',
        )),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>(
          'handrail-channel-public-channels-beta',
        )),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>('handrail-workspace-search')),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>('handrail-workspace-members')),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      _primaryFocusIsWithin(
        tester,
        find.byKey(const ValueKey<String>('handrail-workspace-huddle')),
      ),
      isTrue,
    );
  });

  testWidgets(
      'disposes only its internally created conversation-list controller',
      (tester) async {
    final transport = _WorkspaceTransport(
      listResponses: Queue.of([
        _jsonResponse(_listPage()),
        _jsonResponse(_listPage()),
      ]),
    );
    final client = _client(transport);
    addTearDown(client.dispose);
    final ownedKey = GlobalKey<HandrailChatWorkspaceState>();
    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(key: ownedKey),
    ));
    await _pumpUntil(
      tester,
      () =>
          ownedKey
              .currentState?.debugConversationListController?.state.isReady ??
          false,
    );
    final owned = ownedKey.currentState!.debugConversationListController!;
    expect(ownedKey.currentState!.debugOwnsConversationListController, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(owned.state.isDisposed, isTrue);

    final external = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    addTearDown(external.dispose);
    await tester.pumpWidget(_host(
      client,
      width: 900,
      child: HandrailChatWorkspace(conversationListController: external),
    ));
    await _pumpUntil(tester, () => external.state.isReady);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(external.state.isDisposed, isFalse);
  });
}

Widget _host(
  HandrailChatClient client, {
  required double width,
  required Widget child,
  double height = 700,
  TextScaler? textScaler,
}) =>
    MaterialApp(
      theme: widgetEvidenceTheme,
      home: ChatScope(
        key: ValueKey<Object>(client),
        client: client,
        child: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Center(
                child: SizedBox(width: width, height: height, child: child),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _closePanel(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('handrail-workspace-close-panel')),
  );
  await tester.pump();
}

Future<void> _selectGroupDirectUsers(
  WidgetTester tester,
  List<UserId> userIds,
) async {
  await _pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey<String>('handrail-create-group-direct'))
        .evaluate()
        .isNotEmpty,
  );
  await tester.tap(
    find.byKey(const ValueKey<String>('handrail-create-group-direct')),
  );
  await _pumpUntil(
    tester,
    () => userIds.every(
      (userId) => find
          .byKey(ValueKey<String>(
            'handrail-create-group-direct-user-${userId.value}',
          ))
          .evaluate()
          .isNotEmpty,
    ),
  );
  for (final userId in userIds) {
    await tester.tap(
      find.byKey(ValueKey<String>(
        'handrail-create-group-direct-user-${userId.value}',
      )),
    );
    await tester.pump();
  }
}

bool _primaryFocusIsWithin(WidgetTester tester, Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context as Element?;
  if (focused == null) return false;
  final target = tester.element(finder);
  if (identical(focused, target)) return true;
  var found = false;
  focused.visitAncestorElements((ancestor) {
    if (identical(ancestor, target)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

HandrailChatClient _client(
  HandrailChatHttpTransport transport, {
  Map<String, bool> requestedCapabilities = const <String, bool>{},
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'workspace-token',
      transport: transport,
      requestedCapabilities: requestedCapabilities,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: () => 'workspace-idempotency-key',
      generateForwardMessageCorrelationId: () =>
          'workspace-forward-correlation',
      generateConversationClientRequestId: () => 'workspace-client-request',
    );

void _seedConversation(
  HandrailChatClient client,
  ConversationId id,
  String name, {
  required int latestSequence,
}) {
  client.normalizedState.hydrateConversationDetail(
    ConversationDetailSnapshot.fromJson(_conversationDetail(
      id: id,
      name: name,
      latestSequence: latestSequence,
    )),
  );
}

Map<String, Object?> _conversationDetail({
  required ConversationId id,
  required String name,
  required int latestSequence,
  String visibility = 'public',
  HostEntityReference? entity,
}) =>
    {
      'kind': 'conversation_detail',
      'conversation': {
        'id': id.value,
        'tenantId': _tenant,
        'type': 'channel',
        'name': name,
        'visibility': visibility,
        if (entity != null) 'entity': entity.toJson(),
        'createdAt': _now,
        'updatedAt': _now,
        'latestSequence': latestSequence,
        'activityAt': _now,
        'unreadMentionCount': 0,
        'currentMember': {
          'tenantId': _tenant,
          'conversationId': id.value,
          'userId': _user,
          'role': 'member',
          'state': 'active',
          'joinedAt': _now,
          'updatedAt': _now,
        },
        'currentReadState': {
          'conversationId': id.value,
          'userId': _user,
          'lastReadSequence': 0,
          'updatedAt': _now,
        },
        'currentPreference': {
          'conversationId': id.value,
          'userId': _user,
          'notificationPreference': 'all',
          'isStarred': false,
          'mute': {'muted': false},
          'updatedAt': _now,
        },
        'activeMemberUserIds': [_user],
        'memberUserIds': [_user],
      },
      '_meta': conversationListMetadata(),
    };

Map<String, Object?> _channelCreationResult({
  required ConversationId id,
  required String name,
  required String visibility,
  required String clientRequestId,
  HostEntityReference? entity,
}) =>
    {
      'operation': 'create_conversation',
      'type': 'channel',
      'reconciliationStatus': 'created',
      'clientRequestId': clientRequestId,
      'conversation': _conversationDetail(
        id: id,
        name: name,
        latestSequence: 0,
        visibility: visibility,
        entity: entity,
      ),
    };

Map<String, Object?> _directCreationResult(
  Map<String, Object?> requestBody, {
  required ConversationId conversationId,
  required String status,
}) {
  final intendedUserIds =
      (requestBody['intendedMemberUserIds']! as List<Object?>)
          .cast<String>()
          .map(UserId.new)
          .toList(growable: false);
  final identity = deriveCanonicalParticipantIdentity(
    const UserId('user-actor'),
    intendedUserIds,
  );
  final result = conversationCreationResultFixture(
    'direct',
    status,
    clientRequestId: requestBody['clientRequestId']! as String,
    participantUserIds:
        identity.participantUserIds.map((id) => id.value).toList(),
    participantKey: identity.key,
  );
  final detail = result['conversation']! as Map<String, Object?>;
  final conversation = detail['conversation']! as Map<String, Object?>;
  conversation['id'] = conversationId.value;
  conversation['memberUserIds'] =
      identity.participantUserIds.map((id) => id.value).toList();
  for (final field in <String>[
    'currentMember',
    'currentReadState',
    'currentPreference',
  ]) {
    (conversation[field]! as Map<String, Object?>)['conversationId'] =
        conversationId.value;
  }
  return result;
}

Map<String, Object?> _groupDirectCreationResult(
  Map<String, Object?> requestBody, {
  required ConversationId conversationId,
  required String status,
}) {
  final intendedUserIds =
      (requestBody['intendedMemberUserIds']! as List<Object?>)
          .cast<String>()
          .map(UserId.new)
          .toList(growable: false);
  final identity = deriveCanonicalParticipantIdentity(
    const UserId('user-actor'),
    intendedUserIds,
  );
  final result = conversationCreationResultFixture(
    'group_direct',
    status,
    clientRequestId: requestBody['clientRequestId']! as String,
    participantUserIds:
        identity.participantUserIds.map((id) => id.value).toList(),
    participantKey: identity.key,
  );
  final detail = result['conversation']! as Map<String, Object?>;
  final conversation = detail['conversation']! as Map<String, Object?>;
  conversation['id'] = conversationId.value;
  conversation['memberUserIds'] =
      identity.participantUserIds.map((id) => id.value).toList();
  for (final field in <String>[
    'currentMember',
    'currentReadState',
    'currentPreference',
  ]) {
    (conversation[field]! as Map<String, Object?>)['conversationId'] =
        conversationId.value;
  }
  return result;
}

Map<String, Object?> _requestBody(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

Map<String, Object?> _listPage() => conversationListPage(items: [
      _workspaceListSummary(_alpha, 'Alpha'),
      _workspaceListSummary(_beta, 'Beta'),
    ]);

Map<String, Object?> _workspaceListSummary(ConversationId id, String name) =>
    conversationListSummary(id: id.value, name: name, latestSequence: 1)
      ..addAll({
        'unreadMentionCount': 0,
        'activeMemberUserIds': [conversationListTestUser],
      });

Map<String, Object?> _timelinePage(
  ConversationId id, {
  bool includeThreadSummary = true,
  bool includeForwardedMessage = false,
}) =>
    {
      'conversationId': id.value,
      'messages': [
        {
          'id': id == _alpha ? _root.value : 'message-${id.value}',
          'tenantId': _tenant,
          'conversationId': id.value,
          'author': {'type': 'user', 'userId': _user},
          'sequence': 1,
          'createdAt': _now,
          'updatedAt': _now,
          'revision': {'revision': 1},
          'content': {
            'format': 'plain',
            'text': id == _alpha ? 'Alpha message' : 'Beta message',
          },
          if (id == _alpha && includeThreadSummary)
            'threadSummary': {
              'threadId': _thread.value,
              'replyCount': 1,
              'participantIds': [_user],
              'unreadCount': 0,
              'lastReplyAt': _now,
            },
          'isThreadRoot': id == _alpha && includeThreadSummary,
          'reactions': const <Object?>[],
          'attachmentMetadata': const <Object?>[],
        },
        if (id == _beta && includeForwardedMessage) ...[
          {
            ..._forwardedMessage(),
            'isThreadRoot': false,
            'reactions': const <Object?>[],
            'attachmentMetadata': const <Object?>[],
          },
        ],
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'workspace-${id.value}'},
      },
    };

Map<String, Object?> _forwardResult(Map<String, Object?> request) =>
    <String, Object?>{
      'operation': 'forward_message.v1',
      'reconciliationStatus': 'applied',
      'clientCorrelationId': request['clientCorrelationId'],
      'destinationConversationId': request['destinationConversationId'],
      'message': _forwardedMessage(
        destinationConversationId:
            ConversationId(request['destinationConversationId']! as String),
        sourceMessageId: MessageId(request['sourceMessageId']! as String),
      ),
      'canonicalRevision': 1,
    };

Map<String, Object?> _forwardedMessage({
  ConversationId destinationConversationId = _beta,
  MessageId sourceMessageId = _root,
}) =>
    <String, Object?>{
      'id': 'forwarded-beta',
      'tenantId': _tenant,
      'conversationId': destinationConversationId.value,
      'author': const <String, Object?>{
        'type': 'user',
        'userId': _user,
      },
      'sequence': 2,
      'createdAt': _now,
      'updatedAt': _now,
      'revision': const <String, Object?>{'revision': 1},
      'content': <String, Object?>{
        'format': 'plain',
        'text': 'Forwarded Alpha message',
        'forwarded': <String, Object?>{
          'sourceMessageId': sourceMessageId.value,
          'originalAuthor': const <String, Object?>{
            'userId': _user,
            'displayName': 'Current User',
          },
          'originalCreatedAt': _now,
        },
      },
    };

Map<String, Object?> _threadTimelinePage() => {
      'conversationId': _thread.value,
      'messages': [
        {
          'id': 'thread-reply',
          'tenantId': _tenant,
          'conversationId': _thread.value,
          'author': {'type': 'user', 'userId': _user},
          'sequence': 1,
          'createdAt': _now,
          'updatedAt': _now,
          'revision': {'revision': 1},
          'content': {'format': 'plain', 'text': 'Thread reply'},
          'isThreadRoot': false,
          'reactions': const <Object?>[],
          'attachmentMetadata': const <Object?>[],
        },
      ],
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {'eventId': 'workspace-thread'},
      },
    };

HandrailChatHttpResponse _jsonResponse(Object? body, {int statusCode = 200}) =>
    HandrailChatHttpResponse(statusCode: statusCode, body: jsonEncode(body));

class _WorkspaceTransport implements HandrailChatHttpTransport {
  _WorkspaceTransport({
    Queue<HandrailChatHttpResponse>? listResponses,
    Queue<HandrailChatHttpResponse>? messageSearchResponses,
    this.enabledFeatures = const <String, bool>{},
    this.listPending,
    this.includeThreadSummary = true,
    this.includeForwardedMessage = false,
    this.createChannel,
    this.createDirect,
    this.createGroupDirect,
    this.forwardMessage,
  })  : listResponses = listResponses ?? Queue.of([_jsonResponse(_listPage())]),
        messageSearchResponses =
            messageSearchResponses ?? Queue<HandrailChatHttpResponse>();

  final Queue<HandrailChatHttpResponse> listResponses;
  final Queue<HandrailChatHttpResponse> messageSearchResponses;
  final Map<String, bool> enabledFeatures;
  final Completer<HandrailChatHttpResponse>? listPending;
  final bool includeThreadSummary;
  final bool includeForwardedMessage;
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      createChannel;
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      createDirect;
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      createGroupDirect;
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)?
      forwardMessage;
  final List<HandrailChatHttpRequest> requests = [];

  List<HandrailChatHttpRequest> get messageSearchRequests => requests
      .where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/messages/search'),
      )
      .toList(growable: false);

  List<HandrailChatHttpRequest> get forwardMessageRequests => requests
      .where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/messages/forward'),
      )
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return _jsonResponse(<String, Object?>{
        'packageVersion': '0.1.3',
        'protocolVersion': handrailChatProtocolVersion,
        'schemaVersion': 1,
        'enabledFeatures': enabledFeatures,
        'supportedProtocolRange': <String, Object?>{
          'minimumVersion': handrailChatProtocolVersion - 1,
          'maximumVersion': handrailChatProtocolVersion,
        },
      });
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/search')) {
      if (messageSearchResponses.isNotEmpty) {
        return messageSearchResponses.removeFirst();
      }
      return _jsonResponse(
        const <String, Object?>{'error': 'unexpected message search'},
        statusCode: 500,
      );
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/forward')) {
      final handler = forwardMessage;
      if (handler != null) return handler(request);
      return _jsonResponse(
        const <String, Object?>{'error': 'unexpected message forward'},
        statusCode: 500,
      );
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/messages')) {
      final segments = request.uri.pathSegments;
      final id = ConversationId(segments[segments.length - 2]);
      return _jsonResponse(
        id == _thread
            ? _threadTimelinePage()
            : _timelinePage(
                id,
                includeThreadSummary: includeThreadSummary,
                includeForwardedMessage: includeForwardedMessage,
              ),
      );
    }
    if (request.method == 'GET' &&
        request.uri.pathSegments.contains('conversations') &&
        !request.uri.path.endsWith('/conversations')) {
      final id = ConversationId(request.uri.pathSegments.last);
      if (id == _thread) {
        return _jsonResponse(threadCreationResultFixture('existing_for_root',
          parentConversationId: _alpha.value, rootMessageId: _root.value,
          threadId: _thread.value, summaryThreadId: _thread.value)['conversation']);
      }
      return _jsonResponse(_conversationDetail(
        id: id,
        name: id == _alpha ? 'Alpha' : 'Beta',
        latestSequence: 1,
      ));
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/${_root.value}/thread')) {
      return _jsonResponse(
        threadCreationResultFixture(
          'created',
          parentConversationId: _alpha.value,
          rootMessageId: _root.value,
          threadId: _thread.value,
          summaryThreadId: _thread.value,
        ),
        statusCode: 201,
      );
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/conversations')) {
      final body = _requestBody(request);
      final handler = switch (body['type']) {
        'direct' => createDirect,
        'group_direct' => createGroupDirect,
        _ => createChannel,
      };
      if (handler != null) return handler(request);
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/conversations')) {
      final pending = listPending;
      if (pending != null && !pending.isCompleted) return pending.future;
      return listResponses.removeFirst();
    }
    return _jsonResponse(const {'error': 'unexpected fixture request'},
        statusCode: 400);
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate,
    {String Function()? diagnostic}) async {
  for (var attempt = 0; attempt < 120 && !predicate(); attempt += 1) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'Workspace fixture did not settle. ${diagnostic?.call() ?? ''}',
  );
  await tester.pump();
}

// Reuse discovery and workspace fixtures; only the preference boundary is added.
class _HeaderDiscoveryTransport extends _DiscoveryTransport {
  final preferenceWrites = <Map<String, Object?>>[];
  Completer<void>? pendingPreference;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.method == 'PATCH' && request.uri.path.endsWith('/preference')) {
      final input = _requestBody(request);
      preferenceWrites.add(input);
      await pendingPreference?.future;
      final desired = {
        'notificationPreference': input['notificationPreference'],
        'isStarred': input['isStarred'],
        'mute': input['mute'],
      };
      return _jsonResponse({
        'operation': 'update_conversation_preference',
        'reconciliationStatus': 'applied',
        'conversationId': input['conversationId'],
        'expectedPreferenceRevision': input['expectedPreferenceRevision'],
        'idempotencyKey': input['idempotencyKey'],
        'requestedPreference': desired,
        'preferenceRevision': (input['expectedPreferenceRevision']! as int) + 1,
        'preference': {...desired, 'updatedAt': _now},
      });
    }
    return super.send(request);
  }
}

final class _SettingsWorkspaceTransport extends _WorkspaceTransport {
  _SettingsWorkspaceTransport()
    : super(
        enabledFeatures: const {replyStylePreferenceFeature: true},
        includeThreadSummary: false,
        listResponses: Queue.of([
          _jsonResponse(
            jsonDecode(
                  jsonEncode(_listPage())
                      .replaceAll(conversationListTestTenant, _tenant)
                      .replaceAll(conversationListTestUser, _user),
                )
                as Map<String, dynamic>,
          ),
        ]),
      );
  Map<String, Object?> preference = style.absent;
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.uri.path.endsWith('/preferences/reply-style')) {
      requests.add(request);
      if (request.method == 'GET') return style.response(preference);
      final input = jsonDecode(request.body!) as Map<String, dynamic>;
      final result = style.result(input);
      preference = result['preference']! as Map<String, Object?>;
      return style.response(result);
    }
    return super.send(request);
  }
}
