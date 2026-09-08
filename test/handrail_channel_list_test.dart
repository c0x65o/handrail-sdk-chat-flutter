import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

import 'fixtures/conversation_list_fixtures.dart';

void main() {
  testWidgets('shows creation only from explicit host authorization',
      (tester) async {
    final transport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(id: 'alpha', name: 'Alpha'),
      ]));
    final client = _client(transport);
    final controller = _controller(client);
    var createRequests = 0;

    await _pumpList(tester, controller: controller);
    await _pumpUntil(tester, () => controller.state.isReady);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
      findsNothing,
    );

    await _pumpList(
      tester,
      controller: controller,
      canCreateChannels: true,
      onCreateChannel: () => createRequests += 1,
    );
    await tester.pump();
    final create = find.byKey(
      const ValueKey<String>('handrail-create-channel'),
    );
    expect(create, findsOneWidget);
    await tester.tap(create);
    expect(createRequests, 1);

    await controller.dispose();
    await client.dispose();
  });

  testWidgets(
      'renders a leading starred copy with unique identities and one footer',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final page2 = conversationListCursor('page-2');
    final page3 = conversationListCursor('page-3');
    final transport = _QueueTransport()
      ..json(conversationListPage(
        nextCursor: page2,
        items: [
          conversationListSummary(
            id: 'alpha',
            name: 'Alpha',
            isStarred: true,
            latestSequence: 4,
            lastReadSequence: 2,
          ),
          conversationListSummary(id: 'beta', name: 'Beta'),
        ],
      ))
      ..json(conversationListPage(
        nextCursor: page3,
        items: [conversationListSummary(id: 'gamma', name: 'Gamma')],
      ));
    final client = _client(transport);
    final controller = _controller(client);

    await _pumpList(
      tester,
      controller: controller,
      selectedConversationId: const ConversationId('alpha'),
    );
    await _pumpUntil(tester, () => controller.state.isReady);

    const headerKey = ValueKey<String>('handrail-channel-starred-header');
    const starredRowKey =
        ValueKey<String>('handrail-channel-starred-alpha-row');
    const ordinaryRowKey =
        ValueKey<String>('handrail-channel-public-channels-alpha-row');
    const starredSemanticsKey =
        ValueKey<String>('handrail-channel-starred-alpha-semantics');
    const ordinarySemanticsKey =
        ValueKey<String>('handrail-channel-public-channels-alpha-semantics');

    expect(find.byKey(headerKey), findsOneWidget);
    expect(find.text('Starred'), findsOneWidget);
    expect(find.text('Alpha'), findsNWidgets(2));
    expect(find.byKey(starredRowKey), findsOneWidget);
    expect(find.byKey(ordinaryRowKey), findsOneWidget);
    expect(find.byKey(starredSemanticsKey), findsOneWidget);
    expect(find.byKey(ordinarySemanticsKey), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(starredSemanticsKey)).label,
      'Alpha, selected, 2 unread messages',
    );
    expect(
      tester.getSemantics(find.byKey(ordinarySemanticsKey)).label,
      'Alpha, selected, 2 unread messages',
    );
    expect(
      tester.getTopLeft(find.byKey(headerKey)).dy,
      lessThan(tester.getTopLeft(find.byKey(starredRowKey)).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(starredRowKey)).dy,
      lessThan(tester.getTopLeft(find.byKey(ordinaryRowKey)).dy),
    );
    expect(
      find.byKey(const ValueKey('handrail-channel-list-load-more-footer')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('handrail-channel-list-load-more')),
    );
    await _pumpUntil(tester, () => controller.state.items.length == 3);
    expect(find.text('Gamma'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-public-channels-gamma-row',
      )),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('handrail-channel-list-load-more-footer')),
      findsOneWidget,
    );
    expect(transport.requests.last.uri.queryParameters['cursor'], page2);

    semantics.dispose();
    await controller.dispose();
    await client.dispose();
  });

  testWidgets('orders all non-empty conversation sections after Starred',
      (tester) async {
    final transport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(
          id: 'private',
          name: 'Private room',
          visibility: 'private',
          isStarred: true,
        ),
        conversationListSummary(
          id: 'thread',
          name: 'Ignored thread name',
          type: 'thread',
        ),
        conversationListSummary(id: 'public', name: 'Public room'),
        conversationListSummary(
          id: 'group',
          name: 'Ignored group name',
          type: 'group_direct',
          visibility: 'private',
        ),
        conversationListSummary(
          id: 'direct',
          name: 'Ignored direct name',
          type: 'direct',
          visibility: 'private',
        ),
      ]));
    final client = _client(transport);
    final controller = _controller(client);

    await _pumpList(tester, controller: controller);
    await _pumpUntil(tester, () => controller.state.isReady);

    const orderedKeys = [
      'handrail-channel-starred-header',
      'handrail-channel-starred-private-row',
      'handrail-channel-direct-messages-header',
      'handrail-channel-direct-messages-direct-row',
      'handrail-channel-public-channels-header',
      'handrail-channel-public-channels-public-row',
      'handrail-channel-private-channels-header',
      'handrail-channel-private-channels-private-row',
      'handrail-channel-group-conversations-header',
      'handrail-channel-group-conversations-group-row',
      'handrail-channel-threads-header',
      'handrail-channel-threads-thread-row',
    ];
    final positions = <double>[];
    for (final key in orderedKeys) {
      final finder = find.byKey(ValueKey<String>(key));
      expect(finder, findsOneWidget);
      positions.add(tester.getTopLeft(finder).dy);
    }
    expect(positions, orderedEquals([...positions]..sort()));

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('omits headers for empty conversation sections', (tester) async {
    final transport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(
          id: 'direct',
          name: 'Ignored direct name',
          type: 'direct',
          visibility: 'private',
        ),
        conversationListSummary(
          id: 'thread',
          name: 'Ignored thread name',
          type: 'thread',
        ),
      ]));
    final client = _client(transport);
    final controller = _controller(client);

    await _pumpList(tester, controller: controller);
    await _pumpUntil(tester, () => controller.state.isReady);

    expect(find.text('Direct messages'), findsOneWidget);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Starred'), findsNothing);
    expect(find.text('Public channels'), findsNothing);
    expect(find.text('Private channels'), findsNothing);
    expect(find.text('Group conversations'), findsNothing);

    await controller.dispose();
    await client.dispose();
  });

  testWidgets(
      'renders pages, selection, unread/archive state, and semantic labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final cursor = conversationListCursor('page-2');
    final transport = _QueueTransport()
      ..json(conversationListPage(
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
      ..json(conversationListPage(items: [
        conversationListSummary(
          id: 'archive',
          name: 'Archive room',
          archived: true,
        ),
      ]));
    final client = _client(transport);
    final controller = _controller(client);
    final selected = <ConversationId>[];

    await _pumpList(
      tester,
      controller: controller,
      selectedConversationId: const ConversationId('alpha'),
      onSelected: selected.add,
    );
    await _pumpUntil(tester, () => controller.state.isReady);

    expect(
      find.byKey(const ValueKey<String>('handrail-channel-starred-header')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-public-channels-alpha-row',
      )),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Alpha, selected, 2 unread messages'),
      findsOneWidget,
    );
    await tester.tap(find.text('Alpha'));
    expect(selected, [const ConversationId('alpha')]);

    await tester.tap(
      find.byKey(const ValueKey('handrail-channel-list-load-more')),
    );
    await _pumpUntil(tester, () => !controller.state.hasMore);
    expect(find.text('Archive room'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Archive room, not selected, archived'),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-channel-public-channels-archive-row',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('handrail-channel-list-load-more-footer')),
      findsNothing,
    );
    expect(transport.requests.last.uri.queryParameters['cursor'], cursor);

    semantics.dispose();
    await controller.dispose();
    await client.dispose();
  });

  testWidgets(
      'star tap is optimistic, preserves canonical fields, and ignores duplicates',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);
    final selected = <ConversationId>[];

    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(items: [
        conversationListSummary(id: 'before-1', name: 'Before one'),
        conversationListSummary(id: 'before-2', name: 'Before two'),
        conversationListSummary(
          id: 'alpha',
          name: 'Alpha',
          notificationPreference: 'none',
          mute: const {
            'muted': true,
            'mutedUntil': '2026-08-27T23:00:00.000Z',
          },
        ),
        for (var index = 0; index < 8; index += 1)
          conversationListSummary(
            id: 'after-$index',
            name: 'After $index',
          ),
      ]));
      await initial;
    });
    await _pumpList(
      tester,
      controller: controller,
      selectedConversationId: const ConversationId('alpha'),
      onSelected: selected.add,
      height: 260,
    );

    await tester.drag(
      find.byKey(const ValueKey('handrail-channel-list')),
      const Offset(0, -80),
    );
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final offsetBeforeStar = scrollable.position.pixels;

    final star = find.byKey(
      const ValueKey<String>('handrail-channel-public-channels-alpha-star'),
    );
    expect(star, findsOneWidget);
    expect(tester.getSize(star), const Size(48, 48));
    expect(find.bySemanticsLabel('Star Alpha'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Star Alpha'))
          .flagsCollection
          .isToggled,
      Tristate.isFalse,
    );

    await tester.tap(star);
    await tester.pump();
    expect(scrollable.position.pixels, offsetBeforeStar);
    scrollable.position.jumpTo(0);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('handrail-channel-starred-header')),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsNWidgets(2));
    expect(find.byIcon(Icons.star), findsNWidgets(2));
    expect(find.bySemanticsLabel('Unstar Alpha'), findsNWidgets(2));
    expect(
      find.byKey(
        const ValueKey<String>(
          'handrail-channel-public-channels-alpha-semantics',
        ),
      ),
      findsOneWidget,
    );
    expect(selected, isEmpty);
    expect(tester.widget<IconButton>(star).onPressed, isNull);

    await tester.tap(star, warnIfMissed: false);
    await tester.pump();
    expect(transport.requests, hasLength(2));
    final request =
        jsonDecode(transport.requests.last.body!) as Map<String, Object?>;
    expect(request['isStarred'], isTrue);
    expect(request['notificationPreference'], 'none');
    expect(request['mute'], {
      'muted': true,
      'mutedUntil': '2026-08-27T23:00:00.000Z',
    });

    transport.completeNext(_preferenceResult(request, 'applied'));
    await _pumpUntil(
      tester,
      () => !controller
          .conversationPreference(const ConversationId('alpha'))
          .isPending,
    );
    expect(find.byIcon(Icons.star), findsNWidgets(2));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey<String>(
            'handrail-channel-public-channels-alpha-star-semantics',
          )))
          .flagsCollection
          .isToggled,
      Tristate.isTrue,
    );

    scrollable.position.jumpTo(80);
    await tester.pump();
    final offsetBeforeUnstar = scrollable.position.pixels;
    await tester.tap(star);
    await tester.pump();
    expect(scrollable.position.pixels, offsetBeforeUnstar);
    expect(
      find.byKey(const ValueKey<String>('handrail-channel-starred-header')),
      findsNothing,
    );
    expect(find.text('Alpha'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-public-channels-alpha-row',
      )),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey<String>(
            'handrail-channel-public-channels-alpha-semantics',
          )))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(selected, isEmpty);

    final unstarRequest =
        jsonDecode(transport.requests.last.body!) as Map<String, Object?>;
    expect(unstarRequest['isStarred'], isFalse);
    transport.completeNext(_preferenceResult(unstarRequest, 'applied'));
    await _pumpUntil(
      tester,
      () => !controller
          .conversationPreference(const ConversationId('alpha'))
          .isPending,
    );
    expect(find.byIcon(Icons.star_border), findsWidgets);

    semantics.dispose();
    await controller.dispose();
    await client.dispose();
  });

  testWidgets('keyboard activation unstars once without selecting the row',
      (tester) async {
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);
    final selected = <ConversationId>[];
    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(items: [
        conversationListSummary(
          id: 'alpha',
          name: 'Alpha',
          isStarred: true,
        ),
      ]));
      await initial;
    });
    await _pumpList(
      tester,
      controller: controller,
      autofocus: true,
      onSelected: selected.add,
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.runAsync(() => _waitForRequests(transport, 2));
    expect(transport.requests, hasLength(2));
    final request =
        jsonDecode(transport.requests.last.body!) as Map<String, Object?>;
    expect(request['isStarred'], isFalse);
    expect(selected, isEmpty);
    expect(find.byIcon(Icons.star_border), findsOneWidget);

    transport.completeNext(_preferenceResult(request, 'applied'));
    await _pumpUntil(
      tester,
      () => !controller
          .conversationPreference(const ConversationId('alpha'))
          .isPending,
    );
    expect(find.byIcon(Icons.star_border), findsOneWidget);

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('failure and revision conflict settle to canonical star state',
      (tester) async {
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);
    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(items: [
        conversationListSummary(id: 'alpha', name: 'Alpha'),
      ]));
      await initial;
    });
    await _pumpList(tester, controller: controller);
    final star = find.byKey(
      const ValueKey<String>('handrail-channel-public-channels-alpha-star'),
    );

    await tester.tap(star);
    await tester.pump();
    expect(find.byIcon(Icons.star), findsNWidgets(2));
    transport.completeNext(const {'error': 'internal'}, statusCode: 500);
    await _pumpUntil(
      tester,
      () => !controller
          .conversationPreference(const ConversationId('alpha'))
          .isPending,
    );
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(
      find.text('Could not update the star. Please try again.'),
      findsOneWidget,
    );

    await tester.tap(star);
    await tester.pump();
    final conflictRequest =
        jsonDecode(transport.requests.last.body!) as Map<String, Object?>;
    transport.completeNext(
      _preferenceResult(
        conflictRequest,
        'preference_revision_conflict',
        revision: 2,
        canonical: const {
          'notificationPreference': 'mentions',
          'isStarred': false,
          'mute': {'muted': false},
        },
      ),
      statusCode: 409,
    );
    await _pumpUntil(
      tester,
      () => !controller
          .conversationPreference(const ConversationId('alpha'))
          .isPending,
    );
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(
      find.text('Star setting changed elsewhere. Showing the latest.'),
      findsOneWidget,
    );

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('default and custom rows remain bounded at compact widths',
      (tester) async {
    final transport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(
          id: 'alpha',
          name: 'A very long archived channel name',
          latestSequence: 12,
          archived: true,
        ),
      ]));
    final client = _client(transport);
    final controller = _controller(client);
    await _pumpList(tester, controller: controller, width: 144);
    await _pumpUntil(tester, () => controller.state.isReady);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(
        const ValueKey<String>('handrail-channel-public-channels-alpha-star'),
      )),
      const Size(48, 48),
    );

    final customBuilders = const ChatWidgetBuilders().merge(
      ChatWidgetBuilderOverrides(
        channel: (context, input) => Text(
          'Custom renderer for ${input.item.displayName}',
        ),
      ),
    );
    await _pumpList(
      tester,
      controller: controller,
      builders: customBuilders,
      width: 144,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Custom renderer'), findsOneWidget);

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('disables load more while a retained-items refresh is active',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final cursor = conversationListCursor('page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);

    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(
        nextCursor: cursor,
        items: [conversationListSummary(id: 'alpha', name: 'Alpha')],
      ));
      await initial;
    });
    await _pumpList(tester, controller: controller);

    late Future<ChatConversationListState> refresh;
    await tester.runAsync(() async {
      refresh = controller.refresh();
      await _waitForRequests(transport, 2);
    });
    await tester.pump();

    final loadMoreFinder =
        find.byKey(const ValueKey('handrail-channel-list-load-more'));
    final progressFinder =
        find.byKey(const ValueKey('handrail-channel-list-loading-more'));
    expect(controller.state.isBusy, isTrue);
    expect(tester.widget<TextButton>(loadMoreFinder).onPressed, isNull);
    expect(progressFinder, findsOneWidget);
    expect(tester.getSemantics(progressFinder).label, 'Loading channels');

    await tester.tap(loadMoreFinder);
    await tester.pump();
    expect(transport.requests, hasLength(2));

    await tester.runAsync(() async {
      transport.completeNext(conversationListPage(items: [
        conversationListSummary(id: 'fresh', name: 'Fresh'),
      ]));
      await refresh;
    });
    await tester.pump();

    expect(controller.state.isBusy, isFalse);
    expect(find.text('Fresh'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    semantics.dispose();
    await controller.dispose();
    await client.dispose();
  });

  testWidgets(
      'auto-loads once near the end and preserves interaction state while pending',
      (tester) async {
    final cursor = conversationListCursor('page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);

    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(
        nextCursor: cursor,
        items: _channelItems(0, 24),
      ));
      await initial;
    });
    await _pumpList(tester, controller: controller, height: 260);

    const selectedId = ConversationId('channel-21');
    final selectedRow = find.byKey(
      const ValueKey<String>(
        'handrail-channel-public-channels-channel-21',
      ),
    );
    await tester.scrollUntilVisible(
      selectedRow,
      180,
      scrollable: find.byType(Scrollable),
    );
    await tester.runAsync(() => _waitForRequests(transport, 2));
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final offsetWhilePending = scrollable.position.pixels;
    final loadMoreFinder =
        find.byKey(const ValueKey('handrail-channel-list-load-more'));
    final footerElement = tester.element(loadMoreFinder);
    expect(controller.state.isBusy, isTrue);
    expect(tester.widget<TextButton>(loadMoreFinder).onPressed, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focusedBeforeRebuild = FocusManager.instance.primaryFocus;
    expect(focusedBeforeRebuild, isNotNull);

    for (var rebuild = 0; rebuild < 3; rebuild += 1) {
      await _pumpList(
        tester,
        controller: controller,
        selectedConversationId: selectedId,
        height: 260,
      );
    }

    expect(transport.requests, hasLength(2));
    expect(scrollable.position.pixels, offsetWhilePending);
    expect(tester.element(loadMoreFinder), same(footerElement));
    expect(FocusManager.instance.primaryFocus, same(focusedBeforeRebuild));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey<String>(
            'handrail-channel-public-channels-channel-21-semantics',
          )))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );

    transport.completeNext(conversationListPage(
      items: [
        conversationListSummary(
          id: 'direct-appended',
          name: 'Ignored direct name',
          type: 'direct',
          visibility: 'private',
        ),
        ..._channelItems(24, 5),
      ],
    ));
    await _pumpUntil(
      tester,
      () => !controller.state.isBusy && !controller.state.hasMore,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(transport.requests, hasLength(2));
    expect(
      find.byKey(const ValueKey('handrail-channel-list-load-more-footer')),
      findsNothing,
    );
    expect(scrollable.position.pixels, offsetWhilePending);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey<String>(
            'handrail-channel-public-channels-channel-21-semantics',
          )))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    scrollable.position.jumpTo(0);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>(
        'handrail-channel-direct-messages-direct-appended-row',
      )),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Direct messages')).dy,
      lessThan(tester.getTopLeft(find.text('Public channels')).dy),
    );

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('auto-load failure does not loop and remains manually retryable',
      (tester) async {
    final cursor = conversationListCursor('page-2');
    final transport = _ControlledTransport();
    final client = _client(transport);
    final controller = _controller(client);

    await tester.runAsync(() async {
      final initial = controller.refresh();
      await _waitForRequests(transport, 1);
      transport.completeNext(conversationListPage(
        nextCursor: cursor,
        items: _channelItems(0, 24),
      ));
      await initial;
    });
    await _pumpList(tester, controller: controller, height: 260);

    await tester.scrollUntilVisible(
      find.byKey(
        const ValueKey<String>(
          'handrail-channel-public-channels-channel-21-row',
        ),
      ),
      180,
      scrollable: find.byType(Scrollable),
    );
    await tester.runAsync(() => _waitForRequests(transport, 2));

    transport.completeNext(const {'error': 'failed'}, statusCode: 500);
    await _pumpUntil(
      tester,
      () =>
          controller.state.status == ChatConversationListStatus.error &&
          !controller.state.isBusy,
    );
    for (var pump = 0; pump < 5; pump += 1) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(transport.requests, hasLength(2));

    final retry = find.widgetWithText(TextButton, 'Retry');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.runAsync(() => _waitForRequests(transport, 3));
    expect(transport.requests.last.uri.queryParameters['cursor'], cursor);

    transport.completeNext(conversationListPage(
      items: _channelItems(24, 2),
    ));
    await _pumpUntil(
      tester,
      () => controller.state.isReady && !controller.state.isBusy,
    );
    expect(controller.state.items, hasLength(26));
    expect(controller.state.items.last.displayName, 'Channel 25');
    expect(transport.requests, hasLength(3));

    await controller.dispose();
    await client.dispose();
  });

  testWidgets('shows loading, empty, error, denied, and revoked states',
      (tester) async {
    final pending = _PendingTransport();
    final loadingClient = _client(pending);
    final loadingController = _controller(loadingClient);
    await _pumpList(tester, controller: loadingController);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.response.complete(_response(conversationListPage()));
    await _pumpUntil(tester, () => loadingController.state.isEmpty);
    expect(find.text('No channels'), findsOneWidget);
    await loadingController.dispose();
    await loadingClient.dispose();

    final errorTransport = _QueueTransport()
      ..json(const {'error': 'failed'}, statusCode: 500);
    final errorClient = _client(errorTransport);
    final errorController = _controller(errorClient);
    await _pumpList(tester, controller: errorController);
    await _pumpUntil(
      tester,
      () => errorController.state.status == ChatConversationListStatus.error,
    );
    expect(find.text(errorController.state.error!.message), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await errorController.dispose();
    await errorClient.dispose();

    final deniedTransport = _QueueTransport()
      ..json(const {'error': 'denied'}, statusCode: 403);
    final deniedClient = _client(deniedTransport);
    final deniedController = _controller(deniedClient);
    await _pumpList(tester, controller: deniedController);
    await _pumpUntil(
      tester,
      () =>
          deniedController.state.status ==
          ChatConversationListStatus.accessDenied,
    );
    expect(
      find.text('You do not have access to these channels'),
      findsOneWidget,
    );
    await deniedController.dispose();
    await deniedClient.dispose();

    final revokedTransport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(id: 'alpha', name: 'Alpha'),
      ]))
      ..json(const {'error': 'revoked'}, statusCode: 403);
    final revokedClient = _client(revokedTransport);
    final revokedController = _controller(revokedClient);
    await tester.runAsync(revokedController.refresh);
    await _pumpList(tester, controller: revokedController);
    await tester.runAsync(revokedController.refresh);
    await _pumpUntil(
      tester,
      () =>
          revokedController.state.status ==
          ChatConversationListStatus.accessRevoked,
    );
    expect(
      find.text('Access to these channels was revoked'),
      findsOneWidget,
    );
    await revokedController.dispose();
    await revokedClient.dispose();
  });

  testWidgets('arrow focus traversal and Enter/Space activate host callbacks',
      (tester) async {
    final transport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(
          id: 'private',
          name: 'Private room',
          visibility: 'private',
        ),
        conversationListSummary(
          id: 'direct',
          name: 'Ignored direct name',
          type: 'direct',
          visibility: 'private',
        ),
        conversationListSummary(id: 'public', name: 'Public room'),
      ]));
    final client = _client(transport);
    final controller = _controller(client);
    final selected = <ConversationId>[];
    await _pumpList(
      tester,
      controller: controller,
      autofocus: true,
      onSelected: selected.add,
    );
    await _pumpUntil(tester, () => controller.state.isReady);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, [
      const ConversationId('direct'),
      const ConversationId('public'),
    ]);

    await controller.dispose();
    await client.dispose();
  });

  testWidgets(
      'honors theme/builders and releases only widget-owned controllers',
      (tester) async {
    final callerTransport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(id: 'alpha', name: 'Alpha'),
      ]));
    final callerClient = _client(callerTransport);
    final callerController = _controller(callerClient);
    final theme = ThemeData(
      extensions: const [
        HandrailChatTheme(
          typography: HandrailChatTypography(
            message: TextStyle(fontSize: 11),
            metadata: TextStyle(fontSize: 12),
            conversationTitle: TextStyle(fontSize: 31),
            composer: TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
    await _pumpList(tester, controller: callerController, theme: theme);
    await _pumpUntil(tester, () => callerController.state.isReady);
    expect(tester.widget<Text>(find.text('Alpha')).style?.fontSize, 31);

    final customBuilders = const ChatWidgetBuilders().merge(
      ChatWidgetBuilderOverrides(
        channel: (context, input) => Text(
          'custom ${input.item.displayName} ${input.selected}',
        ),
      ),
    );
    await _pumpList(
      tester,
      controller: callerController,
      builders: customBuilders,
      selectedConversationId: const ConversationId('alpha'),
      theme: theme,
    );
    await tester.pump();
    expect(find.text('custom Alpha true'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(callerController.state.isDisposed, isFalse);

    final ownedTransport = _QueueTransport()
      ..json(conversationListPage(items: [
        conversationListSummary(id: 'owned', name: 'Owned'),
      ]));
    final ownedClient = _client(ownedTransport);
    final key = GlobalKey<HandrailChannelListState>();
    await tester.pumpWidget(MaterialApp(
      home: HandrailChannelList(
        key: key,
        client: ownedClient,
        onSelected: _ignoreSelection,
      ),
    ));
    await _pumpUntil(
      tester,
      () => key.currentState?.debugController?.state.isReady ?? false,
    );
    final ownedController = key.currentState!.debugController!;
    expect(key.currentState!.debugOwnsController, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(ownedController.state.isDisposed, isTrue);

    await callerController.dispose();
    await callerClient.dispose();
    await ownedClient.dispose();
  });
}

Future<void> _pumpList(
  WidgetTester tester, {
  required ChatConversationListController controller,
  ConversationId? selectedConversationId,
  HandrailChannelSelected onSelected = _ignoreSelection,
  ChatWidgetBuilders builders = const ChatWidgetBuilders(),
  ThemeData? theme,
  bool autofocus = false,
  bool canCreateChannels = false,
  HandrailChannelCreateRequested? onCreateChannel,
  double width = 400,
  double height = 600,
}) =>
    tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: HandrailChannelList(
              controller: controller,
              selectedConversationId: selectedConversationId,
              onSelected: onSelected,
              builders: builders,
              autofocus: autofocus,
              canCreateChannels: canCreateChannels,
              onCreateChannel: onCreateChannel,
            ),
          ),
        ),
      ),
    ));

