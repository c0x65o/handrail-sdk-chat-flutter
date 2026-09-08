import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart';
import 'package:handrail_message_timeline_lab/main.dart';

void main() {
  _replyStyleScenarioTests();
  test('directory fixture filters active rows and honors page bounds',
      () async {
    const expectedRows = <String, UserId>{
      'Ada': UserId('ada'),
      'Grace': UserId('grace'),
      'Margaret': UserId('margaret'),
      'Katherine': UserId('katherine'),
    };

    for (final entry in expectedRows.entries) {
      final page = await searchTimelineLabMemberDirectory(
        HandrailMemberDirectorySearchRequest(
          query: entry.key.toLowerCase(),
          pageSize: 1,
        ),
      );
      expect(page.rows, hasLength(1));
      expect(page.rows.single.userId, entry.value);
      expect(page.rows.single.disabled, isFalse);
      expect(page.nextPageToken, isNull);
    }

    final unmatched = await searchTimelineLabMemberDirectory(
      const HandrailMemberDirectorySearchRequest(
        query: 'Dorothy',
        pageSize: 50,
      ),
    );
    expect(unmatched.rows, isEmpty);

    final firstPage = await searchTimelineLabMemberDirectory(
      const HandrailMemberDirectorySearchRequest(query: '', pageSize: 2),
    );
    expect(firstPage.rows, hasLength(2));
    expect(firstPage.nextPageToken, '2');
    final secondPage = await searchTimelineLabMemberDirectory(
      HandrailMemberDirectorySearchRequest(
        query: '',
        pageSize: 2,
        pageToken: firstPage.nextPageToken,
      ),
    );
    expect(secondPage.rows, hasLength(2));
    expect(
      secondPage.rows.map((row) => row.userId),
      const [UserId('margaret'), UserId('katherine')],
    );
    expect(secondPage.nextPageToken, isNull);
  });

  testWidgets(
    'updates and reloads canonical notification and mute preferences',
    (tester) async {
      _useWideViewport(tester);
      final transportRequests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: transportRequests.add),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>(
                'handrail-channel-notification-controls',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );
      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(workspace.notificationControls?.authorized, isTrue);
      transportRequests.clear();

      for (final level in <String>['mentions', 'none', 'all']) {
        await _selectPreferenceMenuItem(
          tester,
          buttonKey: 'handrail-channel-notification-level',
          itemKey: 'handrail-channel-notification-$level',
        );
        await _pumpUntil(
          tester,
          () =>
              transportRequests.where(_isPreferenceRequest).length ==
              <String>['mentions', 'none', 'all'].indexOf(level) + 1,
        );
      }

      for (final mute in <String>['indefinite', 'until', 'unmuted']) {
        await _selectPreferenceMenuItem(
          tester,
          buttonKey: 'handrail-channel-notification-mute',
          itemKey: 'handrail-channel-notification-mute-$mute',
        );
        await _pumpUntil(
          tester,
          () =>
              transportRequests.where(_isPreferenceRequest).length ==
              <String>['indefinite', 'until', 'unmuted'].indexOf(mute) + 4,
        );
      }

      final preferenceRequests =
          transportRequests.where(_isPreferenceRequest).toList();
      expect(preferenceRequests, hasLength(6));
      expect(
        preferenceRequests.map(
          (request) => _preferenceBody(request)['expectedPreferenceRevision'],
        ),
        const [0, 1, 2, 3, 4, 5],
      );
      expect(
        preferenceRequests.map(
          (request) => _preferenceBody(request)['notificationPreference'],
        ),
        const ['mentions', 'none', 'all', 'all', 'all', 'all'],
      );
      expect(
        preferenceRequests.map((request) => _preferenceBody(request)['mute']),
        const [
          {'muted': false},
          {'muted': false},
          {'muted': false},
          {'muted': true},
          {'muted': true, 'mutedUntil': '2030-02-03T04:05:06.000Z'},
          {'muted': false},
        ],
      );
      for (final request in preferenceRequests) {
        expect(
          () => UpdateConversationPreferenceInput.fromJson(
            _preferenceBody(request),
          ),
          returnsNormally,
        );
      }

      const conversationId = ConversationId('flutter-public-channel');
      final client = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      ).client;
      final controller = client.conversations.forConversation(conversationId);
      final detailRequestsBeforeReload = transportRequests
          .where((request) => _isConversationDetailRequest(
                request,
                conversationId,
              ))
          .length;
      final reload = controller.refresh();
      await _pumpUntil(
        tester,
        () =>
            transportRequests
                .where((request) => _isConversationDetailRequest(
                      request,
                      conversationId,
                    ))
                .length >
            detailRequestsBeforeReload,
      );
      await reload;
      await tester.pump();

      final canonical = client.normalizedState.conversationPreference(
        conversationId,
      );
      expect(canonical.authoritativeRevision, 6);
      expect(
        canonical.authoritativePreference?.notificationPreference,
        'all',
      );
      expect(canonical.authoritativePreference?.mute.muted, isFalse);
      expect(
        canonical.authoritativePreference?.updatedAt,
        const IsoTimestamp('2026-08-28T19:40:00.000Z'),
      );
      await _expectCheckedPreferenceItem(
        tester,
        buttonKey: 'handrail-channel-notification-level',
        itemKey: 'handrail-channel-notification-all',
      );
      await _expectCheckedPreferenceItem(
        tester,
        buttonKey: 'handrail-channel-notification-mute',
        itemKey: 'handrail-channel-notification-mute-unmuted',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied notification mode renders no controls or preference requests',
    (tester) async {
      _useWideViewport(tester);
      final transportRequests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          canManageNotificationPreferences: false,
          onTransportRequest: transportRequests.add,
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      final client = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      ).client;
      expect(workspace.notificationControls?.authorized, isFalse);
      expect(
        client.normalizedState
            .conversation(const ConversationId('flutter-public-channel'))
            .members[const UserId('ada')]!
            .role,
        'owner',
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-channel-notification-controls'),
        ),
        findsNothing,
      );
      expect(transportRequests.where(_isPreferenceRequest), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manages canonical member roles with the latest reconciled revision',
    (tester) async {
      _useWideViewport(tester);
      final semantics = tester.ensureSemantics();
      final transportRequests = <HandrailChatHttpRequest>[];
      final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          onTransportRequest: transportRequests.add,
          searchDirectory: (request) {
            directoryRequests.add(request);
            return searchTimelineLabMemberDirectory(request);
          },
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('handrail-workspace-members'))
            .evaluate()
            .isNotEmpty,
      );
      expect(directoryRequests, isEmpty);
      transportRequests.clear();

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-workspace-members')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>('handrail-member-row-katherine'),
            )
            .evaluate()
            .isNotEmpty,
      );

      expect(directoryRequests, hasLength(1));
      expect(
        find.bySemanticsLabel(
          RegExp('Ada Lovelace.*existing member.*role owner'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Grace Hopper.*existing member.*role moderator'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Margaret Hamilton.*existing member.*role member'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Katherine Johnson.*not a member'),
        ),
        findsOneWidget,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(
        workspace.members!.roleOptions,
        const [
          ConversationMembershipMemberRole.owner,
          ConversationMembershipMemberRole.moderator,
          ConversationMembershipMemberRole.member,
        ],
      );
      final client = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      ).client;
      expect(
        client.normalizedState.state.memberListRevisions[
            const ConversationId('flutter-public-channel')],
        7,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-member-add-katherine'),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            client.normalizedState.state.memberListRevisions[
                const ConversationId('flutter-public-channel')] ==
            8,
      );
      expect(
        client
            .normalizedState
            .state
            .membersByConversation[const ConversationId(
                'flutter-public-channel')]![const UserId('katherine')]!
            .role,
        'member',
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-member-role-margaret'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('moderator').last);
      await _pumpUntil(
        tester,
        () =>
            client.normalizedState.state.memberListRevisions[
                const ConversationId('flutter-public-channel')] ==
            9,
      );
      expect(
        client
            .normalizedState
            .state
            .membersByConversation[const ConversationId(
                'flutter-public-channel')]![const UserId('margaret')]!
            .role,
        'moderator',
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-member-remove-grace'),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            client.normalizedState.state.memberListRevisions[
                const ConversationId('flutter-public-channel')] ==
            10,
      );
      expect(
        client
            .normalizedState
            .state
            .membersByConversation[const ConversationId(
                'flutter-public-channel')]![const UserId('grace')]!
            .state,
        'removed',
      );
      expect(
        find.byKey(const ValueKey<String>('handrail-member-add-grace')),
        findsOneWidget,
      );

      final membershipRequests =
          transportRequests.where(_isMembershipRequest).toList();
      expect(membershipRequests, hasLength(3));
      expect(
        membershipRequests.map((request) => _membershipBody(request)['intent']),
        const ['add_member', 'change_member_role', 'remove_member'],
      );
      expect(
        membershipRequests.map(
          (request) => _membershipBody(request)['expectedMemberListRevision'],
        ),
        const [7, 8, 9],
      );
      expect(
        _membershipBody(membershipRequests[1])['requestedRole'],
        'moderator',
      );
      for (final request in membershipRequests) {
        expect(
          () => ConversationMembershipMutationInput.fromJson(
            _membershipBody(request),
          ),
          returnsNormally,
        );
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('last-owner removal and demotion preserve canonical state', (
    tester,
  ) async {
    _useWideViewport(tester);
    final transportRequests = <HandrailChatHttpRequest>[];

    await tester.pumpWidget(
      HandrailTimelineLabApp(onTransportRequest: transportRequests.add),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-workspace-members'))
          .evaluate()
          .isNotEmpty,
    );
    transportRequests.clear();
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-workspace-members')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-member-remove-ada'))
          .evaluate()
          .isNotEmpty,
    );
    final client = ChatScope.of(
      tester.element(find.byType(HandrailChatWorkspace)),
    ).client;

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-member-remove-ada')),
    );
    await _pumpUntil(
      tester,
      () => transportRequests.where(_isMembershipRequest).length == 1,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-member-remove-ada'))
          .evaluate()
          .isNotEmpty,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-member-role-ada')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('member').last);
    await _pumpUntil(
      tester,
      () => transportRequests.where(_isMembershipRequest).length == 2,
    );

    final membershipRequests =
        transportRequests.where(_isMembershipRequest).toList();
    expect(
      membershipRequests.map((request) => _membershipBody(request)['intent']),
      const ['remove_member', 'change_member_role'],
    );
    expect(
      membershipRequests.map(
        (request) => _membershipBody(request)['expectedMemberListRevision'],
      ),
      const [7, 7],
    );
    expect(
      client.normalizedState.state
          .memberListRevisions[const ConversationId('flutter-public-channel')],
      7,
    );
    final owner = client.normalizedState.state.membersByConversation[
        const ConversationId('flutter-public-channel')]![const UserId('ada')]!;
    expect(owner.role, 'owner');
    expect(owner.state, 'active');
    expect(find.text('Update failed. Try again.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'denied member actor has no control, directory query, panel, or mutation',
    (tester) async {
      _useWideViewport(tester);
      final transportRequests = <HandrailChatHttpRequest>[];
      final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          canManageMembers: false,
          canCreateDirectConversations: false,
          canCreateGroupDirectConversations: false,
          onTransportRequest: transportRequests.add,
          searchDirectory: (request) {
            directoryRequests.add(request);
            return searchTimelineLabMemberDirectory(request);
          },
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      final client = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      ).client;
      expect(workspace.members, isNull);
      expect(
        client
            .normalizedState
            .state
            .membersByConversation[const ConversationId(
                'flutter-public-channel')]![const UserId('ada')]!
            .role,
        'owner',
      );
      expect(
        find.byKey(const ValueKey<String>('handrail-workspace-members')),
        findsNothing,
      );
      expect(find.byType(HandrailMemberPicker), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('handrail-workspace-panel')),
        findsNothing,
      );
      expect(directoryRequests, isEmpty);
      expect(transportRequests.where(_isMembershipRequest), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('does not query the directory until an authorized picker opens', (
    tester,
  ) async {
    _useWideViewport(tester);
    final requests = <HandrailMemberDirectorySearchRequest>[];

    await tester.pumpWidget(
      HandrailTimelineLabApp(
        searchDirectory: (request) {
          requests.add(request);
          return searchTimelineLabMemberDirectory(request);
        },
      ),
    );
    await _pumpUntil(
      tester,
      () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
    );

    expect(requests, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-direct')),
    );
    await _pumpUntil(tester, () => requests.isNotEmpty);
    expect(requests, hasLength(1));
    expect(requests.single.query, isEmpty);
  });

  for (final scenario in <({
    ConversationCreationReconciliationStatus status,
    String expectedConversationId,
  })>[
    (
      status: ConversationCreationReconciliationStatus.created,
      expectedConversationId: 'flutter-created-direct',
    ),
    (
      status: ConversationCreationReconciliationStatus.existingEquivalent,
      expectedConversationId: 'flutter-direct',
    ),
  ]) {
    testWidgets(
      'creates a direct and navigates to the ${scenario.status.toJson()} authoritative conversation',
      (tester) async {
        _useWideViewport(tester);
        final transportRequests = <HandrailChatHttpRequest>[];
        final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

        await tester.pumpWidget(
          HandrailTimelineLabApp(
            directCreationReconciliationStatus: scenario.status,
            onTransportRequest: transportRequests.add,
            searchDirectory: (request) {
              directoryRequests.add(request);
              return searchTimelineLabMemberDirectory(request);
            },
          ),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey<String>('handrail-create-direct'))
              .evaluate()
              .isNotEmpty,
        );
        transportRequests.clear();

        await tester.tap(
          find.byKey(const ValueKey<String>('handrail-create-direct')),
        );
        await _pumpUntil(tester, () => directoryRequests.isNotEmpty);
        await tester.enterText(
          find.byKey(
            const ValueKey<String>('handrail-create-direct-search'),
          ),
          'Grace',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await _pumpUntil(
          tester,
          () => directoryRequests.any((request) => request.query == 'Grace'),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(
                const ValueKey<String>(
                  'handrail-create-direct-user-grace',
                ),
              )
              .evaluate()
              .isNotEmpty,
        );

        await tester.tap(
          find.byKey(
            const ValueKey<String>('handrail-create-direct-user-grace'),
          ),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(
            const ValueKey<String>('handrail-create-direct-submit'),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              tester
                  .state<HandrailChatWorkspaceState>(
                    find.byType(HandrailChatWorkspace),
                  )
                  .selectedConversationId ==
              ConversationId(scenario.expectedConversationId),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(
                const ValueKey<String>('handrail-create-direct-dialog'),
              )
              .evaluate()
              .isEmpty,
        );

        final creationRequests =
            transportRequests.where(_isDirectCreationRequest);
        expect(creationRequests, hasLength(1));
        expect(
          jsonDecode(creationRequests.single.body!),
          const <String, Object?>{
            'operation': 'create_conversation',
            'type': 'direct',
            'visibility': 'private',
            'intendedMemberUserIds': ['grace'],
            'idempotencyKey': 'flutter-timeline-idempotency-key',
            'clientRequestId': 'flutter-timeline-client-request',
          },
        );
        expect(
          find.byKey(
            ValueKey<String>(
              'handrail-workspace-timeline-${scenario.expectedConversationId}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>('handrail-create-direct-dialog'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'denied direct creation hides its control and never queries the directory',
    (tester) async {
      _useWideViewport(tester);
      final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          canCreateDirectConversations: false,
          searchDirectory: (request) {
            directoryRequests.add(request);
            return searchTimelineLabMemberDirectory(request);
          },
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(workspace.directCreation?.authorized, isFalse);
      expect(
        find.byKey(const ValueKey<String>('handrail-create-direct')),
        findsNothing,
      );
      expect(find.text('New direct message'), findsNothing);
      expect(directoryRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in <({
    ConversationCreationReconciliationStatus status,
    String expectedConversationId,
  })>[
    (
      status: ConversationCreationReconciliationStatus.created,
      expectedConversationId: 'flutter-created-group-direct',
    ),
    (
      status: ConversationCreationReconciliationStatus.existingEquivalent,
      expectedConversationId: 'flutter-group-direct',
    ),
  ]) {
    testWidgets(
      'creates a group direct and navigates to the ${scenario.status.toJson()} authoritative conversation',
      (tester) async {
        _useWideViewport(tester);
        final transportRequests = <HandrailChatHttpRequest>[];
        final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

        await tester.pumpWidget(
          HandrailTimelineLabApp(
            groupDirectCreationReconciliationStatus: scenario.status,
            onTransportRequest: transportRequests.add,
            searchDirectory: (request) {
              directoryRequests.add(request);
              return searchTimelineLabMemberDirectory(request);
            },
          ),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(
                const ValueKey<String>('handrail-create-group-direct'),
              )
              .evaluate()
              .isNotEmpty,
        );
        transportRequests.clear();

        await tester.tap(
          find.byKey(
            const ValueKey<String>('handrail-create-group-direct'),
          ),
        );
        await _pumpUntil(tester, () => directoryRequests.isNotEmpty);
        const graceRow = ValueKey<String>(
          'handrail-create-group-direct-user-grace',
        );
        const margaretRow = ValueKey<String>(
          'handrail-create-group-direct-user-margaret',
        );
        const graceChip = ValueKey<String>(
          'handrail-create-group-direct-selected-grace',
        );
        const margaretChip = ValueKey<String>(
          'handrail-create-group-direct-selected-margaret',
        );
        await _pumpUntil(
          tester,
          () =>
              find.byKey(graceRow).evaluate().isNotEmpty &&
              find.byKey(margaretRow).evaluate().isNotEmpty,
        );

        await tester.tap(find.byKey(graceRow));
        await tester.pump();
        expect(find.byKey(graceChip), findsOneWidget);
        await tester.tap(find.byKey(graceRow));
        await tester.pump();
        expect(find.byKey(graceChip), findsNothing);
        await tester.tap(find.byKey(graceRow));
        await tester.tap(find.byKey(margaretRow));
        await tester.pump();
        expect(find.byKey(graceChip), findsOneWidget);
        expect(find.byKey(margaretChip), findsOneWidget);

        tester.widget<InputChip>(find.byKey(margaretChip)).onDeleted!();
        await tester.pump();
        expect(find.byKey(margaretChip), findsNothing);
        final submit = find.byKey(
          const ValueKey<String>('handrail-create-group-direct-submit'),
        );
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        await tester.tap(submit, warnIfMissed: false);
        await tester.pump();
        expect(
          transportRequests.where(_isGroupDirectCreationRequest),
          isEmpty,
        );

        await tester.tap(find.byKey(margaretRow));
        await tester.pump();
        expect(find.byKey(margaretChip), findsOneWidget);
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
        await tester.tap(submit);
        await _pumpUntil(
          tester,
          () =>
              tester
                  .state<HandrailChatWorkspaceState>(
                    find.byType(HandrailChatWorkspace),
                  )
                  .selectedConversationId ==
              ConversationId(scenario.expectedConversationId),
        );

        final creationRequests =
            transportRequests.where(_isGroupDirectCreationRequest);
        expect(creationRequests, hasLength(1));
        expect(
          jsonDecode(creationRequests.single.body!),
          const <String, Object?>{
            'operation': 'create_conversation',
            'type': 'group_direct',
            'visibility': 'private',
            'intendedMemberUserIds': ['grace', 'margaret'],
            'idempotencyKey': 'flutter-timeline-idempotency-key',
            'clientRequestId': 'flutter-timeline-client-request',
          },
        );
        final workspaceState = tester.state<HandrailChatWorkspaceState>(
          find.byType(HandrailChatWorkspace),
        );
        final client = ChatScope.of(
          tester.element(find.byType(HandrailChatWorkspace)),
        ).client;
        expect(
          client.normalizedState
              .conversation(ConversationId(scenario.expectedConversationId))
              .memberUserIds,
          const <UserId>[
            UserId('ada'),
            UserId('grace'),
            UserId('margaret'),
          ],
        );
        final listRequestCount =
            transportRequests.where(_isConversationListRequest).length;
        final refresh =
            workspaceState.debugConversationListController!.refresh();
        await _pumpUntil(
          tester,
          () =>
              transportRequests.where(_isConversationListRequest).length >
              listRequestCount,
        );
        await refresh;
        expect(
          find.byKey(
            ValueKey<String>(
              'handrail-channel-group-conversations-'
              '${scenario.expectedConversationId}-row',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            ValueKey<String>(
              'handrail-workspace-timeline-${scenario.expectedConversationId}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          workspaceState.selectedConversationId,
          ConversationId(scenario.expectedConversationId),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'denied group-direct creation hides its control and cannot query or submit',
    (tester) async {
      _useWideViewport(tester);
      final transportRequests = <HandrailChatHttpRequest>[];
      final directoryRequests = <HandrailMemberDirectorySearchRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          canCreateGroupDirectConversations: false,
          onTransportRequest: transportRequests.add,
          searchDirectory: (request) {
            directoryRequests.add(request);
            return searchTimelineLabMemberDirectory(request);
          },
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(workspace.groupDirectCreation?.authorized, isFalse);
      expect(
        find.byKey(const ValueKey<String>('handrail-create-group-direct')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-create-group-direct-dialog'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-create-group-direct-submit'),
        ),
        findsNothing,
      );
      expect(directoryRequests, isEmpty);
      expect(
        transportRequests.where(_isGroupDirectCreationRequest),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authorized group-direct creation cannot submit fewer than two people',
    (tester) async {
      _useWideViewport(tester);
      final transportRequests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: transportRequests.add),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>('handrail-create-group-direct'),
            )
            .evaluate()
            .isNotEmpty,
      );
      transportRequests.clear();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-create-group-direct'),
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>(
                'handrail-create-group-direct-user-grace',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'handrail-create-group-direct-user-grace',
          ),
        ),
      );
      await tester.pump();

      final submit = find.byKey(
        const ValueKey<String>('handrail-create-group-direct-submit'),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      expect(
        transportRequests.where(_isGroupDirectCreationRequest),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'renders one workspace, lists four conversation kinds, and switches timelines',
    (tester) async {
      _useWideViewport(tester);
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(const HandrailTimelineLabApp());
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );

      expect(find.byType(HandrailChatWorkspace), findsOneWidget);
      expect(find.byType(HandrailMessageTimeline), findsOneWidget);
      expect(find.text('Public channel'), findsWidgets);
      expect(find.text('Private channel'), findsOneWidget);
      expect(find.text('Direct message'), findsOneWidget);
      expect(find.text('Group conversation'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-public-channels-flutter-public-channel-row',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-private-channels-flutter-private-channel-row',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-direct-messages-flutter-direct-row',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-group-conversations-flutter-group-direct-row',
          ),
        ),
        findsOneWidget,
      );

      final workspaceState = tester.state<HandrailChatWorkspaceState>(
        find.byType(HandrailChatWorkspace),
      );
      final items = workspaceState.debugConversationListController!.state.items;
      expect(items, hasLength(4));
      expect(
        items[0].conversation,
        isA<ChannelConversation>().having(
          (conversation) => conversation.visibility,
          'visibility',
          ConversationVisibility.public,
        ),
      );
      expect(
        items[1].conversation,
        isA<ChannelConversation>().having(
          (conversation) => conversation.visibility,
          'visibility',
          ConversationVisibility.private,
        ),
      );
      expect(items[2].conversation, isA<DirectConversation>());
      expect(items[3].conversation, isA<GroupDirectConversation>());

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-private-channels-flutter-private-channel-row',
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('Private channel canonical timeline')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('Canonical sent fixture'), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'handrail-channel-public-channels-flutter-public-channel-row',
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.textContaining('Canonical sent fixture').evaluate().isNotEmpty,
      );
      _expectSinglePublicFixtureSet();

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-copy-message-sent')),
      );
      await _pumpUntil(
        tester,
        () => find.text('Message copied').evaluate().isNotEmpty,
      );
      expect(find.text('Message copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'direct send exposes running state and reconciles one canonical message',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];
      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _openDirectConversation(tester);
      requests.clear();

      final input = find.byKey(
        const ValueKey<String>('handrail-message-composer-input'),
      );
      final send = find.byKey(
        const ValueKey<String>('handrail-message-composer-send'),
      );
      await tester.enterText(input, 'QA huddle lifecycle campaign message');
      await tester.pump();
      expect(tester.widget<IconButton>(send).onPressed, isNotNull);
      await tester.tap(send);
      await tester.pump();

      expect(find.text('Sending message.'), findsOneWidget);
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-message-message-flutter-timeline-client-message',
          ),
        ),
        findsNothing,
      );

      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(
        tester,
        () => find
            .text('QA huddle lifecycle campaign message')
            .evaluate()
            .isNotEmpty,
      );

      final sendRequests = requests.where(_isSendMessageRequest).toList();
      expect(sendRequests, hasLength(1));
      expect(
        _sendMessageBody(sendRequests.single),
        containsPair('conversationId', 'flutter-direct'),
      );
      expect(
        (_sendMessageBody(sendRequests.single)['content']!
            as Map<String, Object?>)['text'],
        'QA huddle lifecycle campaign message',
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-message-message-flutter-timeline-client-message',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('The chat server returned an invalid command response.'),
          findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'direct send retry recovers after one sanitized fixture failure',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];
      await tester.pumpWidget(
        HandrailTimelineLabApp(
          sendResponse: TimelineLabSendResponse.recoverableFailure,
          onTransportRequest: requests.add,
        ),
      );
      await _openDirectConversation(tester);
      requests.clear();

      final input = find.byKey(
        const ValueKey<String>('handrail-message-composer-input'),
      );
      final send = find.byKey(
        const ValueKey<String>('handrail-message-composer-send'),
      );
      final retry = find.byKey(
        const ValueKey<String>('handrail-message-composer-retry'),
      );
      await tester.enterText(input, 'Recoverable direct message');
      await tester.pump();
      expect(tester.widget<IconButton>(send).onPressed, isNotNull);
      await tester.tap(send);
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(tester, () => retry.evaluate().isNotEmpty);

      expect(find.text('The chat command could not be completed.'), findsOne);
      expect(find.textContaining('UPSTREAM'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text,
          'Recoverable direct message');

      await tester.tap(retry);
      await tester.pump();
      expect(find.text('Sending message.'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(
        tester,
        () =>
            find.text('Recoverable direct message').evaluate().isNotEmpty &&
            retry.evaluate().isEmpty,
      );

      final sendRequests = requests.where(_isSendMessageRequest).toList();
      expect(sendRequests, hasLength(2));
      expect(
        sendRequests.map(
          (request) => (_sendMessageBody(request)['content']! as Map)['text'],
        ),
        everyElement('Recoverable direct message'),
      );
      expect(
          find.text('The chat command could not be completed.'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persistent direct send failure remains retryable and sanitized',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];
      await tester.pumpWidget(
        HandrailTimelineLabApp(
          sendResponse: TimelineLabSendResponse.persistentFailure,
          onTransportRequest: requests.add,
        ),
      );
      await _openDirectConversation(tester);
      requests.clear();

      final input = find.byKey(
        const ValueKey<String>('handrail-message-composer-input'),
      );
      final retry = find.byKey(
        const ValueKey<String>('handrail-message-composer-retry'),
      );
      await tester.enterText(input, 'Persistent direct message');
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-message-composer-send'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(tester, () => retry.evaluate().isNotEmpty);
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(
        tester,
        () =>
            requests.where(_isSendMessageRequest).length == 2 &&
            find
                .text('The chat command could not be completed.')
                .evaluate()
                .isNotEmpty,
      );

      expect(find.text('The chat command could not be completed.'), findsOne);
      expect(find.textContaining('invalid command response'), findsNothing);
      expect(find.textContaining('flutter-timeline'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text,
          'Persistent direct message');
      expect(retry, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creates a normalized public channel and refreshes its canonical fixture',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('handrail-create-channel'))
            .evaluate()
            .isNotEmpty,
      );
      requests.clear();

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-create-channel')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('handrail-create-channel-name')),
        '  Preview announcements  ',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-create-channel-submit')),
      );
      await _pumpUntil(
        tester,
        () =>
            tester
                .state<HandrailChatWorkspaceState>(
                  find.byType(HandrailChatWorkspace),
                )
                .selectedConversationId ==
            const ConversationId('flutter-created-public-channel'),
      );

      final creationRequests = requests.where(_isChannelCreationRequest);
      expect(creationRequests, hasLength(1));
      expect(
        jsonDecode(creationRequests.single.body!),
        const <String, Object?>{
          'operation': 'create_conversation',
          'type': 'channel',
          'name': 'Preview announcements',
          'visibility': 'public',
          'idempotencyKey': 'flutter-timeline-idempotency-key',
          'clientRequestId': 'flutter-timeline-client-request',
        },
      );

      final workspaceState = tester.state<HandrailChatWorkspaceState>(
        find.byType(HandrailChatWorkspace),
      );
      final refresh = workspaceState.debugConversationListController!.refresh();
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>(
                'handrail-channel-public-channels-flutter-created-public-channel-row',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );
      await refresh;
      final created = workspaceState
          .debugConversationListController!.state.items
          .singleWhere(
        (item) =>
            item.conversationId ==
            const ConversationId('flutter-created-public-channel'),
      );
      expect(
        created.conversation,
        isA<ChannelConversation>()
            .having(
              (conversation) => conversation.name,
              'name',
              'Preview announcements',
            )
            .having(
              (conversation) => conversation.visibility,
              'visibility',
              ConversationVisibility.public,
            ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creates a private channel with a distinct authoritative fixture ID',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('handrail-create-channel'))
            .evaluate()
            .isNotEmpty,
      );
      requests.clear();

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-create-channel')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('handrail-create-channel-name')),
        'Private launch',
      );
      await tester.tap(find.text('Private').last);
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-create-channel-submit')),
      );
      await _pumpUntil(
        tester,
        () =>
            tester
                .state<HandrailChatWorkspaceState>(
                  find.byType(HandrailChatWorkspace),
                )
                .selectedConversationId ==
            const ConversationId('flutter-created-private-channel'),
      );

      final creationRequests = requests.where(_isChannelCreationRequest);
      expect(creationRequests, hasLength(1));
      expect(
        jsonDecode(creationRequests.single.body!),
        const <String, Object?>{
          'operation': 'create_conversation',
          'type': 'channel',
          'name': 'Private launch',
          'visibility': 'private',
          'idempotencyKey': 'flutter-timeline-idempotency-key',
          'clientRequestId': 'flutter-timeline-client-request',
        },
      );

      final workspaceState = tester.state<HandrailChatWorkspaceState>(
        find.byType(HandrailChatWorkspace),
      );
      final refresh = workspaceState.debugConversationListController!.refresh();
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>(
                'handrail-channel-private-channels-flutter-created-private-channel-row',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );
      await refresh;
      final created = workspaceState
          .debugConversationListController!.state.items
          .singleWhere(
        (item) =>
            item.conversationId ==
            const ConversationId('flutter-created-private-channel'),
      );
      expect(
        created.conversation,
        isA<ChannelConversation>()
            .having(
              (conversation) => conversation.name,
              'name',
              'Private launch',
            )
            .having(
              (conversation) => conversation.visibility,
              'visibility',
              ConversationVisibility.private,
            ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rejects a blank channel name without issuing a POST',
      (tester) async {
    _useWideViewport(tester);
    final requests = <HandrailChatHttpRequest>[];

    await tester.pumpWidget(
      HandrailTimelineLabApp(onTransportRequest: requests.add),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('handrail-create-channel'))
          .evaluate()
          .isNotEmpty,
    );
    requests.clear();

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('handrail-create-channel-name')),
      '   \n  ',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-create-channel-submit')),
    );
    await tester.pump();

    expect(find.text('Enter a channel name.'), findsOneWidget);
    expect(requests.where(_isChannelCreationRequest), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hides channel creation in the explicitly denied fixture mode',
      (tester) async {
    _useWideViewport(tester);

    await tester.pumpWidget(
      const HandrailTimelineLabApp(canCreateChannels: false),
    );
    await _pumpUntil(
      tester,
      () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
    );

    final workspace = tester.widget<HandrailChatWorkspace>(
      find.byType(HandrailChatWorkspace),
    );
    expect(workspace.canCreateChannels, isFalse);
    expect(
      find.byKey(const ValueKey<String>('handrail-create-channel')),
      findsNothing,
    );
    expect(find.text('Create channel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'negotiates SDK search, excludes private data, and focuses the opened hit',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _pumpUntil(
        tester,
        () =>
            find.text('Optimistic unsent fixture').evaluate().isNotEmpty &&
            find
                .byKey(
                  const ValueKey<String>('handrail-workspace-search'),
                )
                .evaluate()
                .isNotEmpty,
      );

      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(workspace.messageSearch, isNull);
      final binding = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      );
      expect(binding.state, isA<ChatClientReadyState>());
      expect(
        (binding.state as ChatClientReadyState)
            .negotiatedCapabilities[messageSearchFeature],
        isTrue,
      );
      expect(
        requests.where(
          (request) =>
              request.method == 'GET' && request.uri.path.endsWith('/_meta'),
        ),
        hasLength(1),
      );
      requests.clear();

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-workspace-search')),
      );
      await tester.pump();
      final searchField = find.byKey(
        const ValueKey<String>('handrail-message-search-field'),
      );
      expect(searchField, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('handrail-message-search-initial')),
        findsOneWidget,
      );
      expect(requests.where(_isMessageSearchRequest), isEmpty);

      await tester.enterText(searchField, '   \n  ');
      await tester.pump(const Duration(milliseconds: 301));
      expect(requests.where(_isMessageSearchRequest), isEmpty);
      expect(
        find.byKey(const ValueKey<String>('handrail-message-search-initial')),
        findsOneWidget,
      );

      await tester.enterText(searchField, 'vaulted saffron');
      await tester.pump(const Duration(milliseconds: 301));
      await _pumpUntil(
        tester,
        () => requests.where(_isMessageSearchRequest).length == 1,
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>('handrail-message-search-empty'),
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Inaccessible private channel'), findsNothing);

      await tester.enterText(searchField, '  canonical   rendezvous  ');
      await tester.pump(const Duration(milliseconds: 301));
      await _pumpUntil(
        tester,
        () => requests.where(_isMessageSearchRequest).length == 2,
      );
      final searchRequest = requests.where(_isMessageSearchRequest).last;
      expect(
        jsonDecode(searchRequest.body!),
        const <String, Object?>{
          'query': 'canonical rendezvous',
          'pageSize': 50,
        },
      );
      const searchHitKey = ValueKey<String>(
        'handrail-message-search-hit-message-0',
      );
      await _pumpUntil(
        tester,
        () => find.byKey(searchHitKey).evaluate().isNotEmpty,
      );
      expect(find.byKey(searchHitKey), findsOneWidget);
      expect(
        tester
            .state<HandrailMessageSearchState>(
              find.byType(HandrailMessageSearch),
            )
            .debugRetainedHitCount,
        1,
      );
      expect(
        find.descendant(
          of: find.byKey(searchHitKey),
          matching: find.text('Direct message'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('canonical rendezvous'), findsOneWidget);

      await tester.tap(find.byKey(searchHitKey));
      await _pumpUntil(
        tester,
        () {
          final state = tester.state<HandrailChatWorkspaceState>(
            find.byType(HandrailChatWorkspace),
          );
          return state.selectedConversationId ==
                  const ConversationId('flutter-direct') &&
              find
                  .byKey(
                    const ValueKey<String>('handrail-message-message-direct'),
                  )
                  .evaluate()
                  .isNotEmpty;
        },
      );
      const focusedMessageKey = ValueKey<String>(
        'timeline-lab-search-focus-message-direct',
      );
      await _pumpUntil(
        tester,
        () =>
            find.byKey(focusedMessageKey).evaluate().isNotEmpty &&
            tester.widget<Focus>(find.byKey(focusedMessageKey)).focusNode !=
                null &&
            tester
                .widget<Focus>(find.byKey(focusedMessageKey))
                .focusNode!
                .hasFocus,
      );
      expect(find.text('Direct conversation canonical rendezvous timeline'),
          findsOneWidget);
      expect(
        tester.widget<Focus>(find.byKey(focusedMessageKey)).focusNode!.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hydrates canonical reaction aggregates through two emoji add/remove cycles',
    (tester) async {
      _useWideViewport(tester);
      await _pumpPublicWorkspace(tester);

      expect(
        find.byKey(
          const ValueKey<String>('handrail-add-reaction-message-sent'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-add-reaction-message-deleted'),
        ),
        findsNothing,
      );
      final optimisticAction = find.byKey(
        const ValueKey<String>('handrail-add-reaction-message-optimistic'),
      );
      expect(optimisticAction, findsNothing);
      expect(
        find.byKey(const ValueKey('handrail-reaction-picker')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-add-reaction-message-sent'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('handrail-reaction-picker')),
          findsOneWidget);
      _expectReaction(tester, '👍', count: 2, selected: false);
      _expectReaction(tester, '❤️', count: 2, selected: true);

      await _toggleReaction(
        tester,
        '👍',
        expectedCount: 3,
        expectedSelected: true,
      );
      await _toggleReaction(
        tester,
        '❤️',
        expectedCount: 1,
        expectedSelected: false,
      );
      await _toggleReaction(
        tester,
        '👍',
        expectedCount: 2,
        expectedSelected: false,
      );
      await _toggleReaction(
        tester,
        '❤️',
        expectedCount: 2,
        expectedSelected: true,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('handrail-workspace-close-panel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('handrail-reaction-picker')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mark unread sends one public request, moves its boundary, and retains focus',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _pumpUntil(
        tester,
        () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
      );
      requests.clear();

      const actionKey = ValueKey<String>(
        'handrail-mark-unread-message-zero-reply-root',
      );
      final action = find.byKey(actionKey);
      expect(action, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('handrail-unread-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-mark-unread-message-deleted'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-mark-unread-message-optimistic'),
        ),
        findsNothing,
      );
      final client = ChatScope.of(
        tester.element(find.byType(HandrailMessageTimeline)),
      ).client;

      final focusNode = tester.widget<TextButton>(action).focusNode!;
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      tester.widget<TextButton>(action).onPressed!();

      await _pumpUntil(
        tester,
        () => requests.where(_isReadCursorRequest).length == 1,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final readCursorRequests =
          requests.where(_isReadCursorRequest).toList(growable: false);
      expect(readCursorRequests, hasLength(1));
      final body =
          jsonDecode(readCursorRequests.single.body!) as Map<String, Object?>;
      expect(body['operation'], 'mark_unread');
      expect(body['conversationId'], 'flutter-public-channel');
      expect(body['fromSequence'], 3);

      expect(
        client
            .normalizedState
            .state
            .currentUserReadStates[
                const ConversationId('flutter-public-channel')]
            ?.manualUnreadFromSequence,
        const MessageSequence(3),
      );
      expect(
        find.byKey(const ValueKey<String>('handrail-unread-3')),
        findsOneWidget,
      );
      expect(find.byKey(actionKey), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(actionKey)).onPressed,
          isNotNull);
      expect(focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'forwards an eligible canonical message to an authorized destination',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );
      await _pumpUntil(
        tester,
        () => find.text('Canonical attachment fixture').evaluate().isNotEmpty,
      );
      requests.clear();

      const forwardAction = ValueKey<String>('handrail-forward-message-sent');
      expect(find.byKey(forwardAction), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('handrail-forward-message-deleted'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-forward-message-optimistic'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('handrail-forward-message-with-attachment'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(forwardAction));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('handrail-forward-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-forward-destination-flutter-private-channel',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'handrail-forward-destination-flutter-unavailable',
          ),
        ),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'handrail-forward-destination-flutter-private-channel',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-forward-submit')),
      );
      await _pumpUntil(
        tester,
        () => requests.where(_isForwardRequest).length == 1,
      );

      final transportRequest = requests.where(_isForwardRequest).single;
      final forwardRequest = ForwardMessageRequest.fromJson(
        jsonDecode(transportRequest.body!),
      );
      expect(forwardRequest.sourceMessageId, const MessageId('message-sent'));
      expect(
        forwardRequest.destinationConversationId,
        const ConversationId('flutter-private-channel'),
      );

      final workspaceState = tester.state<HandrailChatWorkspaceState>(
        find.byType(HandrailChatWorkspace),
      );
      await _pumpUntil(
        tester,
        () =>
            workspaceState.selectedConversationId ==
                const ConversationId('flutter-private-channel') &&
            find.text(_forwardedText).evaluate().isNotEmpty,
      );
      final client = ChatScope.of(
        tester.element(find.byType(HandrailMessageTimeline)),
      ).client;
      final forwarded = client.normalizedState.state
              .canonicalMessages[const MessageId('message-forwarded-private')]!
          as ActiveMessage;
      expect(forwarded.conversationId,
          const ConversationId('flutter-private-channel'));
      expect(forwarded.revision.revision, 1);
      expect(forwarded.content.text, _forwardedText);
      expect(
        forwarded.content.forwarded!.sourceMessageId,
        const MessageId('message-sent'),
      );
      expect(
        forwarded.content.forwarded!.originalAuthor.userId,
        const UserId('grace'),
      );
      expect(
        forwarded.content.forwarded!.originalAuthor.displayName,
        'Grace Hopper',
      );
      expect(
        forwarded.content.forwarded!.originalCreatedAt,
        const IsoTimestamp('2026-08-28T19:30:00.000Z'),
      );
      expect(find.text(_forwardedText), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opens seeded and zero-reply threads then reconciles one canonical reply',
    (tester) async {
      _useWideViewport(tester);
      await _pumpPublicWorkspace(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-thread-message-sent')),
      );
      await _pumpUntil(
        tester,
        () => find.text('Seeded existing thread reply').evaluate().isNotEmpty,
      );
      expect(find.byType(HandrailThreadView), findsOneWidget);
      expect(find.text('Seeded existing thread reply'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-thread-close')),
      );
      await _pumpUntil(
        tester,
        () => find.byType(HandrailThreadView).evaluate().isEmpty,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'handrail-reply-message-zero-reply-root',
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              const ValueKey<String>(
                'handrail-thread-composer-flutter-thread-created',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );

      final threadView = find.byType(HandrailThreadView);
      final replyInput = find.descendant(
        of: threadView,
        matching: find.byKey(
          const ValueKey<String>('handrail-message-composer-input'),
        ),
      );
      final sendReply = find.descendant(
        of: threadView,
        matching: find.byKey(
          const ValueKey<String>('handrail-message-composer-send'),
        ),
      );
      final client = ChatScope.of(tester.element(threadView)).client;
      await tester.enterText(replyInput, 'Canonical interactive thread reply');
      await tester.pump();
      expect(tester.widget<IconButton>(sendReply).onPressed, isNotNull);
      await tester.tap(sendReply);
      await _pumpUntil(
        tester,
        () {
          final root = client.normalizedState.state
              .canonicalMessages[const MessageId('message-zero-reply-root')];
          final replies = client.normalizedState
              .timeline(const ConversationId('flutter-thread-created'))
              .messages
              .where(
                (message) =>
                    message.id ==
                    const MessageId('message-created-thread-reply'),
              );
          return root?.threadSummary?.replyCount == 1 && replies.length == 1;
        },
      );

      expect(
        find.text('Canonical interactive thread reply'),
        findsOneWidget,
      );
      expect(
        client
            .normalizedState
            .state
            .canonicalMessages[const MessageId('message-zero-reply-root')]!
            .threadSummary!
            .replyCount,
        1,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-thread-close')),
      );
      await _pumpUntil(
        tester,
        () => find
            .descendant(
              of: find.byKey(
                const ValueKey<String>(
                  'handrail-thread-message-zero-reply-root',
                ),
              ),
              matching: find.text('1 reply'),
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>(
              'handrail-thread-message-zero-reply-root',
            ),
          ),
          matching: find.text('1 reply'),
        ),
        findsOneWidget,
      );

      final replies = client.normalizedState
          .timeline(const ConversationId('flutter-thread-created'))
          .messages
          .where(
            (message) =>
                message.id == const MessageId('message-created-thread-reply'),
          )
          .toList(growable: false);
      expect(replies, hasLength(1));
      expect(
        client.normalizedState.isCanonicalMessage(replies.single.id),
        isTrue,
      );
      expect(
        client
            .normalizedState
            .state
            .canonicalMessages[const MessageId('message-zero-reply-root')]!
            .threadSummary!
            .replyCount,
        1,
      );
      expect(
        client.normalizedState.pendingOptimisticSendClientMessageIds,
        const {'client-message-optimistic'},
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'huddle panel runs canonical start join leave and end lifecycle',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];
      await tester.pumpWidget(
        HandrailTimelineLabApp(onTransportRequest: requests.add),
      );

      final controller = await _openHuddlePanel(tester);
      final binding = ChatScope.of(
        tester.element(find.byType(HandrailChatWorkspace)),
      );
      expect(binding.state, isA<ChatClientReadyState>());
      expect(
        (binding.state as ChatClientReadyState)
            .negotiatedCapabilities['huddles'],
        isTrue,
      );
      expect(controller.state.canonicalState, isA<InactiveHuddleState>());
      expect(find.text('Inactive'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-start')),
      );
      await _pumpUntil(
        tester,
        () => controller.state.canonicalState is StartingHuddleState,
      );
      final starting = controller.state.canonicalState as StartingHuddleState;
      expect(starting.status, HuddleSessionStatus.starting);
      expect(starting.participants, isEmpty);
      expect(find.text('Starting'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
      );
      await _pumpUntil(
        tester,
        () {
          final state = controller.state.canonicalState;
          return state is ActiveHuddleState &&
              state.participants.length == 1 &&
              state.participants.single.status ==
                  HuddleParticipantStatus.joined;
        },
      );
      final joined = controller.state.canonicalState as ActiveHuddleState;
      expect(joined.status, HuddleSessionStatus.active);
      expect(joined.participants.single.userId, const UserId('ada'));
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('ada'), findsOneWidget);
      expect(find.text('Joined'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-leave')),
      );
      await _pumpUntil(
        tester,
        () {
          final state = controller.state.canonicalState;
          return state is ActiveHuddleState &&
              state.participants.single.status == HuddleParticipantStatus.left;
        },
      );
      final left = controller.state.canonicalState as ActiveHuddleState;
      expect(left.status, HuddleSessionStatus.active);
      expect(left.participants.single.userId, const UserId('ada'));
      expect(left.participants.single, isA<HuddleLeftParticipant>());
      expect(find.text('Departed'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-end')),
      );
      await _pumpUntil(
        tester,
        () => controller.state.canonicalState is EndedHuddleState,
      );
      final ended = controller.state.canonicalState as EndedHuddleState;
      expect(ended.status, HuddleSessionStatus.ended);
      expect(ended.endedByUserId, const UserId('ada'));
      expect(ended.participants, hasLength(1));
      expect(ended.participants.single.status, HuddleParticipantStatus.left);
      expect(find.text('Huddle ended'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('handrail-huddle-end')),
        findsNothing,
      );

      final commands = requests.where(_isHuddleCommandRequest).toList();
      expect(commands, hasLength(4));
      expect(
        commands.map((request) => _huddleInput(request).operation),
        const <String>[
          'start_huddle',
          'join_huddle',
          'leave_huddle',
          'end_huddle',
        ],
      );
      expect(
        requests.where(_isHuddleSnapshotRequest),
        hasLength(1),
      );

      final requestCountBeforeTeardown = requests.length;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final afterTeardown = await controller.hydrate();
      expect(
        afterTeardown,
        isA<ChatHuddleActionFailure>().having(
          (failure) => failure.code,
          'code',
          ChatHuddleErrorCode.closed,
        ),
      );
      expect(requests, hasLength(requestCountBeforeTeardown));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'development-only huddle media connects after join and closes with panel',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];
      final mediaDelegate = TimelineLabLocalMediaDelegate();
      await tester.pumpWidget(
        HandrailTimelineLabApp(
          huddleMediaDelegate: mediaDelegate,
          onTransportRequest: requests.add,
        ),
      );

      final controller = await _openHuddlePanel(tester);
      final workspace = tester.widget<HandrailChatWorkspace>(
        find.byType(HandrailChatWorkspace),
      );
      expect(workspace.huddleMediaDelegate, same(mediaDelegate));
      expect(mediaDelegate.connectCount, 0);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-start')),
      );
      await _pumpUntil(
        tester,
        () => controller.state.canonicalState is StartingHuddleState,
      );
      expect(controller.state.media, isA<ChatHuddleMediaReadyState>());
      expect(
        mediaDelegate.connectCount,
        0,
        reason: 'Join material alone must not connect before canonical join.',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
      );
      await _pumpUntil(tester, () => mediaDelegate.connectCount == 1);
      final provider = mediaDelegate.sessions.single;
      expect(
        controller.state.canonicalState,
        isA<ActiveHuddleState>(),
      );
      expect(find.text('Built-in microphone'), findsOneWidget);
      expect(find.text('Built-in speaker'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-microphone')),
      );
      await _pumpUntil(
        tester,
        () => provider.microphoneChanges.length == 1,
      );
      expect(provider.microphoneChanges, const <bool>[true]);
      expect(
        mediaDelegate.permissionRequests,
        const <ChatMediaPermission>[ChatMediaPermission.microphone],
      );
      expect(find.bySemanticsLabel('Mute microphone'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-audio-input')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview USB microphone').last);
      await _pumpUntil(
        tester,
        () => provider.selectedAudioInputs.isNotEmpty,
      );
      expect(
        provider.selectedAudioInputs,
        const <String?>['timeline-usb-microphone'],
      );

      provider.emitActiveSpeakers(const <ChatMediaActiveSpeaker>[
        ChatMediaActiveSpeaker(participantId: 'ada', isSpeaking: true),
      ]);
      await _pumpUntil(
        tester,
        () => find.text('Speaking').evaluate().isNotEmpty,
      );
      expect(find.text('Speaking'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('ada, Joined, active speaker')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-screen-share')),
      );
      await _pumpUntil(
        tester,
        () => provider.screenShareChanges.length == 1,
      );
      var canonical = controller.state.canonicalState as ActiveHuddleState;
      expect(canonical.screenShareOwnerUserId, const UserId('ada'));
      expect(provider.screenShareChanges, const <bool>[true]);
      expect(find.bySemanticsLabel('Stop screen sharing'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-screen-share')),
      );
      await _pumpUntil(
        tester,
        () => provider.screenShareChanges.length == 2,
      );
      canonical = controller.state.canonicalState as ActiveHuddleState;
      expect(canonical.screenShareOwnerUserId, isNull);
      expect(provider.screenShareChanges, const <bool>[true, false]);
      expect(find.bySemanticsLabel('Start screen sharing'), findsOneWidget);
      final screenShareInputs = requests
          .where(_isHuddleCommandRequest)
          .map(_huddleInput)
          .whereType<SetHuddleScreenShareInput>();
      expect(
        screenShareInputs.map((input) => input.intent),
        const <HuddleScreenShareIntent>[
          HuddleScreenShareIntent.set,
          HuddleScreenShareIntent.clear,
        ],
      );

      final mediaActivityBeforeClose = provider.mediaActivityCount;
      final requestCountBeforeClose = requests.length;
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-workspace-close-panel')),
      );
      await _pumpUntil(tester, () => provider.closed);
      _expectClosedLocalMediaProvider(provider);
      expect(find.byType(HandrailHuddlePanel), findsNothing);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(provider.mediaActivityCount, mediaActivityBeforeClose);
      expect(requests, hasLength(requestCountBeforeClose));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local media permission denial is sanitized and app disposal closes media',
    (tester) async {
      _useWideViewport(tester);
      final mediaDelegate = TimelineLabLocalMediaDelegate(
        permissionDecisions: const {
          ChatMediaPermission.microphone: ChatMediaPermissionDecision.denied,
        },
      );
      await tester.pumpWidget(
        HandrailTimelineLabApp(huddleMediaDelegate: mediaDelegate),
      );
      final controller = await _openHuddlePanel(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-start')),
      );
      await _pumpUntil(
        tester,
        () => controller.state.canonicalState is StartingHuddleState,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
      );
      await _pumpUntil(tester, () => mediaDelegate.connectCount == 1);
      final provider = mediaDelegate.sessions.single;

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-microphone')),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('Microphone permission was denied.')
            .evaluate()
            .isNotEmpty,
      );
      expect(provider.microphoneChanges, isEmpty);
      expect(
        mediaDelegate.permissionRequests,
        const <ChatMediaPermission>[ChatMediaPermission.microphone],
      );
      expect(
        find.textContaining('opaque-flutter-preview-huddle-descriptor'),
        findsNothing,
      );
      expect(find.textContaining('provider'), findsNothing);

      final mediaActivityBeforeDispose = provider.mediaActivityCount;
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(tester, () => provider.closed);
      _expectClosedLocalMediaProvider(provider);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(provider.mediaActivityCount, mediaActivityBeforeDispose);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'non-host huddle joins an active fixture while host actions stay denied',
    (tester) async {
      _useWideViewport(tester);
      final requests = <HandrailChatHttpRequest>[];

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          huddleActor: TimelineLabHuddleActor.member,
          onTransportRequest: requests.add,
        ),
      );
      final inactiveController = await _openHuddlePanel(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-start')),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('Huddle access could not be verified.')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        inactiveController.state.canonicalState,
        isA<InactiveHuddleState>(),
      );
      expect(
        find.textContaining('private huddle authorization fixture detail'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        await inactiveController.hydrate(),
        isA<ChatHuddleActionFailure>().having(
          (failure) => failure.code,
          'code',
          ChatHuddleErrorCode.closed,
        ),
      );

      await tester.pumpWidget(
        HandrailTimelineLabApp(
          huddleActor: TimelineLabHuddleActor.member,
          seedActiveHuddle: true,
          onTransportRequest: requests.add,
        ),
      );
      final activeController = await _openHuddlePanel(tester);
      final beforeJoin =
          activeController.state.canonicalState as ActiveHuddleState;
      expect(beforeJoin.status, HuddleSessionStatus.active);
      expect(
        beforeJoin.participants.map((participant) => participant.userId),
        const <UserId>[UserId('ada')],
      );
      expect(
        beforeJoin.participants.every((participant) =>
            participant.status == HuddleParticipantStatus.joined),
        isTrue,
      );
      expect(find.text('ada'), findsOneWidget);
      expect(find.text('grace'), findsNothing);
      expect(find.text('Joined'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-join')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('handrail-huddle-leave'))
            .evaluate()
            .isNotEmpty,
      );
      final beforeDeniedEnd =
          activeController.state.canonicalState as ActiveHuddleState;
      expect(
        beforeDeniedEnd.participants.map((participant) => participant.userId),
        const <UserId>[UserId('ada'), UserId('grace')],
      );
      expect(find.text('grace'), findsOneWidget);
      expect(find.text('Joined'), findsNWidgets(2));
      expect(find.text('Huddle action could not be completed.'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('handrail-huddle-end')),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('Huddle access could not be verified.')
            .evaluate()
            .isNotEmpty,
      );
      final afterDeniedEnd =
          activeController.state.canonicalState as ActiveHuddleState;
      expect(afterDeniedEnd.toJson(), beforeDeniedEnd.toJson());
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Joined'), findsNWidgets(2));
      expect(
        find.textContaining('private huddle authorization fixture detail'),
        findsNothing,
      );

      final huddleCommands = requests.where(_isHuddleCommandRequest).toList();
      expect(huddleCommands, hasLength(3));
      expect(
        huddleCommands.map((request) => _huddleInput(request).operation),
        const <String>['start_huddle', 'join_huddle', 'end_huddle'],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reminder scheduling still applies from the workspace timeline', (
    tester,
  ) async {
    _useWideViewport(tester);
    await _pumpPublicWorkspace(tester);

    await _openSentReminder(tester);
    expect(find.text('No reminder scheduled'), findsOneWidget);
    expect(
      find.bySemanticsLabel('No reminder scheduled. Revision 0'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-reminder-preset-20-minutes')),
    );
    await _pumpUntil(
      tester,
      () => find.text('Reminder scheduled').evaluate().isNotEmpty,
    );
    expect(find.textContaining('Revision 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reminder failures stay sanitized in the workspace timeline', (
    tester,
  ) async {
    _useWideViewport(tester);
    await _pumpPublicWorkspace(tester);
    await _chooseResponse(tester, 'Return sanitized error');

    await _openSentReminder(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-reminder-preset-1-hour')),
    );
    await _pumpUntil(
      tester,
      () => find.text("Reminder couldn't be updated").evaluate().isNotEmpty,
    );

    expect(
      find.textContaining('private upstream reminder fixture detail'),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel('No reminder scheduled. Revision 0'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reminder revision conflicts reconcile in the workspace timeline',
      (
    tester,
  ) async {
    _useWideViewport(tester);
    await _pumpPublicWorkspace(tester);
    await _chooseResponse(tester, 'Return revision conflict');

    await _openSentReminder(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('handrail-reminder-preset-20-minutes')),
    );
    await _pumpUntil(
      tester,
      () => find
          .text('Reminder changed on the server. Showing the latest schedule.')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.textContaining('Revision 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

bool _isReadCursorRequest(HandrailChatHttpRequest request) =>
    request.method == readCursorMutationMethod &&
    request.uri.path.endsWith('/read-cursor');

bool _isForwardRequest(HandrailChatHttpRequest request) =>
    request.method == 'POST' && request.uri.path.endsWith('/messages/forward');

bool _isMessageSearchRequest(HandrailChatHttpRequest request) =>
    request.method == 'POST' && request.uri.path.endsWith('/messages/search');

bool _isSendMessageRequest(HandrailChatHttpRequest request) =>
    request.method == 'POST' &&
    request.uri.path.endsWith('/messages') &&
    !request.uri.path.endsWith('/messages/search');

Map<String, Object?> _sendMessageBody(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

bool _isHuddleSnapshotRequest(HandrailChatHttpRequest request) =>
    request.method == 'GET' && request.uri.path.endsWith('/huddle');

bool _isHuddleCommandRequest(HandrailChatHttpRequest request) =>
    request.body != null && request.uri.pathSegments.contains('huddles');

HuddleCommandInput _huddleInput(HandrailChatHttpRequest request) =>
    HuddleCommandInput.fromJson(jsonDecode(request.body!));

bool _isChannelCreationRequest(HandrailChatHttpRequest request) =>
    _isConversationCreationRequest(request, 'channel');

bool _isDirectCreationRequest(HandrailChatHttpRequest request) =>
    _isConversationCreationRequest(request, 'direct');

bool _isGroupDirectCreationRequest(HandrailChatHttpRequest request) =>
    _isConversationCreationRequest(request, 'group_direct');

bool _isMembershipRequest(HandrailChatHttpRequest request) =>
    request.method == 'PATCH' && request.uri.path.endsWith('/membership');

Map<String, Object?> _membershipBody(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

bool _isPreferenceRequest(HandrailChatHttpRequest request) =>
    request.method == 'PATCH' && request.uri.path.endsWith('/preference');

Map<String, Object?> _preferenceBody(HandrailChatHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

bool _isConversationDetailRequest(
  HandrailChatHttpRequest request,
  ConversationId conversationId,
) =>
    request.method == 'GET' &&
    request.uri.path.endsWith('/conversations/${conversationId.value}');

bool _isConversationListRequest(HandrailChatHttpRequest request) =>
    request.method == 'GET' && request.uri.path.endsWith('/conversations');

bool _isConversationCreationRequest(
  HandrailChatHttpRequest request,
  String type,
) {
  if (request.method != 'POST' ||
      !request.uri.path.endsWith('/conversations') ||
      request.body == null) {
    return false;
  }
  final body = jsonDecode(request.body!);
  return body is Map<String, Object?> && body['type'] == type;
}

const _forwardedText =
    'Canonical sent fixture — open Remind me to inspect the Flutter sheet.';

void _useWideViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPublicWorkspace(WidgetTester tester) async {
  await tester.pumpWidget(
    const HandrailTimelineLabPreview(workspaceTitle: 'Handrail ERP Chat'),
  );
  await _pumpUntil(
    tester,
    () => find.text('Optimistic unsent fixture').evaluate().isNotEmpty,
  );
  expect(find.text('Handrail ERP Chat'), findsOneWidget);
  expect(find.byType(HandrailChatWorkspace), findsOneWidget);
  _expectSinglePublicFixtureSet();
}

Future<void> _openDirectConversation(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () => find
        .byKey(
          const ValueKey<String>(
            'handrail-channel-direct-messages-flutter-direct-row',
          ),
        )
        .evaluate()
        .isNotEmpty,
  );
  await tester.tap(
    find.byKey(
      const ValueKey<String>(
        'handrail-channel-direct-messages-flutter-direct-row',
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .text('Direct conversation canonical rendezvous timeline')
        .evaluate()
        .isNotEmpty,
  );
}

Future<ChatHuddleController> _openHuddlePanel(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey<String>('handrail-workspace-huddle'))
        .evaluate()
        .isNotEmpty,
  );
  final client = ChatScope.of(
    tester.element(find.byType(HandrailChatWorkspace)),
  ).client;
  final controller = client.huddles.forConversation(
    const ConversationId('flutter-public-channel'),
  );
  await tester.tap(
    find.byKey(const ValueKey<String>('handrail-workspace-huddle')),
  );
  await _pumpUntil(
    tester,
    () => controller.state.hydrationStatus == ChatHuddleHydrationStatus.ready,
  );
  expect(find.byType(HandrailHuddlePanel), findsOneWidget);
  return controller;
}

void _expectClosedLocalMediaProvider(
  TimelineLabLocalMediaProviderSession provider,
) {
  expect(provider.closeCount, 1);
  expect(provider.microphoneTrackClosed, isTrue);
  expect(provider.screenShareTrackClosed, isTrue);
  expect(provider.remoteSubscriptionsClosed, isTrue);
  expect(provider.deviceStreamClosed, isTrue);
  expect(provider.activeSpeakerStreamClosed, isTrue);
  expect(provider.deviceSubscriptionCount, 1);
  expect(provider.deviceSubscriptionCancelCount, 1);
  expect(provider.activeSpeakerSubscriptionCount, 1);
  expect(provider.activeSpeakerSubscriptionCancelCount, 1);
}

void _expectSinglePublicFixtureSet() {
  expect(find.byType(HandrailMessageTimeline), findsOneWidget);
  expect(find.bySemanticsLabel('Message timeline'), findsOneWidget);
  expect(find.textContaining('Canonical sent fixture'), findsOneWidget);
  expect(find.text('Canonical zero-reply thread root'), findsOneWidget);
  expect(find.text('Canonical attachment fixture'), findsOneWidget);
  expect(find.text('Message deleted'), findsOneWidget);
  expect(find.text('Optimistic unsent fixture'), findsOneWidget);
  expect(find.text('New messages'), findsOneWidget);
  expect(find.widgetWithText(TextButton, 'Remind me'), findsNWidgets(3));
  expect(find.widgetWithText(TextButton, 'Copy'), findsNWidgets(4));
  expect(find.widgetWithText(TextButton, 'Reply'), findsNWidgets(2));
  expect(find.text('1 reply'), findsOneWidget);
}

Future<void> _openSentReminder(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('handrail-remind-message-sent')),
  );
  await tester.pumpAndSettle();
}

Future<void> _toggleReaction(
  WidgetTester tester,
  String reactionKey, {
  required int expectedCount,
  required bool expectedSelected,
}) async {
  await tester
      .tap(find.byKey(ValueKey<String>('handrail-reaction-$reactionKey')));
  await _pumpUntil(
    tester,
    () {
      final aggregate = _canonicalReaction(tester, reactionKey);
      return aggregate?.count == expectedCount &&
          aggregate?.reactedByCurrentUser == expectedSelected;
    },
  );
  _expectReaction(
    tester,
    reactionKey,
    count: expectedCount,
    selected: expectedSelected,
  );
}

void _expectReaction(
  WidgetTester tester,
  String reactionKey, {
  required int count,
  required bool selected,
}) {
  final aggregate = _canonicalReaction(tester, reactionKey);
  expect(aggregate, isNotNull);
  expect(aggregate!.count, count);
  expect(aggregate.reactedByCurrentUser, selected);

  final pickerChip = find.byKey(
    ValueKey<String>('handrail-reaction-$reactionKey'),
  );
  expect(pickerChip, findsOneWidget);
  expect(tester.widget<FilterChip>(pickerChip).selected, selected);
  expect(
    find.descendant(
      of: pickerChip,
      matching: find.text('$reactionKey $count'),
    ),
    findsOneWidget,
  );
  expect(
    find.byKey(
      ValueKey<String>('handrail-reaction-message-sent-$reactionKey'),
    ),
    findsOneWidget,
  );
}

MessageReactionAggregate? _canonicalReaction(
  WidgetTester tester,
  String reactionKey,
) {
  final client = ChatScope.of(
    tester.element(find.byType(HandrailMessageTimeline)),
  ).client;
  final sent = client.normalizedState
      .timeline(const ConversationId('flutter-public-channel'))
      .messages
      .singleWhere(
        (message) => message.id == const MessageId('message-sent'),
      );
  for (final aggregate in sent.reactions) {
    if (aggregate.reactionKey == reactionKey) return aggregate;
  }
  return null;
}

Future<void> _chooseResponse(WidgetTester tester, String label) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('timeline-lab-reminder-response')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _selectPreferenceMenuItem(
  WidgetTester tester, {
  required String buttonKey,
  required String itemKey,
}) async {
  await tester.tap(find.byKey(ValueKey<String>(buttonKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>(itemKey)));
  await tester.pump();
}

Future<void> _expectCheckedPreferenceItem(
  WidgetTester tester, {
  required String buttonKey,
  required String itemKey,
}) async {
  await tester.tap(find.byKey(ValueKey<String>(buttonKey)));
  await tester.pumpAndSettle();
  expect(
    tester
        .widget<CheckedPopupMenuItem<dynamic>>(
          find.byKey(ValueKey<String>(itemKey)),
        )
        .checked,
    isTrue,
  );
  await tester.tap(find.byKey(ValueKey<String>(itemKey)));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 120 && !predicate(); attempt += 1) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    predicate(),
    isTrue,
    reason: _workspaceDiagnostic(tester),
  );
  await tester.pump();
}

String _workspaceDiagnostic(WidgetTester tester) {
  final workspace = find.byType(HandrailChatWorkspace);
  final state = workspace.evaluate().isEmpty
      ? null
      : tester.state<HandrailChatWorkspaceState>(workspace);
  final listState = state?.debugConversationListController?.state;
  return 'Visible text: '
      '${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().toList()}; '
      'list status: ${listState?.status}; '
      'list error: ${listState?.error?.code} ${listState?.error?.message}';
}

Finder _labKey(String key) => find.byKey(ValueKey(key));
HandrailChatClient _replyLabClient(WidgetTester tester) =>
    ChatScope.of(tester.element(find.byType(HandrailChatWorkspace))).client;
Finder _replyLabInput() => find
    .descendant(
      of: find.byType(HandrailMessageComposer).last,
      matching: find.byType(TextField),
    )
    .first;

Future<void> _mountReplyLab(
  WidgetTester tester,
  TimelineLabReplyStyleScenario scenario,
  List<HandrailChatHttpRequest> requests, {
  TimelineLabReplyActor actor = TimelineLabReplyActor.bob,
  ChatRealtimeSessionTransport? realtime,
}) async {
  await tester.pumpWidget(
    HandrailTimelineLabApp(
      key: UniqueKey(),
      replyStyleScenario: scenario,
      replyActor: actor,
      realtimeSession: realtime,
      onTransportRequest: requests.add,
    ),
  );
  await _pumpUntil(
    tester,
    () =>
        find.byType(HandrailChatWorkspace).evaluate().isNotEmpty &&
        _replyLabClient(tester).replyStyles.state.isResolved,
  );
  await _settleReplyLab(tester);
}

Future<void> _unmountReplyLab(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _settleReplyLab(tester);
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
}

Future<void> _replyLabStyle(WidgetTester tester, String style) async {
  await tester.tap(_labKey('handrail-workspace-settings'));
  await _settleReplyLab(tester);
  await tester.tap(_labKey('handrail-reply-style-$style'));
  await _settleReplyLab(tester);
  await tester.tap(find.text('Close settings'));
  await _settleReplyLab(tester);
  expect(
    _replyLabClient(tester).replyStyles.state.effectiveStyle.wireValue,
    style,
  );
}

Future<MessageId> _postLaunchQuestion(WidgetTester tester) async {
  await tester.enterText(_replyLabInput(), 'Which launch date?');
  await _settleReplyLab(tester);
  await tester.tap(_labKey('handrail-message-composer-send'));
  await _settleReplyLab(tester);
  return _replyLabClient(tester).normalizedState
      .timeline(TimelineLabReplyStyleScenario.channelId)
      .messages
      .singleWhere((message) => message.content?.text == 'Which launch date?')
      .id;
}

void _replyStyleScenarioTests() {
  testWidgets(
    'reply scenario: mixed actors inline reply and canonical named creation',
    (tester) async {
      _useWideViewport(tester);
      final scenario = TimelineLabReplyStyleScenario();
      final requests = <HandrailChatHttpRequest>[];
      await _mountReplyLab(
        tester,
        scenario,
        requests,
        actor: TimelineLabReplyActor.alice,
      );
      expect(
        _replyLabClient(tester).replyStyles.state.effectiveStyle,
        ReplyStyle.current,
      );
      final root = await _postLaunchQuestion(tester);
      await _unmountReplyLab(tester);
      await _mountReplyLab(tester, scenario, requests);
      final bob = _replyLabClient(tester);
      expect(bob.replyStyles.state.effectiveStyle, ReplyStyle.discord);
      expect(find.text('Which launch date?'), findsOneWidget);
      requests.clear();
      await tester.tap(_labKey('handrail-reply-${root.value}'));
      await _settleReplyLab(tester);
      await tester.enterText(_replyLabInput(), 'Friday');
      await _settleReplyLab(tester);
      await tester.tap(_labKey('handrail-message-composer-send'));
      await _settleReplyLab(tester);
      final sent = requests
          .where((r) => r.method == 'POST' && r.uri.path.endsWith('/messages'))
          .single;
      final input = SendMessageRequest.fromJson(jsonDecode(sent.body!));
      expect(input.conversationId, TimelineLabReplyStyleScenario.channelId);
      expect(input.replyTo?.messageId, root);
      expect(input.content.text, 'Friday');
      expect(requests.where((r) => r.uri.path.endsWith('/thread')), isEmpty);
      expect(find.byType(HandrailThreadView), findsNothing);
      final reply = bob.normalizedState
          .timeline(input.conversationId)
          .messages
          .singleWhere((message) => message.content?.text == 'Friday');
      expect(
        bob
            .normalizedState
            .state
            .canonicalMessages[reply.id]
            ?.replyTo
            ?.messageId,
        root,
      );
      expect(reply.author.toJson(), {'type': 'user', 'userId': 'bob'});
      expect(find.text('Reply to alice: Which launch date?'), findsOneWidget);
      expect(
        requests.where((r) => r.uri.path.endsWith('/${root.value}/context')),
        isNotEmpty,
      );

      await tester.tap(_labKey('handrail-create-thread-${root.value}'));
      await _settleReplyLab(tester);
      await tester.enterText(
        _labKey('handrail-thread-name'),
        'Launch date discussion',
      );
      await _settleReplyLab(tester);
      await tester.tap(_labKey('handrail-thread-create-submit'));
      await _pumpUntil(
        tester,
        () => find.byType(HandrailThreadView).evaluate().isNotEmpty,
      );
      await _settleReplyLab(tester);
      expect(find.byType(HandrailThreadView), findsOneWidget);
      expect(find.text('Launch date discussion'), findsWidgets);
      final create = requests
          .where((r) => r.uri.path.endsWith('/thread'))
          .single;
      expect(
        ThreadCreationInput.fromJson(jsonDecode(create.body!)).name,
        'Launch date discussion',
      );
      final canonical =
          bob.normalizedState.state.conversations[TimelineLabReplyStyleScenario
                  .launchThreadId]
              as ThreadConversation;
      expect(canonical.rootMessageId, root);
      await tester.tap(_labKey('handrail-thread-close'));
      await _settleReplyLab(tester);
      await tester.tap(_labKey('handrail-create-thread-${root.value}'));
      await _settleReplyLab(tester);
      expect(find.text('Launch date discussion'), findsWidgets);
      expect(
        requests.where((r) => r.uri.path.endsWith('/thread')),
        hasLength(1),
      );
      // Public controller repeats canonical creation independently of presentation.
      final repeated = bob.threads.create(
        rootMessageId: root,
        name: 'Must not rename',
      );
      await _settleReplyLab(tester);
      final result = await repeated;
      expect(result, isA<ChatThreadOpenSuccess>());
      (result as ChatThreadOpenSuccess).handle.release();
      expect(
        (bob.normalizedState.state.conversations[canonical.id]
                as ThreadConversation)
            .name,
        'Launch date discussion',
      );
      await _unmountReplyLab(tester);
      await _mountReplyLab(
        tester,
        scenario,
        requests,
        actor: TimelineLabReplyActor.alice,
      );
      expect(
        _replyLabClient(tester).replyStyles.state.effectiveStyle,
        ReplyStyle.current,
      );
      expect(find.text('Friday'), findsOneWidget);
      final alice = _replyLabClient(tester);
      final priorCreates = requests.where((r) => r.uri.path.endsWith('/thread')).length;
      final repeatedCreation = alice.threads.create(
        rootMessageId: root, name: 'Do not rename the canonical discussion',
      );
      await _settleReplyLab(tester);
      final reopened = await repeatedCreation;
      expect(reopened, isA<ChatThreadOpenSuccess>());
      (reopened as ChatThreadOpenSuccess).handle.release();
      expect(requests.where((r) => r.uri.path.endsWith('/thread')), hasLength(priorCreates + 1));
      expect((alice.normalizedState.state.conversations[canonical.id]
          as ThreadConversation).name, 'Launch date discussion');
      await tester.tap(_labKey('handrail-create-thread-${root.value}'));
      await _settleReplyLab(tester);
      expect(
        find.text('Launch date discussion'),
        findsWidgets,
        reason: _workspaceDiagnostic(tester),
      );
      await _unmountReplyLab(tester);
    },
  );

  testWidgets('reply scenario: Current Reply opens canonical root thread', (
    tester,
  ) async {
    _useWideViewport(tester);
    final scenario = TimelineLabReplyStyleScenario();
    final requests = <HandrailChatHttpRequest>[];
    await _mountReplyLab(
      tester,
      scenario,
      requests,
      actor: TimelineLabReplyActor.alice,
    );
    final root = await _postLaunchQuestion(tester);
    requests.clear();
    await tester.tap(_labKey('handrail-reply-${root.value}'));
    await _settleReplyLab(tester);
    expect(find.byType(HandrailThreadView), findsOneWidget);
    final create = ThreadCreationInput.fromJson(
      jsonDecode(
        requests.singleWhere((r) => r.uri.path.endsWith('/thread')).body!,
      ),
    );
    expect(create.rootMessageId, root);
    expect(create.name, isNull);
    expect(
      _replyLabClient(tester)
          .normalizedState
          .state
          .conversations[TimelineLabReplyStyleScenario.launchThreadId],
      isA<ThreadConversation>(),
    );
    await _unmountReplyLab(tester);
  });

  testWidgets(
    'reply scenario: style switch and recreated clients retain draft reply and queued destination',
    (tester) async {
      _useWideViewport(tester);
      final scenario = TimelineLabReplyStyleScenario();
      final requests = <HandrailChatHttpRequest>[];
      await _mountReplyLab(tester, scenario, requests);
      final first = _replyLabClient(tester);
      final root = TimelineLabReplyStyleScenario.discussionRootId;
      await tester.tap(_labKey('handrail-reply-${root.value}'));
      await _settleReplyLab(tester);
      await tester.enterText(_replyLabInput(), 'Friday queued');
      await _settleReplyLab(tester);
      final composer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer),
      );
      composer.setReplyNotifyAuthor(false);
      await _settleReplyLab(tester);
      await _replyLabStyle(tester, 'current');
      expect(find.text('Friday queued'), findsOneWidget);
      expect(composer.replyTo?.messageId, root);
      expect(composer.replyTo?.notifyAuthor, isFalse);
      final saved = await scenario.storage.read(
        scenario.identity(TimelineLabReplyActor.bob),
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      );
      expect(saved?.encode(), contains('Friday queued'));
      await _unmountReplyLab(tester);

      final network = FakeChatRealtimeNetwork();
      final socket = FakeChatRealtimeSocket();
      final offline = ChatRealtimeSessionTransport(
        endpoint: Uri.parse('https://flutter-timeline-lab.invalid/api/chat'),
        clientPackageVersion: handrailChatPackageVersion,
        protocolVersion: handrailChatProtocolVersion,
        tokenProvider: () => 'fixture-token',
        network: network,
        socketFactory: (_, __) => socket,
      );
      await tester.runAsync(() async {
        await offline.start();
        socket.emitJson({
          'type': 'chat.session.accepted',
          'tenantId': scenario
              .identity(TimelineLabReplyActor.bob)
              .tenantId
              .value,
          'actorStreamId': 'user:bob',
          'deviceId': scenario
              .identity(TimelineLabReplyActor.bob)
              .deviceId
              .value,
          'sessionId': 'reply-lab-session',
          'metadata': {
            'packageVersion': handrailChatPackageVersion,
            'protocolVersion': handrailChatProtocolVersion,
            'schemaVersion': 9,
            'enabledFeatures': {
              replyStylePreferenceFeature: true,
              ChatReplyThreadFeatures.inlineReplies: true,
              ChatReplyThreadFeatures.namedThreads: true,
              ChatReplyThreadFeatures.threadDiscovery: true,
              ChatReplyThreadFeatures.threadLifecycle: true,
            },
            'supportedProtocolRange': {
              'minimumVersion': handrailChatProtocolVersion,
              'maximumVersion': handrailChatProtocolVersion,
            },
          },
        });
        await Future<void>.delayed(Duration.zero);
      });
      await _mountReplyLab(tester, scenario, requests, realtime: offline);
      final second = _replyLabClient(tester);
      expect(identical(first, second), isFalse);
      expect(second.replyStyles.state.effectiveStyle, ReplyStyle.current);
      expect(
        find.text('Friday queued'),
        findsOneWidget,
        reason: _workspaceDiagnostic(tester),
      );
      final restoredComposer = tester.state<HandrailMessageComposerState>(
        find.byType(HandrailMessageComposer),
      );
      expect(restoredComposer.replyTo?.toJson(), composer.replyTo?.toJson());
      network.setOnline(false);
      await _settleReplyLab(tester);
      requests.clear();
      // Queue through the existing client hook using the real restored composer
      // draft. This assertion covers queue storage, not offline button dispatch.
      final queueResult = second.sendMessage(
        ChatSendMessageInput(
          conversationId: TimelineLabReplyStyleScenario.channelId,
          content: MessageContent(
            format: MessageContentFormat.plain,
            text: 'Friday queued',
          ),
          replyTo: restoredComposer.replyTo,
        ),
      );
      await _settleReplyLab(tester);
      expect(await queueResult, isA<ChatCommandQueued<SendMessageResult>>());
      expect(second.queuedSendMessages, hasLength(1));
      final queued = second.queuedSendMessages.single.request.toJson();
      expect(
        second.queuedSendMessages.single.request.conversationId,
        TimelineLabReplyStyleScenario.channelId,
      );
      expect(
        second.queuedSendMessages.single.request.replyTo?.notifyAuthor,
        isFalse,
      );
      expect(
        requests.where(
          (r) => r.method == 'POST' && r.uri.path.endsWith('/messages'),
        ),
        isEmpty,
      );
      // Use the existing composer hook while offline capability gating disables
      // new timeline Reply actions. This writes through the real retained draft runtime.
      expect(
        restoredComposer.selectReply(
          MessageContextRequest(
            conversationId: TimelineLabReplyStyleScenario.channelId,
            messageId: root,
          ),
        ),
        isTrue,
      );
      await tester.enterText(_replyLabInput(), 'Next launch note');
      await _settleReplyLab(tester);
      await _unmountReplyLab(tester);
      await tester.runAsync(() async {
        await offline.dispose();
        await network.dispose();
      });
      await _mountReplyLab(tester, scenario, requests);
      final third = _replyLabClient(tester);
      expect(identical(second, third), isFalse);
      expect(third.queuedSendMessages.single.request.toJson(), queued);
      expect(find.text('Next launch note'), findsOneWidget);
      expect(
        tester
            .state<HandrailMessageComposerState>(
              find.byType(HandrailMessageComposer),
            )
            .replyTo
            ?.messageId,
        root,
      );
      await _replyLabStyle(tester, 'discord');
      expect(find.text('Next launch note'), findsOneWidget);
      await tester.tap(_labKey('handrail-create-thread-${root.value}'));
      await _settleReplyLab(tester);
      expect(find.text('Launch planning'), findsWidgets);
      expect(third.queuedSendMessages.single.request.toJson(), queued);
      await _unmountReplyLab(tester);
      await _mountReplyLab(tester, scenario, requests,
          actor: TimelineLabReplyActor.alice);
      expect(_replyLabClient(tester).replyStyles.state.effectiveStyle,
          ReplyStyle.current);
      expect(_replyLabClient(tester).queuedSendMessages, isEmpty);
      await _unmountReplyLab(tester);
    },
  );

  testWidgets(
    'reply scenario: narrow discovery close reopen and Leave retain history and draft destination',
    (tester) async {
      tester.view.physicalSize = const Size(480, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scenario = TimelineLabReplyStyleScenario();
      final requests = <HandrailChatHttpRequest>[];
      await _mountReplyLab(tester, scenario, requests);
      await tester.tap(_labKey('handrail-workspace-threads'));
      await _pumpUntil(
        tester,
        () => _labKey(
          'handrail-thread-list-${TimelineLabReplyStyleScenario.discussionId.value}',
        ).evaluate().isNotEmpty,
      );
      await _settleReplyLab(tester);
      await tester.tap(
        _labKey(
          'handrail-thread-list-${TimelineLabReplyStyleScenario.discussionId.value}',
        ),
      );
      await _settleReplyLab(tester);
      expect(find.text('The launch checklist stays here.'), findsOneWidget);
      await tester.tap(find.byTooltip('Thread subscriptions'));
      await _settleReplyLab(tester);
      await tester.tap(find.text('Join'));
      await _settleReplyLab(tester);
      await tester.enterText(_replyLabInput(), 'Retained thread draft');
      await _settleReplyLab(tester);
      final composer = tester.state(find.byType(HandrailMessageComposer).last);
      for (final action in ['Close shared thread', 'Reopen thread']) {
        await tester.tap(find.byTooltip('Shared thread controls'));
        await _settleReplyLab(tester);
        await tester.tap(find.text(action));
        await _settleReplyLab(tester);
        expect(
          tester.state(find.byType(HandrailMessageComposer).last),
          same(composer),
        );
        expect(find.text('Retained thread draft'), findsOneWidget);
      }
      requests.clear();
      await tester.tap(find.byTooltip('Thread subscriptions'));
      await _settleReplyLab(tester);
      await tester.tap(find.text('Leave'));
      await _settleReplyLab(tester);
      final follow = SetThreadFollowInput.fromJson(
        jsonDecode(
          requests.singleWhere((r) => r.uri.path.endsWith('/follow')).body!,
        ),
      );
      expect(follow.intent, ThreadFollowMutationIntent.unfollow);
      expect(follow.target.id, TimelineLabReplyStyleScenario.discussionId);
      expect(find.text('The launch checklist stays here.'), findsOneWidget);
      expect(find.text('Retained thread draft'), findsOneWidget);
      expect(
        tester.state(find.byType(HandrailMessageComposer).last),
        same(composer),
      );
      await tester.tap(_labKey('handrail-message-composer-send').last);
      await _settleReplyLab(tester);
      final send = SendMessageRequest.fromJson(
        jsonDecode(
          requests
              .singleWhere(
                (r) => r.method == 'POST' && r.uri.path.endsWith('/messages'),
              )
              .body!,
        ),
      );
      expect(send.conversationId, TimelineLabReplyStyleScenario.discussionId);
      expect(tester.takeException(), isNull);
      await _unmountReplyLab(tester);
    },
  );
}

Future<void> _settleReplyLab(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
