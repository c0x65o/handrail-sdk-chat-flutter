import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

const _conversationA = ConversationId('conversation-a');
const _conversationB = ConversationId('conversation-b');

void main() {
  testWidgets('normalizes the query and preserves explicit typed filters', (
    tester,
  ) async {
    final requests = <HandrailMessageSearchRequest>[];
    final sourceConversationIds = <ConversationId>[_conversationA];
    final filters = HandrailMessageSearchFilter(
      conversationIds: sourceConversationIds,
      authorUserIds: const [UserId('author-a')],
      sentAfter: const IsoTimestamp('2026-08-01T00:00:00.000Z'),
      sentBefore: const IsoTimestamp('2026-08-31T23:59:59.999Z'),
      includeConversationHits: false,
    );
    sourceConversationIds.add(_conversationB);

    await _pumpSearch(
      tester,
      filters: filters,
      debounce: const Duration(milliseconds: 100),
      pageSize: 17,
      search: (request) async {
        requests.add(request);
        return HandrailMessageSearchPage(hits: const []);
      },
    );

    expect(
      find.byKey(const ValueKey('handrail-message-search-initial')),
      findsOneWidget,
    );
    expect(requests, isEmpty);

    await tester.enterText(_searchField, '  Cafe\u0301 \n  status  ');
    await tester.pump(const Duration(milliseconds: 99));
    expect(requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.query, 'Café status');
    expect(request.pageSize, 17);
    expect(request.pageToken, isNull);
    expect(request.filters, same(filters));
    expect(request.filters.conversationIds, [_conversationA]);
    expect(request.filters.authorUserIds, const [UserId('author-a')]);
    expect(
      request.filters.sentAfter,
      const IsoTimestamp('2026-08-01T00:00:00.000Z'),
    );
    expect(request.filters.includeConversationHits, isFalse);
    expect(request.filters.includeMessageHits, isTrue);
  });

  testWidgets('debounces requests and suppresses stale completions', (
    tester,
  ) async {
    final requests = <HandrailMessageSearchRequest>[];
    final oldPage = Completer<HandrailMessageSearchPage>();
    final newPage = Completer<HandrailMessageSearchPage>();

    await _pumpSearch(
      tester,
      debounce: const Duration(milliseconds: 100),
      search: (request) {
        requests.add(request);
        return request.query == 'old' ? oldPage.future : newPage.future;
      },
    );

    await tester.enterText(_searchField, 'o');
    await tester.pump(const Duration(milliseconds: 40));
    await tester.enterText(_searchField, 'old');
    await tester.pump(const Duration(milliseconds: 99));
    expect(requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests.map((request) => request.query), ['old']);

    await tester.enterText(_searchField, 'new');
    await tester.pump(const Duration(milliseconds: 100));
    expect(requests.map((request) => request.query), ['old', 'new']);

    newPage.complete(
      HandrailMessageSearchPage(hits: [_messageHit('new', 'New result')]),
    );
    await tester.pump();
    expect(find.text('New result'), findsOneWidget);

    oldPage.complete(
      HandrailMessageSearchPage(hits: [_messageHit('old', 'Stale result')]),
    );
    await tester.pump();
    expect(find.text('New result'), findsOneWidget);
    expect(find.text('Stale result'), findsNothing);
  });

  testWidgets(
    'paginates, retries failures, removes duplicates, and stops token cycles',
    (tester) async {
      final requests = <HandrailMessageSearchRequest>[];
      final failedPage = Completer<HandrailMessageSearchPage>();
      var pageACalls = 0;

      await _pumpSearch(
        tester,
        initialQuery: 'roadmap',
        search: (request) {
          requests.add(request);
          if (request.pageToken == null) {
            return Future.value(
              HandrailMessageSearchPage(
                hits: [_messageHit('one', 'First message')],
                nextPageToken: 'page-a',
              ),
            );
          }
          if (request.pageToken == 'page-a') {
            pageACalls += 1;
            if (pageACalls == 1) return failedPage.future;
            return Future.value(
              HandrailMessageSearchPage(
                hits: [
                  _messageHit('one', 'Duplicate first message'),
                  _conversationHit('two', 'Second conversation'),
                ],
                nextPageToken: 'page-b',
              ),
            );
          }
          return Future.value(
            HandrailMessageSearchPage(
              hits: [_messageHit('three', 'Third message')],
              nextPageToken: 'page-a',
            ),
          );
        },
      );
      await tester.pump();

      await tester.tap(_loadMoreButton);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('handrail-message-search-loading-more')),
        findsOneWidget,
      );
      failedPage.completeError(StateError('temporary host failure'));
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey('handrail-message-search-pagination-error'),
        ),
        findsOneWidget,
      );

      await tester.tap(_retryButton);
      await tester.pump();
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Duplicate first message'), findsNothing);
      expect(find.text('Second conversation'), findsOneWidget);

      await tester.tap(_loadMoreButton);
      await tester.pump();
      expect(find.text('Third message'), findsOneWidget);
      expect(_loadMoreButton, findsNothing);
      expect(
        requests.map((request) => request.pageToken),
        [null, 'page-a', 'page-a', 'page-b'],
      );
    },
  );

  testWidgets(
      'renders host snippets as literal plain text and shows empty state',
      (tester) async {
    const unsafeLooking =
        '<script>alert(1)</script> **bold** [open](javascript:run())';
    await _pumpSearch(
      tester,
      initialQuery: 'markup',
      search: (request) async => HandrailMessageSearchPage(
        hits: request.query == 'markup'
            ? const [
                HandrailMessageSearchMessageHit(
                  messageId: MessageId('message-markup'),
                  conversationId: _conversationA,
                  title: 'Markup sample',
                  snippet: unsafeLooking,
                ),
              ]
            : const [],
      ),
    );
    await tester.pump();

    expect(find.text(unsafeLooking), findsOneWidget);
    expect(find.text('bold'), findsNothing);
    expect(find.byType(Image), findsNothing);

    await tester.enterText(_searchField, 'nothing');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('handrail-message-search-empty')),
      findsOneWidget,
    );
  });

  testWidgets('shows initial loading and retries an initial error', (
    tester,
  ) async {
    final firstPage = Completer<HandrailMessageSearchPage>();
    var calls = 0;
    await _pumpSearch(
      tester,
      initialQuery: 'invoice',
      search: (_) {
        calls += 1;
        if (calls == 1) return firstPage.future;
        return Future.value(
          HandrailMessageSearchPage(
            hits: [_conversationHit('invoice', 'Invoices')],
          ),
        );
      },
    );

    expect(
      find.byKey(
        const ValueKey('handrail-message-search-initial-loading'),
      ),
      findsOneWidget,
    );
    firstPage.completeError(StateError('search unavailable'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('handrail-message-search-error')),
      findsOneWidget,
    );

    await tester.tap(_retryButton);
    await tester.pump();
    expect(find.text('Invoices'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('routes pointer activation through the typed host delegate', (
    tester,
  ) async {
    final hit = _messageHit('open', 'Open this result');
    HandrailMessageSearchHit? opened;
    final delegates = ChatApplicationDelegates(
      openMessageSearchHit: (value) async {
        opened = value;
        return ChatApplicationDelegateResult.handled;
      },
    );

    expect(
      await const ChatApplicationDelegates().openMessageSearchHit(hit),
      ChatApplicationDelegateResult.unavailable,
    );
    await _pumpSearch(
      tester,
      initialQuery: 'open',
      delegates: delegates,
      search: (_) async => HandrailMessageSearchPage(hits: [hit]),
    );
    await tester.pump();
    await tester.tap(find.text('Open this result'));
    await tester.pump();

    expect(opened, same(hit));
    expect((opened as HandrailMessageSearchMessageHit).messageId,
        const MessageId('message-open'));
  });

  testWidgets('supports semantics and deterministic arrow-key activation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final opened = <HandrailMessageSearchHit>[];
    await _pumpSearch(
      tester,
      initialQuery: 'keyboard',
      autofocus: true,
      delegates: ChatApplicationDelegates(
        openMessageSearchHit: (hit) async {
          opened.add(hit);
          return ChatApplicationDelegateResult.handled;
        },
      ),
      search: (_) async => HandrailMessageSearchPage(
        hits: [
          _messageHit('first', 'First keyboard result'),
          _conversationHit('second', 'Second keyboard result'),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel('Search conversations and messages'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('2 search results'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp('message, First keyboard result.*Snippet first'),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(opened, hasLength(2));
    expect(opened[0], isA<HandrailMessageSearchMessageHit>());
    expect(opened[1], isA<HandrailMessageSearchConversationHit>());
    semantics.dispose();
  });

  testWidgets('disposal cancels debounce and ignores late search completion', (
    tester,
  ) async {
    final key = GlobalKey<HandrailMessageSearchState>();
    final latePage = Completer<HandrailMessageSearchPage>();
    var calls = 0;
    await _pumpSearch(
      tester,
      key: key,
      initialQuery: 'late',
      search: (_) {
        calls += 1;
        return latePage.future;
      },
    );
    final disposedState = key.currentState!;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(disposedState.debugRetainedHitCount, 0);

    latePage.complete(
      HandrailMessageSearchPage(hits: [_messageHit('late', 'Late result')]),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _pumpSearch(
      tester,
      debounce: const Duration(seconds: 1),
      search: (_) async {
        calls += 1;
        return HandrailMessageSearchPage(hits: const []);
      },
    );
    await tester.enterText(_searchField, 'cancel timer');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  test(
      'search surface has no client, state-store, or cache-scanning dependency',
      () {
    final widgetSource =
        File('lib/src/handrail_message_search.dart').readAsStringSync();
    final contractSource =
        File('lib/src/message_search.dart').readAsStringSync();
    final uiSource = File('lib/ui.dart').readAsStringSync();
    final combined = '$widgetSource\n$contractSource';

    expect(combined, isNot(contains("import 'handrail_chat_client.dart'")));
    expect(combined, isNot(contains('NormalizedSnapshotStore')));
    expect(combined, isNot(contains('.normalizedState')));
    expect(combined, isNot(contains('ApplicationChatStorage')));
    expect(combined, isNot(contains('dart:io')));
    expect(combined, isNot(contains('package:http')));
    expect(uiSource, contains("export 'src/handrail_message_search.dart';"));
    expect(uiSource, contains("export 'src/message_search.dart';"));
  });
}

Finder get _searchField =>
    find.byKey(const ValueKey('handrail-message-search-field'));
Finder get _loadMoreButton =>
    find.byKey(const ValueKey('handrail-message-search-load-more'));
Finder get _retryButton =>
    find.byKey(const ValueKey('handrail-message-search-retry'));

HandrailMessageSearchMessageHit _messageHit(String id, String title) =>
    HandrailMessageSearchMessageHit(
      messageId: MessageId('message-$id'),
      conversationId: _conversationA,
      title: title,
      snippet: 'Snippet $id',
      authorUserId: const UserId('author-a'),
      authorDisplayName: 'Ada',
    );

HandrailMessageSearchConversationHit _conversationHit(
  String id,
  String title,
) =>
    HandrailMessageSearchConversationHit(
      conversationId: ConversationId('conversation-$id'),
      title: title,
      snippet: 'Conversation snippet $id',
    );

Future<void> _pumpSearch(
  WidgetTester tester, {
  required HandrailMessageSearchDelegate search,
  ChatApplicationDelegates delegates = const ChatApplicationDelegates(),
  HandrailMessageSearchFilter filters = HandrailMessageSearchFilter.empty,
  Duration debounce = const Duration(milliseconds: 300),
  int pageSize = 50,
  String initialQuery = '',
  bool autofocus = false,
  Key? key,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: HandrailMessageSearch(
            key: key,
            search: search,
            applicationDelegates: delegates,
            filters: filters,
            searchDebounce: debounce,
            pageSize: pageSize,
            initialQuery: initialQuery,
            autofocusSearch: autofocus,
          ),
        ),
      ),
    ),
  );
}
