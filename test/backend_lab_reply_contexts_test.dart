import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

// Exercise the example host with the SDK's existing transport fixtures.
// ignore: avoid_relative_lib_imports
import '../example/lib/backend_lab/reply_contexts.dart';
import 'fixtures/existing_thread_opening_fixtures.dart';
import 'message_context_controller_test.dart' as f;
import 'reply_style_client_test.dart' as rt;

void main() {
  for (final kind in ['channel', 'direct', 'thread']) {
    for (final loaded in [true, false]) {
      testWidgets('backend host resolves $kind reply and jumps, loaded=$loaded',
          (tester) async {
        final socket = rt.Socket();
        final session = rt.sessionFor(socket);
        final http = f.Http();
        final client = (await tester
            .runAsync(() => f.clientFor(http, realtime: session)))!;
        final binding = BackendLabReplyContexts(client, session);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await binding.dispose();
        });
        final detail = existingThreadDetailFixture();
        final conversation = detail['conversation']! as Map<String, Object?>;
        if (kind != 'thread') {
          conversation['type'] = kind;
          conversation.remove('parentConversationId');
          conversation.remove('rootMessageId');
          conversation['memberUserIds'] = [f.user.value, 'alice'];
          conversation['activeMemberUserIds'] = [f.user.value, 'alice'];
          (conversation['currentMember']! as Map)['state'] = 'active';
          if (kind == 'direct') conversation.remove('name');
        }
        http.detail = (_) async => f.response(detail);
        http.value = f.context(text: 'Which launch date?');
        (http.value['message']! as Map)['author'] = {
          'type': 'user',
          'userId': 'alice'
        };
        final page = f.page(loaded ? [10, 20] : [20]);
        final messages = page['messages']! as List;
        if (loaded) {
          (messages.first as Map)['content'] = {
            'format': 'plain',
            'text': 'Which launch date?'
          };
        }
        (messages.last as Map)['content'] = {
          'format': 'plain',
          'text': 'Friday'
        };
        (messages.last as Map)['replyTo'] = {
          'messageId': f.sourceId.value,
          'notifyAuthor': true
        };
        http.timeline = (request) async => f.response(
            request.uri.queryParameters.containsKey('before') ||
                    request.uri.queryParameters.containsKey('after')
                ? f.page([])
                : page);
        final source = client.messageContexts.forMessage(f.request);
        await source.load();
        expect(http.reads, isEmpty); // No trusted session yet.
        await tester.runAsync(session.start);
        socket.accept(
            identity: const ChatReplyStyleIdentity(
          tenantId: f.tenant,
          userId: f.user,
        ));
        await _settle(tester);
        await tester.pumpWidget(MaterialApp(
          home: ChatScope(
              client: client,
              child: Scaffold(
                body: HandrailMessageTimeline(
                  conversationId: f.thread,
                  isConversationActive: false,
                ),
              )),
        ));
        await _settle(tester);
        expect(find.text('Reply to alice: Which launch date?'), findsOneWidget);
        expect(find.text('Original message unavailable'), findsNothing);
        expect(http.reads, hasLength(1));
        await tester.runAsync(source.retry); // Shared with the composer.
        await _settle(tester);
        expect(source.state.source!.content.text, 'Which launch date?');
        await tester.tap(find.text('Reply to alice: Which launch date?'));
        await _settle(tester);
        expect(FocusManager.instance.primaryFocus!.debugLabel,
            loaded ? 'Message message-reply' : 'Original reply source');
        if (!loaded) {
          expect(find.text('user-other: Source preview'), findsNothing);
          expect(find.text('alice: Which launch date?'), findsOneWidget);
          await tester.tap(find.byTooltip('Return to replies'));
          await _settle(tester);
        }
        final reads = http.reads.length;
        client.normalizedState.hydrateConversationDetail(
            ConversationDetailSnapshot.fromJson(detail));
        await _settle(tester);
        expect(http.reads, hasLength(reads));
        expect(source.state.status, ChatMessageContextStatus.available);

        await tester.runAsync(session.suspend);
        await _settle(tester);
        expect(source.state.source, isNull);
        await tester.runAsync(session.start);
        socket.accept(
            device: 'reconnected-device',
            identity: const ChatReplyStyleIdentity(
              tenantId: f.tenant,
              userId: f.user,
            ));
        await _settle(tester);
        expect(find.text('Reply to alice: Which launch date?'), findsOneWidget);

        // A host commit must not silently undo a source revocation.
        source.setAuthority(null);
        client.normalizedState
            .hydrateMessageTimeline(MessageTimelinePage.fromJson(
          page,
          request: MessageTimelineRequest(
            conversationId: f.thread,
            direction: MessageTimelineDirection.backward,
            limit: 50,
          ),
        ));
        await _settle(tester);
        expect(source.state.source, isNull);
        expect(find.text('Original message unavailable'), findsOneWidget);
      });
    }
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
