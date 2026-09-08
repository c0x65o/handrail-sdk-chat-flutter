import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/conversation_list_fixtures.dart';

void main() {
  test('pages an entity scope, deduplicates rows, and computes unread state',
      () async {
    final cursor = conversationListCursor('page-2');
    final transport = _QueueTransport()
      ..json(conversationListPage(
        scope: _entityScope,
        nextCursor: cursor,
        items: [
          conversationListSummary(
            id: 'alpha',
            name: 'Alpha',
            latestSequence: 8,
            lastReadSequence: 6,
          ),
        ],
      ))
      ..json(conversationListPage(
        scope: _entityScope,
        items: [
          conversationListSummary(
            id: 'alpha',
            name: 'Alpha renamed',
            latestSequence: 8,
            lastReadSequence: 6,
          ),
          conversationListSummary(
            id: 'beta',
            name: 'Beta',
            latestSequence: 7,
            lastReadSequence: 6,
            manualUnreadFromSequence: 4,
            archived: true,
          ),
        ],
      ));
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const EntityConversationSnapshotScope(
        entity: HostEntityReference(type: 'project', id: 'project-7'),
      ),
      pageSize: 2,
    );

    final first = await controller.refresh();
    expect(first.status, ChatConversationListStatus.ready);
    expect(first.items.single.unreadCount, 2);
    expect(first.hasMore, isTrue);

    final second = await controller.loadMore();
    expect(second.items.map((item) => item.displayName), [
      'Alpha renamed',
      'Beta',
    ]);
    expect(second.items.last.unreadCount, 4);
    expect(second.items.last.isArchived, isTrue);
    expect(second.hasMore, isFalse);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.uri.queryParameters['scope'], 'entity');
    expect(transport.requests.last.uri.queryParameters['cursor'], cursor);

    await controller.dispose();
    await client.dispose();
  });

  test('distinguishes denied and revoked access and supports retry', () async {
    final transport = _QueueTransport()
      ..json(const {'error': 'denied'}, statusCode: 403)
      ..json(conversationListPage(items: [
        conversationListSummary(id: 'alpha', name: 'Alpha'),
      ]))
      ..json(const {'error': 'revoked'}, statusCode: 403);
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );

    expect(
      (await controller.refresh()).status,
      ChatConversationListStatus.accessDenied,
    );
    expect((await controller.retry()).status, ChatConversationListStatus.ready);
    expect(
      (await controller.refresh()).status,
      ChatConversationListStatus.accessRevoked,
    );

    await controller.dispose();
    await client.dispose();
  });

  test('loadMore coalesces with an active refresh without using a stale cursor',
      () async {
    final staleCursor = conversationListCursor('stale-page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );

    final initial = controller.refresh();
    await _waitForRequests(transport, 1);
    transport.completeNext(conversationListPage(
      nextCursor: staleCursor,
      items: [conversationListSummary(id: 'alpha', name: 'Alpha')],
    ));
    await initial;

    final refresh = controller.refresh();
    await _waitForRequests(transport, 2);
    final refreshRequest = transport.requests[1];
    final refreshCancellation =
        refreshRequest.cancellationSignal! as ChatCommandCancellationSignal;
    final loadMore = controller.loadMore();

    expect(controller.state.isBusy, isTrue);
    expect(loadMore, same(refresh));
    expect(transport.requests, hasLength(2));
    expect(refreshRequest.uri.queryParameters['cursor'], isNull);
    expect(refreshCancellation.isCancelled, isFalse);

    transport.completeNext(conversationListPage(items: [
      conversationListSummary(id: 'fresh', name: 'Fresh'),
    ]));
    await Future.wait([refresh, loadMore]);

    expect(refreshCancellation.isCancelled, isFalse);
    expect(transport.requests, hasLength(2));
    expect(controller.state.items.map((item) => item.displayName), ['Fresh']);
    expect(controller.state.isBusy, isFalse);

    await controller.dispose();
    await client.dispose();
  });

  test('refresh queues behind loadMore and replaces its completed page',
      () async {
    final cursor = conversationListCursor('page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );

    final initial = controller.refresh();
    await _waitForRequests(transport, 1);
    transport.completeNext(conversationListPage(
      nextCursor: cursor,
      items: [conversationListSummary(id: 'alpha', name: 'Alpha')],
    ));
    await initial;

    final loadMore = controller.loadMore();
    await _waitForRequests(transport, 2);
    final loadMoreRequest = transport.requests[1];
    final loadMoreCancellation =
        loadMoreRequest.cancellationSignal! as ChatCommandCancellationSignal;
    final refresh = controller.refresh();
    final duplicateLoadMore = controller.loadMore();

    expect(controller.state.isBusy, isTrue);
    expect(duplicateLoadMore, same(loadMore));
    expect(transport.requests, hasLength(2));
    expect(loadMoreRequest.uri.queryParameters['cursor'], cursor);
    expect(loadMoreCancellation.isCancelled, isFalse);

    transport.completeNext(conversationListPage(items: [
      conversationListSummary(id: 'beta', name: 'Beta'),
    ]));
    final completedLoadMore = await loadMore;
    expect(completedLoadMore.items.map((item) => item.displayName), [
      'Alpha',
      'Beta',
    ]);
    expect(completedLoadMore.isBusy, isTrue);

    await _waitForRequests(transport, 3);
    expect(transport.requests[2].uri.queryParameters['cursor'], isNull);
    expect(loadMoreCancellation.isCancelled, isFalse);
    transport.completeNext(conversationListPage(items: [
      conversationListSummary(id: 'fresh', name: 'Fresh'),
    ]));
    await refresh;

    expect(controller.state.items.map((item) => item.displayName), ['Fresh']);
    expect(controller.state.isBusy, isFalse);
    expect(transport.requests, hasLength(3));

    await controller.dispose();
    await client.dispose();
  });

  test('failed loadMore clears busy state and retry reuses the exact cursor',
      () async {
    final cursor = conversationListCursor('failed-page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );

    final initial = controller.refresh();
    await _waitForRequests(transport, 1);
    transport.completeNext(conversationListPage(
      nextCursor: cursor,
      items: [conversationListSummary(id: 'alpha', name: 'Alpha')],
    ));
    await initial;

    final failedLoadMore = controller.loadMore();
    await _waitForRequests(transport, 2);
    transport.completeNext(const {'error': 'failed'}, statusCode: 500);
    expect(
      (await failedLoadMore).status,
      ChatConversationListStatus.error,
    );
    expect(controller.state.isBusy, isFalse);

    final retry = controller.retry();
    await _waitForRequests(transport, 3);
    expect(transport.requests[1].uri.queryParameters['cursor'], cursor);
    expect(transport.requests[2].uri.queryParameters['cursor'], cursor);
    transport.completeNext(conversationListPage(items: [
      conversationListSummary(id: 'beta', name: 'Beta'),
    ]));
    await retry;

    expect(controller.state.items.map((item) => item.displayName), [
      'Alpha',
      'Beta',
    ]);
    expect(controller.state.isBusy, isFalse);

    await controller.dispose();
    await client.dispose();
  });

  test('disposal cancels in-flight work and emits disposed deterministically',
      () async {
    final transport = _PendingTransport();
    final client = _client(transport);
    final controller = ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
    );
    final states = <ChatConversationListStatus>[];
    final subscription = controller.states.listen(
      (state) => states.add(state.status),
    );

    final refresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isBusy, isTrue);
    await controller.dispose();
    expect(controller.state.status, ChatConversationListStatus.disposed);
    expect(controller.state.isBusy, isFalse);
    expect(states.last, ChatConversationListStatus.disposed);
    expect(
      (transport.request!.cancellationSignal! as ChatCommandCancellationSignal)
          .isCancelled,
      isTrue,
    );
    expect((await refresh).status, ChatConversationListStatus.disposed);

    await subscription.cancel();
    await client.dispose();
  });
}

