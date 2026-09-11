import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/flutter.dart';
import 'package:handrail_chat/testing.dart'
    show FakeChatRealtimeNetwork, InMemoryApplicationChatStorage;
import 'package:handrail_chat/src/chat_application_delegates.dart';
import 'package:handrail_chat/src/handrail_chat_theme.dart';
import 'package:handrail_chat/src/handrail_member_picker.dart';
import 'package:handrail_chat/src/handrail_message_composer.dart';

import 'fixtures/conversation_membership_fixtures.dart';
import 'fixtures/draft_mutation_fixtures.dart';

final _storageIdentity = ApplicationChatStorageIdentity(
    tenantId: TenantId(_tenantId),
    userId: UserId(_userId),
    deviceId: DeviceId('device-composer'));

const _conversationId = ConversationId('conversation-composer');
const _tenantId = 'tenant-composer';
const _userId = 'user-composer';
const _now = '2026-08-26T22:00:00.000Z';
const _input = ValueKey('handrail-message-composer-input');
const _send = ValueKey('handrail-message-composer-send');
const _attach = ValueKey('handrail-message-composer-attach');
const _mentionPopup = ValueKey('handrail-message-composer-mention-suggestions');
const _graceId = UserId('user-grace');
const _ginaId = UserId('user-gina');
const _disabledId = UserId('user-disabled');
const _removedId = UserId('user-removed');
const _outsiderId = UserId('user-outsider');
const _grace = HandrailMemberDirectoryRow(
  userId: _graceId,
  displayName: 'Grace',
  subtitle: 'Engineering',
);
const _gina = HandrailMemberDirectoryRow(
  userId: _ginaId,
  displayName: 'Gina',
);
const _disabled = HandrailMemberDirectoryRow(
  userId: _disabledId,
  displayName: 'Disabled Dana',
  disabled: true,
);
const _removed = HandrailMemberDirectoryRow(
  userId: _removedId,
  displayName: 'Removed Riley',
);
const _outsider = HandrailMemberDirectoryRow(
  userId: _outsiderId,
  displayName: 'Outside Olivia',
);