void _ignoreSelection(ConversationId _) {}

List<Map<String, Object?>> _channelItems(int start, int count) => [
      for (var index = start; index < start + count; index += 1)
        conversationListSummary(
          id: 'channel-$index',
          name: 'Channel $index',
        ),
    ];

ChatConversationListController _controller(HandrailChatClient client) =>
    ChatConversationListController(
      client: client,
      scope: const OrganizationConversationSnapshotScope(),
      pageSize: 2,
    );

HandrailChatClient _client(HandrailChatHttpTransport transport) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'widget-token',
      transport: transport,
    );

HandrailChatHttpResponse _response(Object? body, {int statusCode = 200}) =>
    HandrailChatHttpResponse(
      statusCode: statusCode,
      body: jsonEncode(body),
    );

Map<String, Object?> _preferenceResult(
  Map<String, Object?> request,
  String status, {
  int? revision,
  Map<String, Object?>? canonical,
}) {
  final desired = <String, Object?>{
    'notificationPreference': request['notificationPreference'],
    'isStarred': request['isStarred'],
    'mute': request['mute'],
  };
  final expected = request['expectedPreferenceRevision']! as int;
  return {
    'operation': 'update_conversation_preference',
    'reconciliationStatus': status,
    'conversationId': request['conversationId'],
    'expectedPreferenceRevision': expected,
    'idempotencyKey': request['idempotencyKey'],
    'requestedPreference': desired,
    'preferenceRevision': revision ?? expected + 1,
    'preference': {
      ...?canonical,
      if (canonical == null) ...desired,
      'updatedAt': '2026-08-28T23:00:00.000Z',
    },
  };
}

final class _QueueTransport implements HandrailChatHttpTransport {
  final Queue<HandrailChatHttpResponse> _responses = Queue();
  final List<HandrailChatHttpRequest> requests = [];

  void json(Object? body, {int statusCode = 200}) =>
      _responses.add(_response(body, statusCode: statusCode));

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    return _responses.removeFirst();
  }
}

final class _PendingTransport implements HandrailChatHttpTransport {
  final Completer<HandrailChatHttpResponse> response = Completer();

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) =>
      response.future;
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
    _pending.removeFirst().complete(_response(body, statusCode: statusCode));
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt += 1) {
    await tester.runAsync(() async {
      for (var microtask = 0; microtask < 4; microtask += 1) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue,
      reason: 'Expected controller state was not reached.');
  await tester.pump();
}