const _entityScope = <String, Object?>{
  'type': 'entity',
  'entity': {'type': 'project', 'id': 'project-7'},
};

HandrailChatClient _client(HandrailChatHttpTransport transport) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'list-token',
      transport: transport,
    );

final class _QueueTransport implements HandrailChatHttpTransport {
  final Queue<HandrailChatHttpResponse> _responses = Queue();
  final List<HandrailChatHttpRequest> requests = [];

  void json(Object? body, {int statusCode = 200}) => _responses.add(
        HandrailChatHttpResponse(
          statusCode: statusCode,
          body: jsonEncode(body),
        ),
      );

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    return _responses.removeFirst();
  }
}

final class _PendingTransport implements HandrailChatHttpTransport {
  HandrailChatHttpRequest? request;
  final Completer<HandrailChatHttpResponse> response = Completer();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    this.request = request;
    return response.future;
  }
}

final class _ControlledTransport implements HandrailChatHttpTransport {
  final List<HandrailChatHttpRequest> requests = [];
  final Queue<Completer<HandrailChatHttpResponse>> _pending = Queue();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    final response = Completer<HandrailChatHttpResponse>();
    _pending.add(response);
    return response.future;
  }

  void completeNext(Object? body, {int statusCode = 200}) {
    _pending.removeFirst().complete(HandrailChatHttpResponse(
          statusCode: statusCode,
          body: jsonEncode(body),
        ));
  }
}

Future<void> _waitForRequests(
  _ControlledTransport transport,
  int count,
) async {
  for (var attempt = 0;
      attempt < 100 && transport.requests.length < count;
      attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(transport.requests, hasLength(count));
}