void main() {
  for (final retryCount in [0, 1]) {
    testWidgets(
        'offline Send persists one reply intent before reconnect (retries=$retryCount)',
        (tester) async {
      final storage = InMemoryApplicationChatStorage();
      final harness = _Harness(
          realtime: true, storage: storage, sendFailuresRemaining: retryCount);
      addTearDown(() => _disposeHarness(tester, harness));
      await _connectStoredComposer(tester, harness);
      harness.client.replyStyles.configure(
          const ChatReplyStyleConfiguration(override: ReplyStyle.discord));
      _authorizeSource(harness);
      final key = GlobalKey<HandrailMessageComposerState>();
      await _pumpComposer(tester, harness,
          composerKey: key,
          delegates: ChatApplicationDelegates(
              pickAttachment: () async => ChatAttachmentPickerSelection(
                  [AttachmentId('attachment-schedule')])));
      key.currentState!.selectReply(MessageContextRequest(
          conversationId: _conversationId, messageId: _sourceId));
      await tester.pump();
      await tester.tap(find.text('Notify reply author'));
      await tester.tap(find.byKey(_attach));
      await tester.enterText(find.byKey(_input), 'Friday');
      harness.network.setOnline(false);
      await tester.pump();
      await tester.tap(find.byKey(_send));
      await _pumpUntil(tester, () => _text(tester).isEmpty);
      expect(harness.transport.operations('send'), isEmpty);
      final queued = harness.client.queuedSendMessages.single;
      expect(queued.identity.userId, UserId(_userId));
      expect(queued.conversationId, _conversationId);
      expect(queued.request.replyTo!.toJson(),
          {'messageId': _sourceId.value, 'notifyAuthor': false});
      expect(queued.content.text, 'Friday');
      expect(queued.content.attachments!.single.attachmentId,
          AttachmentId('attachment-schedule'));
      expect(
          await storage.read(queued.identity,
              ApplicationChatStorageRecordKind.queuedSendMessageIntents),
          isNotNull);
      expect(harness.client.draftFor(_conversationId)!.draft,
          isA<CanonicalClearDraftTombstone>());
      final storedDraft = await storage.read(queued.identity,
              ApplicationChatStorageRecordKind.queuedDraftIntents)
          as ApplicationChatQueuedDraftIntentsRecord;
      expect(storedDraft.intents.single.request.toJson()['intent'], 'clear');
      harness.client.replyStyles.configure(
          const ChatReplyStyleConfiguration(override: ReplyStyle.current));
      await _pumpComposer(tester, harness,
          composerKey: key, showFormatSelector: false);
      expect(_text(tester), isEmpty);
      final sentFrames = harness.socket!.sent.length;
      harness.network.setOnline(true);
      await _pumpUntil(tester, () => harness.socket!.sent.length > sentFrames);
      harness.socket!.emit(_acceptedFrame());
      await _pumpUntil(
          tester,
          () =>
              harness.client.queuedSendMessages.isEmpty &&
              harness.client.draftFor(_conversationId)?.isPending == false);
      final sends = harness.transport.operations('send');
      expect(sends, hasLength(1 + retryCount));
      for (final send in sends) {
        expect(send, queued.request.toJson());
      }
      final canonical = harness
          .client.normalizedState.state.canonicalMessages.values
          .where((m) => m.id.value.startsWith('sent-'))
          .single;
      expect(canonical.toJson()['author'], {'type': 'user', 'userId': _userId});
      expect(_text(tester), isEmpty);
      expect(key.currentState!.replyTo, isNull);
      await tester.pumpWidget(const SizedBox());
      await _pumpComposer(tester, harness);
      expect(_text(tester), isEmpty);
    });
  }

  for (final failure in [
    ApplicationChatStorageRecordKind.queuedDraftIntents,
    ApplicationChatStorageRecordKind.queuedSendMessageIntents
  ]) {
    testWidgets(
        'offline Send retains editable reply on storage failure $failure',
        (tester) async {
      final storage = _ControlledStorage();
      final harness = _Harness(realtime: true, storage: storage);
      addTearDown(() => _disposeHarness(tester, harness));
      await _connectStoredComposer(tester, harness);
      _authorizeSource(harness);
      final key = GlobalKey<HandrailMessageComposerState>();
      await _pumpComposer(tester, harness,
          composerKey: key,
          delegates: ChatApplicationDelegates(
              pickAttachment: () async => ChatAttachmentPickerSelection(
                  [AttachmentId('attachment-schedule')])));
      key.currentState!.selectReply(MessageContextRequest(
          conversationId: _conversationId, messageId: _sourceId));
      key.currentState!.setReplyNotifyAuthor(false);
      await tester.tap(find.byKey(_attach));
      await tester.enterText(find.byKey(_input), 'Keep this reply');
      storage.failKind = failure;
      harness.network.setOnline(false);
      await tester.pump();
      await tester.tap(find.byKey(_send));
      await _pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(_text(tester), 'Keep this reply');
      expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
      expect(find.text('attachment-schedule'), findsOneWidget);
      expect(harness.client.queuedSendMessages, isEmpty);
      expect(harness.transport.operations('send'), isEmpty);
      storage.failKind = null;
      await tester.tap(find.text('Retry'));
      await _pumpUntil(tester, () => _text(tester).isEmpty);
      final queued = harness.client.queuedSendMessages.single;
      expect(queued.content.text, 'Keep this reply');
      expect(queued.request.replyTo!.notifyAuthor, isFalse);
      expect(queued.content.attachments!.single.attachmentId,
          AttachmentId('attachment-schedule'));
    });
  }

  testWidgets(
      'local persistence pending keeps content and freezes binding across style changes',
      (tester) async {
    final storage = _ControlledStorage();
    final harness = _Harness(realtime: true, storage: storage);
    addTearDown(() => _disposeHarness(tester, harness));
    await _connectStoredComposer(tester, harness);
    _authorizeSource(harness);
    final key = GlobalKey<HandrailMessageComposerState>();
    await _pumpComposer(tester, harness, composerKey: key);
    key.currentState!.selectReply(MessageContextRequest(
        conversationId: _conversationId, messageId: _sourceId));
    key.currentState!.setReplyNotifyAuthor(false);
    await tester.enterText(find.byKey(_input), 'Original');
    final gate = Completer<void>();
    storage.pendingWrite = gate;
    harness.network.setOnline(false);
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(tester, () => storage.waiting);
    expect(_text(tester), 'Original');
    expect(harness.client.queuedSendMessages, isEmpty);
    harness.client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    await _pumpComposer(tester, harness,
        composerKey: key,
        showFormatSelector: false,
        theme: ThemeData.dark(),
        waitUntilReady: false);
    expect(_text(tester), 'Original');
    const other = ConversationId('another-conversation');
    await _pumpComposer(tester, harness,
        composerKey: key, conversationId: other, draftDebounce: Duration.zero);
    await tester.enterText(find.byKey(_input), 'New destination draft');
    gate.complete();
    await _pumpUntil(
        tester,
        () =>
            harness.client.queuedSendMessages.length == 1 &&
            harness.client.draftFor(_conversationId)?.draft
                is CanonicalClearDraftTombstone);
    expect(_text(tester), 'New destination draft');
    final queued = harness.client.queuedSendMessages.single;
    expect(queued.conversationId, _conversationId);
    expect(queued.content.text, 'Original');
    expect(queued.request.replyTo!.notifyAuthor, isFalse);
    await _pumpComposer(tester, harness, composerKey: key);
    expect(_text(tester), isEmpty);
  });

  testWidgets('deferred online draft cleanup preserves the next composition',
      (tester) async {
    final harness = _Harness(storage: InMemoryApplicationChatStorage());
    addTearDown(() => _disposeHarness(tester, harness));
    final pending = Completer<void>();
    harness.transport.pendingDraft = pending;
    await _pumpComposer(tester, harness, draftDebounce: Duration.zero);
    await tester.enterText(find.byKey(_input), 'First');
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(tester, () => _text(tester).isEmpty);
    expect(harness.transport.operations('send'), hasLength(1));
    expect(harness.client.draftFor(_conversationId)!.draft,
        isA<CanonicalClearDraftTombstone>());
    await tester.enterText(find.byKey(_input), 'Second');
    await tester.pump();
    pending.complete();
    await _pumpUntil(tester,
        () => harness.client.draftFor(_conversationId)?.isPending == false);
    expect(_text(tester), 'Second');
    expect(
        (harness.client.draftFor(_conversationId)!.draft
                as CanonicalReplacedDraft)
            .content
            .text,
        'Second');
    expect(harness.transport.operations('send'), hasLength(1));
  });

  for (final dispose in [false, true]) {
    testWidgets(
        'pending local persistence guards ${dispose ? 'disposal' : 'identity change'}',
        (tester) async {
      final storage = _ControlledStorage();
      final harness = _Harness(storage: storage);
      addTearDown(() => _disposeHarness(tester, harness));
      await _pumpComposer(tester, harness);
      await tester.enterText(find.byKey(_input), 'Original actor');
      final gate = Completer<void>();
      storage.pendingWrite = gate;
      await tester.pump();
      await tester.tap(find.byKey(_send));
      await _pumpUntil(tester, () => storage.waiting);
      Future<void>? changed;
      if (dispose) {
        await tester.pumpWidget(const SizedBox());
      } else {
        changed = harness.client.activateStorageIdentity(
            ApplicationChatStorageIdentity(
                tenantId: _storageIdentity.tenantId,
                userId: UserId('another-user'),
                deviceId: _storageIdentity.deviceId));
        await tester.pump();
      }
      gate.complete();
      var settled = changed == null;
      changed?.then((_) => settled = true);
      await _pumpUntil(tester, () => settled);
      await tester.pumpAndSettle();
      expect(harness.transport.operations('send'), isEmpty);
      expect(harness.client.queuedSendMessages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no-storage Send retains the legacy remote draft boundary',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final pending = Completer<void>();
    harness.transport.pendingDraft = pending;
    await _pumpComposer(tester, harness);
    await tester.enterText(find.byKey(_input), 'Online only');
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(tester,
        () => harness.transport.operations('synchronize_draft').isNotEmpty);
    expect(_text(tester), 'Online only');
    expect(harness.transport.operations('send'), isEmpty);
    expect(harness.client.queuedSendMessages, isEmpty);
    pending.complete();
    await _pumpUntil(tester, () => _text(tester).isEmpty);
    expect(harness.transport.operations('send'), hasLength(1));
    expect(harness.client.queuedSendMessages, isEmpty);
  });

  testWidgets('reply target-only and ping-only drafts restore false ping',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final source = _authorizeSource(harness);
    final key = GlobalKey<HandrailMessageComposerState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpComposer(tester, harness,
        composerKey: key, focusNode: focus, draftDebounce: Duration.zero);
    expect(
        key.currentState!.selectReply(MessageContextRequest(
            conversationId: ConversationId('elsewhere'), messageId: _sourceId)),
        isFalse);
    expect(
        key.currentState!.selectReply(MessageContextRequest(
            conversationId: _conversationId, messageId: _sourceId)),
        isTrue);
    await _pumpUntil(tester,
        () => harness.transport.operations('synchronize_draft').isNotEmpty);
    expect(focus.hasFocus, isTrue);
    var draft = harness.transport.operations('synchronize_draft').last;
    expect(draft['intent'], 'replace');
    expect((draft['content'] as Map)['replyTo'],
        {'messageId': _sourceId.value, 'notifyAuthor': true});
    await tester.tap(find.text('Notify reply author'));
    await _pumpUntil(tester,
        () => harness.transport.operations('synchronize_draft').length >= 2);
    draft = harness.transport.operations('synchronize_draft').last;
    expect((draft['content'] as Map)['replyTo'],
        {'messageId': _sourceId.value, 'notifyAuthor': false});
    expect(focus.hasFocus, isTrue);
    await _pumpUntil(tester,
        () => source.state.status == ChatMessageContextStatus.available);
    await tester.pumpWidget(const SizedBox());
    // The shared source remains usable after this consumer detaches.
    expect(source.state.status, ChatMessageContextStatus.available);
    await _pumpComposer(tester, harness, composerKey: key, focusNode: focus);
    expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
    expect(_text(tester), isEmpty);
    await _pumpUntil(
        tester,
        () =>
            find.text('Replying to: Which launch date?').evaluate().isNotEmpty);
    expect(tester.widget<IconButton>(find.byKey(_send)).onPressed, isNull);
  });

  testWidgets(
      'cancel reply retains restored text and attachments across style rebuilds',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    _authorizeSource(harness);
    harness.client.reconcileDraftEvent(_draftEvent('Friday',
        attachments: ['attachment-schedule'],
        replyTo:
            MessageReplyReference(messageId: _sourceId, notifyAuthor: false)));
    final key = GlobalKey<HandrailMessageComposerState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpComposer(tester, harness, composerKey: key, focusNode: focus);
    await _pumpComposer(tester, harness,
        composerKey: key,
        focusNode: focus,
        showFormatSelector: false,
        theme: ThemeData.dark(),
        draftDebounce: Duration.zero);
    expect(_text(tester), 'Friday');
    expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Notify reply author'), findsOneWidget);
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel reply'));
    await _pumpUntil(tester,
        () => harness.transport.operations('synchronize_draft').isNotEmpty);
    expect(focus.hasFocus, isTrue);
    expect(_text(tester), 'Friday');
    final content = harness.transport
        .operations('synchronize_draft')
        .last['content'] as Map;
    expect(content['attachments'], [
      {'attachmentId': 'attachment-schedule'}
    ]);
    expect(content.containsKey('replyTo'), isFalse);
    expect(key.currentState!.replyTo, isNull);
    semantics.dispose();
  });

  testWidgets(
      'same-thread failed send and retry freeze destination and reference',
      (tester) async {
    const thread = ConversationId('existing-thread');
    final harness = _Harness(sendFailuresRemaining: 1);
    harness.transport.threads.add(thread.value);
    addTearDown(() => _disposeHarness(tester, harness));
    _authorizeSource(harness, conversationId: thread);
    final key = GlobalKey<HandrailMessageComposerState>();
    await _pumpComposer(tester, harness,
        composerKey: key, conversationId: thread);
    key.currentState!.selectReply(
        MessageContextRequest(conversationId: thread, messageId: _sourceId));
    key.currentState!.setReplyNotifyAuthor(false);
    await tester.enterText(find.byKey(_input), 'Friday');
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);
    expect(_text(tester), 'Friday');
    await _pumpComposer(tester, harness,
        composerKey: key, conversationId: thread, showFormatSelector: false);
    expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
    await tester.tap(find.text('Retry'));
    await _pumpUntil(tester, () => _text(tester).isEmpty);
    final sends = harness.transport.operations('send');
    expect(sends, hasLength(2));
    for (final send in sends) {
      expect(send['conversationId'], thread.value);
      expect(send['replyTo'],
          {'messageId': _sourceId.value, 'notifyAuthor': false});
      expect(send['content'],
          {'format': 'plain', 'text': 'Friday', 'attachments': []});
    }
    expect(
        harness.transport.requests
            .where((r) => r.method != 'GET' && r.uri.path.contains('/threads')),
        isEmpty);
    expect(harness.client.draftFor(thread)!.draft,
        isA<CanonicalClearDraftTombstone>());
  });

  for (final succeeds in [true, false]) {
    testWidgets('pending send rebind preserves new draft (success=$succeeds)',
        (tester) async {
      final harness = _Harness(sendFailuresRemaining: succeeds ? 0 : 1);
      addTearDown(() => _disposeHarness(tester, harness));
      _authorizeSource(harness);
      final pending = Completer<void>();
      harness.transport.pendingSend = pending;
      final key = GlobalKey<HandrailMessageComposerState>();
      await _pumpComposer(tester, harness, composerKey: key);
      key.currentState!.selectReply(MessageContextRequest(
          conversationId: _conversationId, messageId: _sourceId));
      key.currentState!.setReplyNotifyAuthor(false);
      await tester.enterText(find.byKey(_input), 'Original');
      await tester.pump();
      await tester.tap(find.byKey(_send));
      await _pumpUntil(
          tester, () => harness.transport.operations('send').isNotEmpty);
      const other = ConversationId('other-conversation');
      await _pumpComposer(tester, harness,
          composerKey: key,
          conversationId: other,
          draftDebounce: Duration.zero);
      expect(_text(tester), isEmpty);
      expect(key.currentState!.replyTo, isNull);
      await tester.enterText(find.byKey(_input), 'New draft');
      await _pumpUntil(tester, () => harness.client.draftFor(other) != null);
      pending.complete();
      await tester.pumpAndSettle();
      expect(_text(tester), 'New draft');
      expect(find.text('Retry'), findsNothing);
      expect(
          (harness.client.draftFor(other)!.draft as CanonicalReplacedDraft)
              .content
              .text,
          'New draft');
      if (succeeds) {
        expect(harness.client.draftFor(_conversationId)!.draft,
            isA<CanonicalClearDraftTombstone>());
      } else {
        await _pumpComposer(tester, harness, composerKey: key);
        expect(_text(tester), 'Original');
        expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
        await tester.pump();
        await tester.tap(find.byKey(_send));
        await _pumpUntil(tester, () => _text(tester).isEmpty);
      }
      expect(
          harness.transport
              .operations('send')
              .every((s) => s['conversationId'] == _conversationId.value),
          isTrue);
    });
  }

  testWidgets(
      'source errors deletion revocation and identity changes redact preview with recovery',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final source = _authorizeSource(harness);
    final key = GlobalKey<HandrailMessageComposerState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpComposer(tester, harness, composerKey: key, focusNode: focus);
    key.currentState!.selectReply(MessageContextRequest(
        conversationId: _conversationId, messageId: _sourceId));
    await _pumpUntil(
        tester,
        () =>
            find.text('Replying to: Which launch date?').evaluate().isNotEmpty);
    harness.transport.contextHttpStatus = 503;
    key.currentState!.retryReplyContext();
    await _pumpUntil(
        tester,
        () => find
            .text('Reply source could not be loaded.')
            .evaluate()
            .isNotEmpty);
    expect(find.textContaining('Which launch date?'), findsNothing);
    expect(key.currentState!.replyTo, isNotNull);
    harness.transport.contextHttpStatus = 200;
    await tester.tap(find.text('Retry reply source'));
    await _pumpUntil(tester,
        () => source.state.status == ChatMessageContextStatus.available);
    expect(focus.hasFocus, isTrue);
    source.setAuthority(null);
    await tester.pump();
    expect(find.textContaining('Which launch date?'), findsNothing);
    expect(find.text('Reply source is unavailable.'), findsOneWidget);
    _authorizeSource(harness);
    harness.transport.contextStatus = 'unavailable';
    await tester.tap(find.text('Retry reply source'));
    await _pumpUntil(tester,
        () => source.state.status == ChatMessageContextStatus.unavailable);
    harness.transport.contextStatus = 'deleted';
    await tester.pump();
    await tester.tap(find.text('Retry reply source'));
    await _pumpUntil(tester,
        () => find.text('Reply source was deleted.').evaluate().isNotEmpty);
    expect(key.currentState!.replyTo, isNotNull);
    source.setAuthority(const ChatMessageContextAuthority(
        tenantId: TenantId('other-tenant'), userId: UserId('other-user')));
    await tester.pump();
    expect(find.text('Reply source is unavailable.'), findsOneWidget);
    expect(find.textContaining('Which launch date?'), findsNothing);
  });

  testWidgets(
      'typed reply builder exposes live context and keyboard cancellation',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    _authorizeSource(harness);
    final key = GlobalKey<HandrailMessageComposerState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    HandrailMessageComposerReplyControls? controls;
    await _pumpComposer(tester, harness, composerKey: key, focusNode: focus,
        replyBuilder: (context, value) {
      controls = value;
      return TextButton(
          onPressed: value.cancel, child: const Text('Custom cancel reply'));
    });
    key.currentState!.selectReply(MessageContextRequest(
        conversationId: _conversationId, messageId: _sourceId));
    await _pumpUntil(tester,
        () => controls?.context.status == ChatMessageContextStatus.available);
    expect(controls!.reference.notifyAuthor, isTrue);
    await tester.enterText(find.byKey(_input), 'Keep this');
    final button = tester.element(find.text('Custom cancel reply'));
    Focus.of(button).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(key.currentState!.replyTo, isNull);
    expect(focus.hasFocus, isTrue);
    expect(_text(tester), 'Keep this');
  });

  for (final succeeds in [true, false]) {
    testWidgets(
        'new host edits survive an original send completion (success=$succeeds)',
        (tester) async {
      final harness = _Harness(sendFailuresRemaining: succeeds ? 0 : 1);
      addTearDown(() => _disposeHarness(tester, harness));
      final host = TextEditingController();
      addTearDown(host.dispose);
      final pending = Completer<void>();
      harness.transport.pendingSend = pending;
      await _pumpComposer(tester, harness,
          controller: host, draftDebounce: Duration.zero);
      await tester.enterText(find.byKey(_input), 'Original');
      await tester.pump();
      await tester.tap(find.byKey(_send));
      await _pumpUntil(
          tester, () => harness.transport.operations('send').isNotEmpty);
      host.text = 'Newer composition';
      await _pumpUntil(
          tester,
          () =>
              (harness.client.draftFor(_conversationId)?.draft
                      as CanonicalReplacedDraft?)
                  ?.content
                  .text ==
              'Newer composition');
      pending.complete();
      await _pumpUntil(tester,
          () => tester.widget<IconButton>(find.byKey(_send)).onPressed != null);
      expect(_text(tester), 'Newer composition');
      expect(
          harness.transport
              .operations('synchronize_draft')
              .where((d) => d['intent'] == 'clear'),
          isEmpty);
      expect(find.text('Retry'), findsNothing);
    });
  }

  testWidgets(
      'unavailable source send rejection retains reference and attachments for retry',
      (tester) async {
    final harness = _Harness(sendFailuresRemaining: 1);
    harness.transport.sendFailureStatus = 400;
    harness.transport.contextStatus = 'unavailable';
    addTearDown(() => _disposeHarness(tester, harness));
    _authorizeSource(harness);
    harness.client.reconcileDraftEvent(_draftEvent('Friday',
        attachments: ['attachment-schedule'],
        replyTo:
            MessageReplyReference(messageId: _sourceId, notifyAuthor: false)));
    final key = GlobalKey<HandrailMessageComposerState>();
    await _pumpComposer(tester, harness, composerKey: key);
    await _pumpUntil(tester,
        () => find.text('Reply source is unavailable.').evaluate().isNotEmpty);
    await tester.tap(find.byKey(_send));
    await _pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);
    expect(_text(tester), 'Friday');
    expect(key.currentState!.replyTo!.notifyAuthor, isFalse);
    expect(
        harness.transport
            .operations('synchronize_draft')
            .where((d) => d['intent'] == 'clear'),
        isEmpty);
    harness.transport.contextStatus = 'available';
    await tester.tap(find.text('Retry reply source'));
    await _pumpUntil(
        tester,
        () =>
            find.text('Replying to: Which launch date?').evaluate().isNotEmpty);
    await tester.tap(find.text('Retry'));
    await _pumpUntil(tester, () => _text(tester).isEmpty);
    final sends = harness.transport.operations('send');
    expect(sends, hasLength(2));
    expect(sends[0]['replyTo'], sends[1]['replyTo']);
    expect(sends[0]['content'], sends[1]['content']);
  });

  testWidgets('late source lookup cannot restore a revoked preview',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final source = _authorizeSource(harness);
    final pending = Completer<HandrailChatHttpResponse>();
    harness.transport.pendingContext = pending;
    final key = GlobalKey<HandrailMessageComposerState>();
    await _pumpComposer(tester, harness, composerKey: key);
    key.currentState!.selectReply(MessageContextRequest(
        conversationId: _conversationId, messageId: _sourceId));
    await _pumpUntil(
        tester,
        () => harness.transport.requests
            .any((r) => r.uri.path.endsWith('/context')));
    source.setAuthority(null);
    pending.complete(
        _response(200, _sourceContext(_conversationId.value, 'available')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.textContaining('Which launch date?'), findsNothing);
    expect(find.text('Reply source is unavailable.'), findsOneWidget);
    expect(key.currentState!.replyTo, isNotNull);
  });

  testWidgets('successful send retains a newer remote composition draft',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final pending = Completer<void>();
    harness.transport.pendingSend = pending;
    await _pumpComposer(tester, harness);
    await tester.enterText(find.byKey(_input), 'Original');
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
        tester, () => harness.transport.operations('send').isNotEmpty);
    expect(
        harness.client.reconcileDraftEvent(_draftEvent('New remote draft',
            baseRevision: 100,
            replyTo: MessageReplyReference(
                messageId: _sourceId, notifyAuthor: false))),
        isTrue);
    pending.complete();
    await _pumpUntil(tester,
        () => tester.widget<IconButton>(find.byKey(_send)).onPressed != null);
    expect(_text(tester), 'New remote draft');
    final draft = harness.client.draftFor(_conversationId)!.draft
        as CanonicalReplacedDraft;
    expect(draft.content.text, 'New remote draft');
    expect(draft.content.replyTo!.notifyAuthor, isFalse);
    expect(
        harness.transport
            .operations('synchronize_draft')
            .where((d) => d['intent'] == 'clear'),
        isEmpty);
  });

  testWidgets('restores markdown draft, debounces changes, and clears on send',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    expect(
      harness.client.reconcileDraftEvent(_draftEvent('saved **draft**')),
      isTrue,
    );
    harness.transport.requests.clear();

    await _pumpComposer(
      tester,
      harness,
      draftDebounce: const Duration(milliseconds: 300),
    );
    expect(_text(tester), 'saved draft');
    expect(find.byType(DropdownButton<MessageContentFormat>), findsNothing);
    expect(
        find.byKey(const ValueKey('handrail-message-composer-format-toolbar')),
        findsOneWidget);
    expect(_editingSpan(tester).toPlainText(), 'saved draft');
    expect(_styleForText(tester, 'draft').fontWeight, FontWeight.bold);

    await tester.enterText(find.byKey(_input), 'updated draft');
    await tester.pump(const Duration(milliseconds: 299));
    expect(harness.transport.operations('synchronize_draft'), isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').length == 1,
    );
    final replace = harness.transport.operations('synchronize_draft').single;
    expect(replace['intent'], 'replace');
    expect(
      replace['content'],
      containsPair('text', 'updated **draft**'),
    );
    expect(
      replace['content'],
      containsPair('format', 'markdown'),
    );

    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').length == 1 &&
          harness.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    expect(_text(tester), isEmpty);
    expect(
      harness.transport.operations('send').single['content'],
      containsPair('format', 'markdown'),
    );
  });

  testWidgets(
      'formats delimiter-free text and serializes the supported Markdown subset',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(
      tester,
      harness,
      draftDebounce: Duration.zero,
    );
    harness.transport.requests.clear();

    const visible = 'bold italic link\nbullet\nnumbered\ninline\nblock';
    await tester.enterText(find.byKey(_input), visible);

    await _selectText(tester, 'bold');
    await _tapFormat(tester, 'bold');
    expect(_styleForText(tester, 'bold').fontWeight, FontWeight.bold);

    await _selectText(tester, 'italic');
    await _tapFormat(tester, 'italic');
    expect(_styleForText(tester, 'italic').fontStyle, FontStyle.italic);

    await _selectText(tester, 'link');
    await _tapFormat(tester, 'link');
    await tester.enterText(
      find.byKey(
        const ValueKey('handrail-message-composer-link-destination'),
      ),
      'javascript:alert(1)',
    );
    await tester.tap(
      find.byKey(const ValueKey('handrail-message-composer-link-apply')),
    );
    await tester.pump();
    expect(
      find.text('Enter a safe web, email, or relative link.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(
        const ValueKey('handrail-message-composer-link-destination'),
      ),
      'https://example.com',
    );
    await tester.tap(
      find.byKey(const ValueKey('handrail-message-composer-link-apply')),
    );
    await tester.pumpAndSettle();
    expect(_styleForText(tester, 'link').decoration, TextDecoration.underline);

    await _selectText(tester, 'bullet');
    await _tapFormat(tester, 'unordered-list');
    final colors = Theme.of(tester.element(find.byKey(_input))).colorScheme;
    expect(_styleForText(tester, 'bullet').backgroundColor,
        colors.secondaryContainer.withAlpha(115));

    await _selectText(tester, 'numbered');
    await _tapFormat(tester, 'ordered-list');
    expect(_styleForText(tester, 'numbered').backgroundColor,
        colors.secondaryContainer.withAlpha(115));

    await _selectText(tester, 'inline');
    await _tapFormat(tester, 'inline-code');
    expect(_styleForText(tester, 'inline').fontFamily, 'monospace');
    expect(_styleForText(tester, 'inline').backgroundColor,
        colors.surfaceContainerHighest);

    await _selectText(tester, 'block');
    await _tapFormat(tester, 'code-block');
    expect(_styleForText(tester, 'block').fontFamily, 'monospace');

    final edited = _text(tester).replaceFirst('bold', 'bolXd');
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: edited,
      selection: const TextSelection.collapsed(offset: 4),
    ));
    await tester.pump();
    expect(_styleForText(tester, 'bolXd').fontWeight, FontWeight.bold);
    expect(_text(tester), 'bolXd italic link\nbullet\nnumbered\ninline\nblock');
    expect(_editingSpan(tester).toPlainText(), _text(tester));

    const canonical = '**bolXd** *italic* [link](https://example.com)\n\n'
        '- bullet\n\n'
        '1. numbered\n\n'
        '`inline`\n\n'
        '```\nblock\n```';
    await _pumpUntil(
      tester,
      () {
        final drafts = harness.transport.operations('synchronize_draft');
        if (drafts.isEmpty) return false;
        final content = drafts.last['content'] as Map<String, Object?>?;
        return content?['text'] == canonical;
      },
    );
    final draft = harness.transport.operations('synchronize_draft').last;
    expect(draft['content'], containsPair('text', canonical));
    expect(draft['content'], containsPair('format', 'markdown'));

    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').isNotEmpty &&
          harness.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    final sent = harness.transport.operations('send').single['content'];
    expect(sent, containsPair('text', canonical));
    expect(sent, containsPair('format', 'markdown'));
  });

  testWidgets('plain unformatted entry keeps the plain payload contract',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(tester, harness);

    await tester.enterText(find.byKey(_input), 'plain text');
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').isNotEmpty,
    );
    final draft = harness.transport.operations('synchronize_draft').last;
    expect(draft['content'], containsPair('text', 'plain text'));
    expect(draft['content'], containsPair('format', 'plain'));

    expect(tester.widget<IconButton>(find.byKey(_send)).onPressed, isNotNull);
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () => harness.transport.operations('send').isNotEmpty,
    );
    await _pumpUntil(
      tester,
      () => harness.transport
          .operations('synchronize_draft')
          .any((body) => body['intent'] == 'clear'),
    );
    final sent = harness.transport.operations('send').single['content'];
    expect(sent, containsPair('text', 'plain text'));
    expect(sent, containsPair('format', 'plain'));
  });

  testWidgets('toolbar stays bounded at compact width and honors chat theme',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final theme = ThemeData(
      extensions: const [
        HandrailChatTheme(
          typography: HandrailChatTypography(
            message: TextStyle(fontSize: 13),
            metadata: TextStyle(fontSize: 11),
            conversationTitle: TextStyle(fontSize: 15),
            composer: TextStyle(fontSize: 19),
          ),
        ),
      ],
    );
    await _pumpComposer(
      tester,
      harness,
      width: 240,
      theme: theme,
    );

    expect(tester.widget<TextField>(find.byKey(_input)).style?.fontSize, 19);
    expect(
      tester
          .widget<SingleChildScrollView>(find.byKey(const ValueKey(
            'handrail-message-composer-format-toolbar',
          )))
          .scrollDirection,
      Axis.horizontal,
    );
    await tester.enterText(find.byKey(_input), 'compact');
    await _selectText(tester, 'compact');
    await _tapFormat(tester, 'code-block');
    expect(_styleForText(tester, 'compact').fontFamily, 'monospace');
    expect(tester.takeException(), isNull);
  });

  testWidgets('retains failed content and retries a failed send',
      (tester) async {
    final harness = _Harness(sendFailuresRemaining: 1);
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(tester, harness);

    await tester.enterText(find.byKey(_input), 'retry this');
    await tester.pump();
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey('handrail-message-composer-retry'),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(_text(tester), 'retry this');
    expect(find.text('The chat command could not be completed.'), findsOne);

    await tester.tap(
      find.byKey(const ValueKey('handrail-message-composer-retry')),
    );
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').length == 2 &&
          _text(tester).isEmpty,
    );
    expect(
      harness.transport
          .operations('send')
          .map((body) => (body['content']! as Map)['text']),
      everyElement('retry this'),
    );
  });

  testWidgets('emits typing lifecycle and submits from the keyboard action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness(realtime: true);
    addTearDown(() => _disposeHarness(tester, harness));
    await tester.runAsync(harness.connectRealtime);
    await _pumpComposer(
      tester,
      harness,
      typingIdleTimeout: const Duration(milliseconds: 100),
    );

    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Message composer')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Message input')), findsOneWidget);
    expect(find.byTooltip('Send message'), findsOneWidget);
    semantics.dispose();

    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), 'keyboard send');
    await tester.pump();
    expect(harness.socket!.typingStates, contains('start'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.socket!.typingStates.last, 'stop');

    await tester.enterText(find.byKey(_input), 'keyboard send');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').isNotEmpty &&
          _text(tester).isEmpty,
    );
    expect(_text(tester), isEmpty);
    expect(harness.socket!.typingStates.last, 'stop');
  });

  testWidgets('uploads a host-selected source and includes its attachment',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    _FakeComposerUpload? upload;
    final delegates = ChatApplicationDelegates(
      pickAttachment: () async => ChatAttachmentPickerUploadSelection([
        ChatAttachmentUploadSource(
          metadata: AttachmentMetadata(
            fileName: 'notes.txt',
            contentType: 'text/plain',
            sizeBytes: 3,
          ),
          source: const Stream<List<int>>.empty(),
        ),
      ]),
    );
    await _pumpComposer(
      tester,
      harness,
      delegates: delegates,
      attachmentUploadStarter: (_, source) =>
          upload = _FakeComposerUpload(source.metadata, uploadedBytes: 2),
    );

    await tester.tap(find.byKey(_attach));
    await tester.pump();
    expect(upload, isNotNull);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('Uploading attachment.'), findsOneWidget);
    upload!.completeSuccessfully();
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey(
              'handrail-message-composer-attachment-attachment-composer-1',
            ),
          )
          .evaluate()
          .isNotEmpty,
    );

    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').isNotEmpty &&
          harness.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    final content = harness.transport.operations('send').single['content']!
        as Map<String, Object?>;
    expect(content['attachments'], [
      {'attachmentId': 'attachment-composer-1'},
    ]);
  });

  testWidgets('cancels an active upload through its public handle',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    _FakeComposerUpload? upload;
    final delegates = ChatApplicationDelegates(
      pickAttachment: () async => ChatAttachmentPickerUploadSelection([
        ChatAttachmentUploadSource(
          metadata: AttachmentMetadata(
            fileName: 'cancel.txt',
            contentType: 'text/plain',
            sizeBytes: 1,
          ),
          source: const Stream<List<int>>.empty(),
        ),
      ]),
    );
    await _pumpComposer(
      tester,
      harness,
      delegates: delegates,
      attachmentUploadStarter: (_, source) =>
          upload = _FakeComposerUpload(source.metadata),
    );

    await tester.tap(find.byKey(_attach));
    await tester.pump();
    final cancel = find.byTooltip('Cancel attachment upload');
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    await tester.pump();
    await _pumpUntil(tester, () => find.text('cancel.txt').evaluate().isEmpty);
    expect(upload?.cancelCalls, 1);
    expect(find.text('Attachment upload failed.'), findsNothing);
  });

  testWidgets('delegate cancellation is inert and does not choose a picker',
      (tester) async {
    var calls = 0;
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(
      tester,
      harness,
      delegates: ChatApplicationDelegates(
        pickAttachment: () async {
          calls += 1;
          return const ChatAttachmentPickerCancelled();
        },
      ),
    );

    await tester.tap(find.byKey(_attach));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(InputChip), findsNothing);
    expect(find.textContaining('Attachment selection'), findsNothing);
    expect(harness.transport.operations('prepare_attachment'), isEmpty);
  });

  testWidgets('enforces UTF-8 and attachment limits', (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(
      tester,
      harness,
      maxTextUtf8Bytes: 4,
      maxAttachments: 1,
      delegates: ChatApplicationDelegates(
        pickAttachment: () async => ChatAttachmentPickerSelection(const [
          AttachmentId('attachment-a'),
          AttachmentId('attachment-b'),
        ]),
      ),
    );

    await tester.enterText(find.byKey(_input), 'ééé');
    await tester.pump();
    expect(find.text('Message is too long (6/4 UTF-8 bytes).'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(_send)).onPressed, isNull);

    await tester.enterText(find.byKey(_input), 'ok');
    await tester.tap(find.byKey(_attach));
    await tester.pump();
    expect(
      find.text('A message can include at most 1 attachments.'),
      findsOneWidget,
    );
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('renders loading, disabled, access-revoked, and error states',
      (tester) async {
    final loading = _Harness(hangQueries: true);
    addTearDown(() => _disposeHarness(tester, loading));
    await _pumpComposer(tester, loading, waitUntilReady: false);
    expect(
      tester
          .widget<Text>(find.byKey(
            const ValueKey('handrail-message-composer-status'),
          ))
          .data,
      'Loading message composer.',
    );
    expect(tester.widget<TextField>(find.byKey(_input)).enabled, isFalse);

    final disabled = _Harness();
    addTearDown(() => _disposeHarness(tester, disabled));
    await _pumpComposer(
      tester,
      disabled,
      enabled: false,
      waitUntilReady: false,
    );
    expect(
      tester
          .widget<Text>(find.byKey(
            const ValueKey('handrail-message-composer-status'),
          ))
          .data,
      'Message composer disabled.',
    );

    final revoked = _Harness(conversationStatus: 403, timelineStatus: 403);
    addTearDown(() => _disposeHarness(tester, revoked));
    await _pumpComposer(tester, revoked, waitUntilReady: false);
    await _pumpUntil(
      tester,
      () => find
          .text('You no longer have access to this conversation.')
          .evaluate()
          .isNotEmpty,
    );

    final error = _Harness(conversationStatus: 500, timelineStatus: 500);
    addTearDown(() => _disposeHarness(tester, error));
    await _pumpComposer(tester, error, waitUntilReady: false);
    await _pumpUntil(
      tester,
      () => find
          .text('The message composer could not be loaded.')
          .evaluate()
          .isNotEmpty,
    );
  });

  testWidgets(
      'filters active members and keyboard selection sends one canonical mention',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final searches = <String>[];
    await _pumpComposer(
      tester,
      harness,
      mentions: _mentionConfiguration(
        search: (request) async {
          searches.add(request.query);
          return HandrailMemberDirectoryPage(
            rows: const [
              _outsider,
              _disabled,
              _removed,
              _grace,
              _grace,
            ],
          );
        },
      ),
    );
    harness.installCanonicalMembers();
    await tester.pump();

    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), '@gr');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isNotEmpty,
    );
    expect(searches, contains('gr'));
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Outside Olivia'), findsNothing);
    expect(find.text('Disabled Dana'), findsNothing);
    expect(find.text('Removed Riley'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(_text(tester), '@Grace ');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isEmpty,
    );
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').isNotEmpty,
    );
    expect(
      _mentionsIn(
        harness.transport.operations('synchronize_draft').last['content'],
      ),
      [
        {'type': 'user', 'userId': _graceId.value},
      ],
    );

    await tester.enterText(find.byKey(_input), '@Grace @gr');
    await _pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey('handrail-message-composer-mention-user-grace'),
          )
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('handrail-message-composer-mention-user-grace'),
      ),
    );
    await tester.pump();
    expect(_text(tester), '@Grace @Grace ');
    await _selectText(tester, '@Grace');
    await _tapFormat(tester, 'bold');
    expect(_text(tester), '@Grace @Grace ');
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').isNotEmpty &&
          harness.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    expect(
      _mentionsIn(harness.transport.operations('send').single['content']),
      [
        {'type': 'user', 'userId': _graceId.value},
      ],
    );
    expect(
      harness.transport.operations('send').single['content'],
      containsPair('text', '**@Grace** @Grace '),
    );
  });

  testWidgets('Escape preserves text and token edits remove stale metadata',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(
      tester,
      harness,
      mentions: _mentionConfiguration(),
    );
    harness.installCanonicalMembers();
    await tester.pump();

    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), '@gr');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isNotEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(_text(tester), '@gr');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isEmpty,
    );

    await tester.enterText(find.byKey(_input), '@g');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isNotEmpty,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('handrail-message-composer-mention-user-grace'),
      ),
    );
    await tester.pump();
    expect(_text(tester), '@Grace ');

    harness.transport.requests.clear();
    await tester.enterText(find.byKey(_input), '@Gracie ');
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').isNotEmpty,
    );
    expect(
      _mentionsIn(
        harness.transport.operations('synchronize_draft').last['content'],
      ),
      isEmpty,
    );

    await tester.enterText(find.byKey(_input), '@gr');
    await _pumpUntil(
      tester,
      () => find.byKey(_mentionPopup).evaluate().isNotEmpty,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('handrail-message-composer-mention-user-grace'),
      ),
    );
    await tester.pump();
    harness.transport.requests.clear();
    await tester.enterText(find.byKey(_input), 'deleted');
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').isNotEmpty,
    );
    expect(
      _mentionsIn(
        harness.transport.operations('synchronize_draft').last['content'],
      ),
      isEmpty,
    );
  });

  testWidgets('restores only a resolved active mention into draft and send',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    await _pumpComposer(
      tester,
      harness,
      mentions: _mentionConfiguration(),
    );
    harness.installCanonicalMembers();
    await tester.pump();
    harness.transport.requests.clear();
    expect(
      harness.client.reconcileDraftEvent(
        _draftEvent(
          '@Grace hello',
          mentions: const [UserMention(userId: _graceId)],
        ),
      ),
      isTrue,
    );
    await _pumpUntil(
      tester,
      () =>
          _text(tester) == '@Grace hello' &&
          tester.widget<IconButton>(find.byKey(_send)).onPressed != null,
    );

    await tester.enterText(find.byKey(_input), '@Grace hello again');
    await _pumpUntil(
      tester,
      () => harness.transport.operations('synchronize_draft').isNotEmpty,
    );
    expect(
      _mentionsIn(
        harness.transport.operations('synchronize_draft').last['content'],
      ),
      [
        {'type': 'user', 'userId': _graceId.value},
      ],
    );
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          harness.transport.operations('send').isNotEmpty &&
          harness.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    expect(
      _mentionsIn(harness.transport.operations('send').single['content']),
      [
        {'type': 'user', 'userId': _graceId.value},
      ],
    );
  });

  testWidgets(
      'email, mid-word, selection, IME, disabled, and absent directory stay inert',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var searches = 0;
    final configuration = _mentionConfiguration(
      search: (request) async {
        searches += 1;
        return HandrailMemberDirectoryPage(rows: const [_grace]);
      },
    );
    await _pumpComposer(
      tester,
      harness,
      controller: controller,
      mentions: configuration,
    );
    harness.installCanonicalMembers();
    await tester.pump();
    await tester.tap(find.byKey(_input));

    for (final text in const ['grace@example.com', 'hello@gr']) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      await tester.pump();
      expect(find.byKey(_mentionPopup), findsNothing);
    }
    controller.value = const TextEditingValue(
      text: '@gr',
      selection: TextSelection(baseOffset: 1, extentOffset: 3),
    );
    await tester.pump();
    expect(find.byKey(_mentionPopup), findsNothing);
    controller.value = const TextEditingValue(
      text: '@gr',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    await tester.pump();
    expect(find.byKey(_mentionPopup), findsNothing);
    expect(searches, 0);

    final disabledController = TextEditingController(text: '@gr');
    addTearDown(disabledController.dispose);
    await _pumpComposer(
      tester,
      harness,
      controller: disabledController,
      mentions: configuration,
      enabled: false,
      waitUntilReady: false,
    );
    await tester.pump();
    expect(find.byKey(_mentionPopup), findsNothing);
    expect(searches, 0);

    final noDirectory = _Harness();
    addTearDown(() => _disposeHarness(tester, noDirectory));
    await _pumpComposer(tester, noDirectory);
    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), '@Grace');
    await tester.pump();
    expect(find.byKey(_mentionPopup), findsNothing);
    await tester.tap(find.byKey(_send));
    await _pumpUntil(
      tester,
      () =>
          noDirectory.transport.operations('send').isNotEmpty &&
          noDirectory.transport
              .operations('synchronize_draft')
              .any((body) => body['intent'] == 'clear'),
    );
    expect(
      _mentionsIn(noDirectory.transport.operations('send').single['content']),
      isEmpty,
    );
  });

  testWidgets('stale directory results cannot replace a newer query',
      (tester) async {
    final harness = _Harness();
    addTearDown(() => _disposeHarness(tester, harness));
    final pending = <String, Completer<HandrailMemberDirectoryPage>>{};
    await _pumpComposer(
      tester,
      harness,
      mentions: _mentionConfiguration(
        search: (request) => (pending[request.query] ??= Completer()).future,
      ),
    );
    harness.installCanonicalMembers();
    await tester.pump();
    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), '@g');
    await tester.pump();
    await tester.enterText(find.byKey(_input), '@gr');
    await tester.pump();
    pending['gr']!.complete(
      HandrailMemberDirectoryPage(rows: const [_grace]),
    );
    await _pumpUntil(
      tester,
      () => find.text('Grace').evaluate().isNotEmpty,
    );
    pending['g']!.complete(
      HandrailMemberDirectoryPage(rows: const [_gina]),
    );
    await tester.pump();
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Gina'), findsNothing);
  });

  testWidgets('disposal stops typing and cancels pending local work',
      (tester) async {
    final picker = Completer<ChatAttachmentPickerResult>();
    final harness = _Harness(realtime: true);
    addTearDown(() => _disposeHarness(tester, harness));
    await tester.runAsync(harness.connectRealtime);
    await _pumpComposer(
      tester,
      harness,
      draftDebounce: const Duration(seconds: 1),
      delegates: ChatApplicationDelegates(
        pickAttachment: () => picker.future,
      ),
    );
    harness.transport.requests.clear();

    await tester.tap(find.byKey(_input));
    await tester.enterText(find.byKey(_input), 'dispose me');
    await tester.tap(find.byKey(_attach));
    await tester.pump();
    expect(harness.socket!.typingStates.last, 'start');

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    picker.complete(
      ChatAttachmentPickerSelection(const [AttachmentId('too-late')]),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(harness.transport.operations('synchronize_draft'), isEmpty);
    expect(harness.transport.operations('prepare_attachment'), isEmpty);
    expect(harness.socket!.typingStates.last, 'stop');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpComposer(
  WidgetTester tester,
  _Harness harness, {
  ChatApplicationDelegates delegates = const ChatApplicationDelegates(),
  Duration draftDebounce = const Duration(milliseconds: 20),
  Duration typingIdleTimeout = const Duration(seconds: 3),
  int maxTextUtf8Bytes = maxDraftTextUtf8Bytes,
  int maxAttachments = maxDraftAttachmentReferences,
  bool enabled = true,
  bool waitUntilReady = true,
  TextEditingController? controller,
  HandrailMessageMentionConfiguration? mentions,
  HandrailMessageComposerUploadStarter? attachmentUploadStarter,
  double? width,
  ThemeData? theme,
  ConversationId conversationId = _conversationId,
  GlobalKey<HandrailMessageComposerState>? composerKey,
  FocusNode? focusNode,
  bool showFormatSelector = true,
  HandrailMessageComposerReplyBuilder? replyBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: ChatScope(
        key: ValueKey<_Harness>(harness),
        client: harness.client,
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                width: width,
                child: HandrailMessageComposer(
                  key: composerKey,
                  conversationId: conversationId,
                  focusNode: focusNode,
                  showFormatSelector: showFormatSelector,
                  replyBuilder: replyBuilder,
                  delegates: delegates,
                  controller: controller,
                  enabled: enabled,
                  draftDebounce: draftDebounce,
                  typingIdleTimeout: typingIdleTimeout,
                  maxTextUtf8Bytes: maxTextUtf8Bytes,
                  maxAttachments: maxAttachments,
                  mentions: mentions,
                  attachmentUploadStarter: attachmentUploadStarter,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (waitUntilReady) {
    await _pumpUntil(
      tester,
      () => tester.widget<TextField>(find.byKey(_input)).enabled ?? false,
    );
  } else {
    await tester.pump();
  }
}

String _text(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_input)).controller!.text;

TextSpan _editingSpan(WidgetTester tester) {
  final field = tester.widget<TextField>(find.byKey(_input));
  return field.controller!.buildTextSpan(
    context: tester.element(find.byKey(_input)),
    style: field.style,
    withComposing: true,
  );
}

TextStyle _styleForText(WidgetTester tester, String text) {
  TextStyle? result;

  void visit(InlineSpan span) {
    if (span is! TextSpan || result != null) return;
    if (span.text == text) {
      result = span.style;
      return;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child);
    }
  }

  visit(_editingSpan(tester));
  expect(result, isNotNull, reason: 'No visual span found for "$text".');
  return result!;
}

Future<void> _selectText(WidgetTester tester, String text) async {
  final field = tester.widget<TextField>(find.byKey(_input));
  final start = field.controller!.text.indexOf(text);
  expect(start, isNonNegative, reason: 'Could not select "$text".');
  field.controller!.selection = TextSelection(
    baseOffset: start,
    extentOffset: start + text.length,
  );
  await tester.pump();
}

Future<void> _tapFormat(WidgetTester tester, String format) async {
  final finder = find.byKey(
    ValueKey('handrail-message-composer-format-$format'),
  );
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

HandrailMessageMentionConfiguration _mentionConfiguration({
  HandrailMemberDirectorySearchDelegate? search,
  HandrailMessageMentionResolver? resolve,
}) =>
    HandrailMessageMentionConfiguration(
      searchDirectory: search ??
          (_) async => HandrailMemberDirectoryPage(
                rows: const [
                  _grace,
                  _gina,
                  _disabled,
                  _removed,
                  _outsider,
                ],
              ),
      resolveUser: resolve ??
          (userId) async => switch (userId) {
                _graceId => _grace,
                _ginaId => _gina,
                _disabledId => _disabled,
                _removedId => _removed,
                _outsiderId => _outsider,
                _ => null,
              },
    );

List<Object?> _mentionsIn(Object? content) {
  final object = content! as Map<String, Object?>;
  return (object['mentions'] as List<Object?>?) ?? const [];
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var index = 0; index < 200 && !predicate(); index += 1) {
    await tester.pump(const Duration(milliseconds: 5));
    // Cancellation futures can finish in the real async zone. Drain both
    // zones while keeping application timers controlled by the widget clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(predicate(), isTrue,
      reason: 'Asynchronous widget work did not settle.');
}

Future<void> _connectStoredComposer(
    WidgetTester tester, _Harness harness) async {
  final initialized = harness.client.initialize();
  await tester.pump();
  await initialized;
  final started = harness.realtimeSession!.start();
  await _pumpUntil(tester, () => harness.socket!.sent.isNotEmpty);
  harness.socket!.emit(_acceptedFrame());
  await _pumpUntil(tester,
      () => harness.realtimeSession!.state is ChatRealtimeConnectedState);
  await started;
}

// Faults only at the host storage boundary; serialization and mutation use
// the SDK's existing storage implementation and real runtime queues.
final class _ControlledStorage implements ApplicationChatStorage {
  final delegate = InMemoryApplicationChatStorage();
  ApplicationChatStorageRecordKind? failKind;
  Completer<void>? pendingWrite;
  bool waiting = false;

  @override
  Future<ApplicationChatStorageRecord?> read(
          ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      delegate.read(identity, kind);
  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind == failKind) throw StateError('storage unavailable');
    if (record.kind == ApplicationChatStorageRecordKind.queuedDraftIntents &&
        pendingWrite != null) {
      waiting = true;
      await pendingWrite!.future;
    }
    await delegate.replace(record);
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      delegate.remove(identity, kind);
  @override
  Future<void> clearForLogout(
          ApplicationChatStorageIdentity previousIdentity) =>
      delegate.clearForLogout(previousIdentity);
  @override
  Future<void> clearForIdentityChange(
          {required ApplicationChatStorageIdentity previousIdentity,
          required ApplicationChatStorageIdentity nextIdentity}) =>
      delegate.clearForIdentityChange(
          previousIdentity: previousIdentity, nextIdentity: nextIdentity);
}

final class _Harness {
  _Harness({
    int sendFailuresRemaining = 0,
    int conversationStatus = 200,
    int timelineStatus = 200,
    bool hangQueries = false,
    bool realtime = false,
    _ByteTransfer? byteTransfer,
    ApplicationChatStorage? storage,
  })  : transport = _ComposerTransport(
          sendFailuresRemaining: sendFailuresRemaining,
          conversationStatus: conversationStatus,
          timelineStatus: timelineStatus,
          hangQueries: hangQueries,
        ),
        socket = realtime ? _Socket() : null,
        byteTransfer = byteTransfer ?? _ByteTransfer.success() {
    realtimeSession = realtime
        ? ChatRealtimeSessionTransport(
            endpoint: Uri.parse('https://chat.test/api/chat'),
            clientPackageVersion: '0.1.3',
            protocolVersion: 4,
            tokenProvider: () async => 'realtime-token',
            socketFactory: (_, __) => socket!,
            network: network,
            ephemeralSignals: const ChatRealtimeEphemeralSignalOptions(
              presenceEnabled: false,
              conversationVisibilityResolver: _publicVisibility,
            ),
          )
        : null;
    var key = 0;
    var message = 0;
    var upload = 0;
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.test/api/chat'),
      tokenProvider: () async => 'token',
      transport: transport,
      realtimeSession: realtimeSession,
      localStorage: storage,
      storageIdentity: storage == null ? null : _storageIdentity,
      offlineSendRetryBackoff: (_) => const Duration(milliseconds: 5),
      attachmentTransferTransport: this.byteTransfer,
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      generateIdempotencyKey: () => 'composer-key-${key += 1}',
      generateDraftDeviceMutationId: () => 'composer-device-${key += 1}',
      generateClientMessageId: () => 'composer-message-${message += 1}',
      generateAttachmentUploadId: () => 'composer-upload-${upload += 1}',
    );
  }

  final network = FakeChatRealtimeNetwork();
  final _ComposerTransport transport;
  final _Socket? socket;
  final _ByteTransfer byteTransfer;
  late final ChatRealtimeSessionTransport? realtimeSession;
  late final HandrailChatClient client;

  Future<void> connectRealtime() async {
    final started = realtimeSession!.start();
    await Future<void>.delayed(Duration.zero);
    socket!.emit(_acceptedFrame());
    await started;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  void installCanonicalMembers() {
    final input = ConversationMembershipMutationInput(
      intent: ConversationMembershipMutationIntent.addMember,
      conversationId: _conversationId,
      expectedMemberListRevision: 1,
      idempotencyKey: 'composer-membership-seed',
      targetUserId: _graceId,
      requestedRole: ConversationMembershipMemberRole.member,
    );
    client.normalizedState.reconcileConversationMembership(
      ConversationMembershipMutationResult.fromJson(
        {
          'operation': 'mutate_conversation_membership',
          'intent': 'add_member',
          'reconciliationStatus': 'applied',
          'conversationId': _conversationId.value,
          'expectedMemberListRevision': 1,
          'memberListRevision': 2,
          'memberUserId': _graceId.value,
          'targetUserId': _graceId.value,
          'requestedRole': 'member',
          'members': [
            membershipMember(_userId, 'member'),
            membershipMember(_disabledId.value, 'member'),
            membershipMember(_ginaId.value, 'member'),
            membershipMember(_graceId.value, 'member'),
            membershipMember(_removedId.value, 'member', 'removed'),
          ],
        },
        expectedInput: input,
      ),
    );
  }

  Future<void> dispose() async {
    await client.dispose();
    await realtimeSession?.dispose();
    await network.dispose();
  }
}

ChatRealtimeConversationVisibility? _publicVisibility(
  ConversationId _,
  ChatRealtimeConversationVisibility? __,
) =>
    ChatRealtimeConversationVisibility.publicConversation;

final class _ComposerTransport implements HandrailChatHttpTransport {
  _ComposerTransport({
    required this.sendFailuresRemaining,
    required this.conversationStatus,
    required this.timelineStatus,
    required this.hangQueries,
  });

  int sendFailuresRemaining;
  int sendFailureStatus = 500;
  final int conversationStatus;
  final int timelineStatus;
  final bool hangQueries;
  final List<HandrailChatHttpRequest> requests = [];
  Map<String, Object?>? pendingAttachment;
  var sentSequence = 10;
  Completer<void>? pendingSend;
  Completer<void>? pendingDraft;
  final Set<String> threads = {};
  String contextStatus = 'available';
  int contextHttpStatus = 200;
  Completer<HandrailChatHttpResponse>? pendingContext;

  List<Map<String, Object?>> operations(String operation) => requests
      .where((request) => request.body != null)
      .map((request) => jsonDecode(request.body!) as Map<String, Object?>)
      .where((body) => body['operation'] == operation)
      .toList(growable: false);

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      if (hangQueries) return Completer<HandrailChatHttpResponse>().future;
      if (request.uri.path.endsWith('/_meta')) {
        return _response(200, {
          'packageVersion': '0.1.3',
          'protocolVersion': 4,
          'schemaVersion': 1,
          'enabledFeatures': {'realtime': true},
          'supportedProtocolRange': {'minimumVersion': 3, 'maximumVersion': 4},
        });
      }
      final parts = request.uri.pathSegments;
      final id = parts[parts.indexOf('conversations') + 1];
      if (request.uri.path.endsWith('/context')) {
        if (pendingContext != null) return pendingContext!.future;
        return _response(contextHttpStatus, _sourceContext(id, contextStatus));
      }
      if (request.uri.path.endsWith('/messages')) {
        if (timelineStatus != 200) return _response(timelineStatus, {});
        return _response(200, _timelineFixture(conversationId: id));
      }
      if (conversationStatus != 200) return _response(conversationStatus, {});
      return _response(
          200,
          _conversationFixture(
              conversationId: id, thread: threads.contains(id)));
    }

    final body = jsonDecode(request.body!) as Map<String, Object?>;
    switch (body['operation']) {
      case 'synchronize_draft':
        await pendingDraft?.future;
        return _response(200, settledDraftResultFixture(body));
      case 'send':
        await pendingSend?.future;
        if (sendFailuresRemaining > 0) {
          sendFailuresRemaining -= 1;
          return _response(sendFailureStatus, {
            'error': {'code': 'TEMPORARY', 'message': 'temporary'},
          });
        }
        sentSequence += 1;
        return _response(200, {
          'operation': 'send',
          'reconciliationStatus': 'applied',
          'clientMessageId': body['clientMessageId'],
          'message': {
            'id': 'sent-$sentSequence',
            'tenantId': _tenantId,
            'conversationId': body['conversationId'],
            if (body['replyTo'] != null) 'replyTo': body['replyTo'],
            'author': {'type': 'user', 'userId': _userId},
            'sequence': sentSequence,
            'createdAt': _now,
            'updatedAt': _now,
            'revision': {'revision': 1},
            'content': body['content'],
          },
          'canonicalRevision': 1,
        });
      case 'prepare_attachment':
        final now = DateTime.now().toUtc();
        pendingAttachment = {
          'status': 'pending',
          'attachmentId': 'attachment-composer-1',
          'metadata': body['metadata'],
          'createdAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
        };
        return _response(200, {
          'operation': 'prepare_attachment',
          'reconciliationStatus': 'applied',
          'idempotencyKey': body['idempotencyKey'],
          'attachment': pendingAttachment,
          'upload': {
            'kind': 'opaque_attachment_upload',
            'descriptor': 'composer-upload-descriptor',
            'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
          },
        });
      case 'finalize_attachment':
        final now = DateTime.now().toUtc();
        return _response(200, {
          'operation': 'finalize_attachment',
          'reconciliationStatus': 'applied',
          'idempotencyKey': body['idempotencyKey'],
          'attachmentId': body['attachmentId'],
          'outcome': 'finalized',
          'attachment': {
            ...pendingAttachment!,
            'status': 'finalized',
            'checksum':
                'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'finalizedAt': now.toIso8601String(),
          },
        });
      case 'abort_attachment':
        final now = DateTime.now().toUtc();
        return _response(200, {
          'operation': 'abort_attachment',
          'reconciliationStatus': 'applied',
          'idempotencyKey': body['idempotencyKey'],
          'attachmentId': body['attachmentId'],
          'attachment': {
            ...pendingAttachment!,
            'status': 'abandoned',
            'abandonedAt': now.toIso8601String(),
          },
        });
      default:
        return _response(400, {
          'error': {'code': 'UNEXPECTED', 'message': 'unexpected'},
        });
    }
  }
}

final class _ByteTransfer implements ChatAttachmentByteTransferTransport {
  _ByteTransfer(this.handler);
  _ByteTransfer.success()
      : handler = ((_) async => const ChatAttachmentBytesUploaded());

  final Future<ChatAttachmentByteTransferResult> Function(
    ChatAttachmentByteTransferRequest request,
  ) handler;

  @override
  Future<ChatAttachmentByteTransferResult> transfer(
    ChatAttachmentByteTransferRequest request,
  ) =>
      handler(request);
}

final class _FakeComposerUpload implements HandrailMessageComposerUploadHandle {
  _FakeComposerUpload(
    this.metadata, {
    int uploadedBytes = 0,
  }) : _state = ChatAttachmentUploadState(
          uploadId: 'composer-upload-fake',
          conversationId: _conversationId,
          metadata: metadata,
          status: ChatAttachmentUploadStatus.uploading,
          uploadedBytes: uploadedBytes,
          attachment: PendingAttachmentState(
            attachmentId: const AttachmentId('attachment-composer-1'),
            metadata: metadata,
            createdAt: const IsoTimestamp(_now),
            expiresAt: const IsoTimestamp('2026-08-26T23:00:00.000Z'),
          ),
        );

  final AttachmentMetadata metadata;
  final Completer<ChatAttachmentUploadResult> _completion =
      Completer<ChatAttachmentUploadResult>();
  ChatAttachmentUploadState _state;
  int cancelCalls = 0;

  @override
  Future<ChatAttachmentUploadResult> get completion => _completion.future;

  @override
  ChatAttachmentUploadState get state => _state;

  @override
  String get uploadId => _state.uploadId;

  void completeSuccessfully() {
    final finalized = FinalizedAttachmentState(
      attachmentId: const AttachmentId('attachment-composer-1'),
      metadata: metadata,
      createdAt: const IsoTimestamp(_now),
      expiresAt: const IsoTimestamp('2026-08-26T23:00:00.000Z'),
      checksum:
          'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      finalizedAt: const IsoTimestamp('2026-08-26T22:01:00.000Z'),
    );
    _state = ChatAttachmentUploadState(
      uploadId: uploadId,
      conversationId: _conversationId,
      metadata: metadata,
      status: ChatAttachmentUploadStatus.finalized,
      uploadedBytes: metadata.sizeBytes,
      attachment: finalized,
    );
    _completion.complete(ChatAttachmentUploadFinalized(finalized));
  }

  @override
  void cancel() {
    cancelCalls += 1;
    if (_completion.isCompleted) return;
    _state = ChatAttachmentUploadState(
      uploadId: uploadId,
      conversationId: _conversationId,
      metadata: metadata,
      status: ChatAttachmentUploadStatus.cancelled,
      uploadedBytes: state.uploadedBytes,
    );
    _completion.complete(const ChatAttachmentUploadCancelled());
  }
}

final class _Socket implements ChatRealtimeSocket {
  final StreamController<Object?> _frames =
      StreamController<Object?>.broadcast(sync: true);
  final List<String> sent = [];

  List<String> get typingStates => sent
      .map((frame) => jsonDecode(frame) as Map<String, Object?>)
      .where((frame) => frame['type'] == 'typing.signal')
      .map((frame) =>
          ((frame['payload']! as Map<String, Object?>)['state']! as String))
      .toList(growable: false);

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  void close() {}

  void emit(Map<String, Object?> frame) => _frames.add(jsonEncode(frame));
}

Map<String, Object?> _acceptedFrame() => {
      'type': 'chat.session.accepted',
      'metadata': {
        'packageVersion': '0.1.3',
        'protocolVersion': 4,
        'schemaVersion': 1,
        'enabledFeatures': {'typing': true},
        'supportedProtocolRange': {
          'minimumVersion': 3,
          'maximumVersion': 4,
        },
      },
      'tenantId': _tenantId,
      'actorStreamId': 'user:$_userId',
      'deviceId': 'device-composer',
      'sessionId': 'session-composer',
    };

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

ConversationDraftUpdatedEvent _draftEvent(
  String text, {
  List<MessageMention>? mentions,
  MessageReplyReference? replyTo,
  List<String> attachments = const [],
  int baseRevision = 0,
}) {
  final input = <String, Object?>{
    'operation': 'synchronize_draft',
    'intent': 'replace',
    'conversationId': _conversationId.value,
    'baseRevision': baseRevision,
    'deviceMutationId': 'composer-seed-device',
    'idempotencyKey': 'composer-seed-key',
    'content': <String, Object?>{
      'format': 'markdown',
      'text': text,
      if (mentions != null)
        'mentions': [for (final mention in mentions) mention.toJson()],
      'attachments': [
        for (final id in attachments) {'attachmentId': id}
      ],
      if (replyTo != null) 'replyTo': replyTo.toJson(),
    },
  };
  final result = settledDraftResultFixture(input);
  return ConversationDraftUpdatedEvent.fromJson(
    {
      'eventId': 'composer-seed-event',
      'protocolVersion': 4,
      'tenantId': _tenantId,
      'streamId': 'user:$_userId',
      'type': draftUpdatedEventType,
      'occurredAt': canonicalDraftUpdatedAtFixture,
      'payload': {
        'actorUserId': _userId,
        'input': input,
        'result': result,
      },
    },
    expectedTenantId: const TenantId(_tenantId),
  );
}

const _sourceId = MessageId('reply-source');
Map<String, Object?> _sourceContext(String conversationId, String status) => {
      'status': status,
      'conversationId': conversationId,
      'messageId': _sourceId.value,
      if (status != 'unavailable') ...{
        'sequence': 1,
        'message': {
          'id': _sourceId.value,
          'tenantId': _tenantId,
          'conversationId': conversationId,
          'author': {'type': 'user', 'userId': 'alice'},
          'sequence': 1,
          'createdAt': _now,
          'updatedAt': _now,
          'revision': {'revision': status == 'deleted' ? 2 : 1},
          'content': status == 'deleted'
              ? null
              : {'format': 'plain', 'text': 'Which launch date?'},
          if (status == 'deleted') ...{
            'deletedAt': _now,
            'deletedByUserId': 'alice'
          },
        },
      },
    };

ChatMessageContextController _authorizeSource(_Harness harness,
    {ConversationId conversationId = _conversationId}) {
  final controller = harness.client.messageContexts.forMessage(
      MessageContextRequest(
          conversationId: conversationId, messageId: _sourceId));
  controller.setAuthority(const ChatMessageContextAuthority(
      tenantId: TenantId(_tenantId), userId: UserId(_userId), canRead: true));
  return controller;
}

Future<void> _disposeHarness(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox());
  var closed = false;
  unawaited(harness.dispose().then((_) => closed = true));
  await _pumpUntil(tester, () => closed);
}
