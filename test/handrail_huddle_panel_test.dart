import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/testing.dart';

const _conversationId = ConversationId('conversation-panel');
const _sessionId = HuddleSessionId('huddle-panel');
final _now = DateTime.utc(2030, 1, 1);

void main() {
  testWidgets('renders inactive, serializes start, then joins and connects', (
    tester,
  ) async {
    final harness = _Harness();
    final provider = _provider();
    final delegate = FakeChatMediaDelegate(fallbackSession: provider);
    final session = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: delegate,
    );

    await _pumpPanel(tester, harness.controller, mediaSession: session);
    expect(find.text('Inactive'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-start')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-start')));
    await _pumpUntil(
      tester,
      () => harness.controller.state.canonicalState is StartingHuddleState,
      diagnostic: () => '${harness.controller.state}; '
          'responses=${harness.responseCount}; '
          'diagnostics=${harness.diagnostics}',
    );
    expect(find.text('Starting'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-join')), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-end')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-join')));
    await _pumpUntil(
      tester,
      () => session.state.status == ChatMediaSessionStatus.connected,
    );
    expect(find.text('Active'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsOneWidget);
    expect(delegate.connectCount, 1);
    expect(session.state.status, ChatMediaSessionStatus.connected);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(provider.closeCount, 0,
        reason: 'The supplied session is caller-owned.');
    await tester.runAsync(harness.dispose);
  });

  testWidgets('disables lifecycle controls while an action is pending', (
    tester,
  ) async {
    final harness = _Harness(holdStart: true);
    await _pumpPanel(tester, harness.controller);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-start')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('handrail-huddle-pending')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('handrail-huddle-start')),
          )
          .onPressed,
      isNull,
    );
    expect(harness.transport.requests, hasLength(1));

    harness.releaseStart();
    await _pumpUntil(
      tester,
      () => harness.controller.state.canonicalState is StartingHuddleState,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  });

  testWidgets(
    'renders participants, active speakers, media toggles, and live devices',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = _Harness();
      await tester.runAsync(
        () => harness.activate(withDepartedParticipant: true),
      );
      final provider = _provider();
      final delegate = FakeChatMediaDelegate(fallbackSession: provider);
      final session = ChatHuddleMediaSession(
        controller: harness.controller,
        delegate: delegate,
      );
      await tester.runAsync(session.connect);

      await _pumpPanel(
        tester,
        harness.controller,
        mediaSession: session,
        width: 900,
      );
      expect(find.text('user-alice'), findsOneWidget);
      expect(find.text('user-bob'), findsOneWidget);
      expect(find.text('Joined'), findsOneWidget);
      expect(find.text('Departed'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('user-bob, Departed')),
        findsOneWidget,
      );

      provider.emitActiveSpeakers(const [
        ChatMediaActiveSpeaker(participantId: 'user-alice', isSpeaking: true),
        ChatMediaActiveSpeaker(participantId: 'unknown-user', isSpeaking: true),
      ]);
      await _pumpUntil(
        tester,
        () => find.text('Speaking').evaluate().isNotEmpty,
        diagnostic: () => 'session=${session.state}; '
            'controller=${harness.controller.state}',
      );
      expect(find.text('Speaking'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('user-alice, Joined, active speaker')),
        findsOneWidget,
      );
      expect(find.text('unknown-user'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('handrail-huddle-microphone')),
      );
      await _pumpUntil(tester, () => session.state.microphoneEnabled);
      expect(session.state.microphoneEnabled, isTrue);
      expect(find.bySemanticsLabel('Mute microphone'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('handrail-huddle-microphone')),
      );
      await _pumpUntil(tester, () => !session.state.microphoneEnabled);
      expect(session.state.microphoneEnabled, isFalse);

      await tester.tap(
        find.byKey(const ValueKey('handrail-huddle-screen-share')),
      );
      await _pumpUntil(tester, () => session.state.screenShareEnabled);
      expect(session.state.screenShareEnabled, isTrue);
      expect(find.bySemanticsLabel('Stop screen sharing'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('handrail-huddle-screen-share')),
      );
      await _pumpUntil(tester, () => !session.state.screenShareEnabled);
      expect(session.state.screenShareEnabled, isFalse);

      await _chooseDropdown(
        tester,
        const ValueKey('handrail-huddle-audio-input'),
        'USB microphone',
      );
      await _pumpUntil(
        tester,
        () => session.state.devices.selectedAudioInputId == 'input-usb',
      );
      await _chooseDropdown(
        tester,
        const ValueKey('handrail-huddle-audio-output'),
        'Headphones',
      );
      await _pumpUntil(
        tester,
        () =>
            session.state.devices.selectedAudioOutputId == 'output-headphones',
      );
      expect(session.state.devices.selectedAudioInputId, 'input-usb');
      expect(session.state.devices.selectedAudioOutputId, 'output-headphones');

      provider.emitDevices(ChatMediaDeviceState(
        devices: const [
          ChatMediaDevice(
            id: 'input-dock',
            kind: ChatMediaDeviceKind.audioInput,
            label: 'Dock microphone',
          ),
          ChatMediaDevice(
            id: 'output-dock',
            kind: ChatMediaDeviceKind.audioOutput,
            label: 'Dock speaker',
          ),
        ],
        selectedAudioInputId: 'input-dock',
        selectedAudioOutputId: 'output-dock',
      ));
      await tester.pump();
      expect(find.text('Dock microphone'), findsOneWidget);
      expect(find.text('Dock speaker'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Huddle status: Active')),
        findsOneWidget,
      );

      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(harness.dispose);
    },
  );

  testWidgets('leaves, ends, and presents the terminal state', (tester) async {
    final harness = _Harness();
    await tester.runAsync(harness.activate);
    final provider = _provider();
    final session = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: FakeChatMediaDelegate(fallbackSession: provider),
    );
    await tester.runAsync(session.connect);
    await _pumpPanel(tester, harness.controller, mediaSession: session);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-leave')));
    await _pumpUntil(
      tester,
      () =>
          harness.controller.state.canonicalState is ActiveHuddleState &&
          (harness.controller.state.canonicalState as ActiveHuddleState)
              .participants
              .every((participant) =>
                  participant.status == HuddleParticipantStatus.left),
      diagnostic: () => '${harness.controller.state}; '
          'diagnostics=${harness.diagnostics}',
    );
    expect(find.text('Departed'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-join')), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsNothing);
    expect(find.text('Media'), findsNothing);
    expect(
      find.byKey(const ValueKey('handrail-huddle-audio-input')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('handrail-huddle-end')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-end')));
    await _pumpUntil(
      tester,
      () => harness.controller.state.canonicalState is EndedHuddleState,
    );
    expect(find.text('Huddle ended'), findsOneWidget);
    expect(find.text('user-alice'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsNothing);
    expect(find.byKey(const ValueKey('handrail-huddle-end')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  });

  testWidgets('known actor can rejoin after denied end then successful leave', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final harness = _Harness(
        storage: InMemoryApplicationChatStorage(),
        denyEnd: true,
        withJoinedParticipant: true,
      );
      await harness.client.activateStorageIdentity(
        ApplicationChatStorageIdentity(
          tenantId: const TenantId('tenant-panel'),
          userId: const UserId('user-alice'),
          deviceId: const DeviceId('device-panel'),
        ),
      );
      await harness.activate();
      return harness;
    }))!;
    final session = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: FakeChatMediaDelegate(fallbackSession: _provider()),
    );
    await tester.runAsync(session.connect);
    await _pumpPanel(tester, harness.controller, mediaSession: session);
    expect(
      harness.controller.currentActorParticipation,
      ChatHuddleActorParticipation.joined,
    );
    expect(find.text('Joined'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-huddle-join')), findsNothing);
    expect(
      find.byKey(const ValueKey('handrail-huddle-microphone')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-end')));
    await _pumpUntil(
      tester,
      () => find
          .text('Huddle access could not be verified.')
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.textContaining('private huddle authorization fixture detail'),
      findsNothing,
    );
    expect(find.textContaining('HUDDLE_HOST_REQUIRED'), findsNothing);
    expect(harness.controller.state.canonicalState, isA<ActiveHuddleState>());
    expect(
      harness.controller.currentActorParticipation,
      ChatHuddleActorParticipation.joined,
    );
    expect(find.text('Joined'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-leave')));
    await _pumpUntil(
      tester,
      () =>
          harness.controller.currentActorParticipation ==
          ChatHuddleActorParticipation.left,
    );
    final canonical =
        harness.controller.state.canonicalState as ActiveHuddleState;
    expect(canonical.participants, hasLength(2));
    expect(
      canonical.participants
          .singleWhere((p) => p.userId.value == 'user-alice')
          .status,
      HuddleParticipantStatus.left,
    );
    expect(
      canonical.participants
          .singleWhere((p) => p.userId.value == 'user-bob')
          .status,
      HuddleParticipantStatus.joined,
    );
    expect(harness.controller.state.media, isA<ChatHuddleMediaIdleState>());
    expect(find.text('Departed'), findsOneWidget);
    expect(find.text('Joined'), findsOneWidget);
    expect(find.text('Join huddle'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('handrail-huddle-join')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(const ValueKey('handrail-huddle-leave')), findsNothing);
    expect(find.text('Huddle access could not be verified.'), findsNothing);
    expect(find.text('Media'), findsNothing);
    for (final control in [
      'microphone',
      'screen-share',
      'audio-input',
      'audio-output',
    ]) {
      expect(find.byKey(ValueKey('handrail-huddle-$control')), findsNothing);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  });

  testWidgets('surfaces permission denial and stable provider failure text', (
    tester,
  ) async {
    const providerSecret = 'SECRET_PROVIDER_EXCEPTION_TEXT';
    final harness = _Harness();
    await tester.runAsync(harness.activate);
    final provider = _provider();
    final delegate = FakeChatMediaDelegate(fallbackSession: provider)
      ..enqueuePermission(
        ChatMediaPermission.microphone,
        ChatMediaPermissionDecision.denied,
      );
    final session = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: delegate,
    );
    await tester.runAsync(session.connect);
    await _pumpPanel(tester, harness.controller, mediaSession: session);

    await tester.tap(
      find.byKey(const ValueKey('handrail-huddle-microphone')),
    );
    await _pumpUntil(
      tester,
      () =>
          session.state.lastFailure?.code ==
          ChatMediaErrorCode.permissionDenied,
    );
    expect(find.text('Microphone permission was denied.'), findsOneWidget);
    expect(delegate.permissionRequests, [ChatMediaPermission.microphone]);

    provider.queueError(
      ChatMediaOperation.microphone,
      StateError(providerSecret),
    );
    await tester.tap(
      find.byKey(const ValueKey('handrail-huddle-microphone')),
    );
    await _pumpUntil(
      tester,
      () =>
          session.state.lastFailure?.code == ChatMediaErrorCode.providerFailure,
    );
    expect(
        find.text('Media operation could not be completed.'), findsOneWidget);
    expect(find.textContaining(providerSecret), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  });

  testWidgets('surfaces stable controller failure without response text', (
    tester,
  ) async {
    final harness = _Harness(failOperation: 'start_huddle');
    await _pumpPanel(tester, harness.controller);

    await tester.tap(find.byKey(const ValueKey('handrail-huddle-start')));
    await _pumpUntil(
      tester,
      () =>
          harness.controller.state.pendingOperation == null &&
          harness.controller.state.media is ChatHuddleMediaErrorState,
    );
    expect(find.text('Huddle action could not be completed.'), findsOneWidget);
    expect(find.textContaining('SERVER_PRIVATE_FAILURE'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  });

  testWidgets(
      'capability-disabled state performs no permission or provider work', (
    tester,
  ) async {
    final harness = _Harness(huddlesEnabled: false);
    await tester.runAsync(() async {
      await harness.initialize();
      await harness.controller.hydrate();
    });
    final delegate = FakeChatMediaDelegate(fallbackSession: _provider());

    await _pumpPanel(tester, harness.controller, mediaDelegate: delegate);
    expect(
      find.text('Huddles are unavailable for this conversation.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('handrail-huddle-start')),
          )
          .onPressed,
      isNull,
    );
    expect(delegate.permissionRequests, isEmpty);
    expect(delegate.connectCount, 0);
    expect(harness.transport.requests, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(harness.dispose);
  });

  testWidgets('switches between compact and expanded accessible layouts', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness();

    await _pumpPanel(tester, harness.controller, width: 320);
    expect(
      find.byKey(const ValueKey('handrail-huddle-compact')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('Handrail huddle panel')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('Huddle status: Inactive')),
      findsOneWidget,
    );

    await _pumpPanel(tester, harness.controller, width: 900);
    expect(
      find.byKey(const ValueKey('handrail-huddle-expanded')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('handrail-huddle-compact')), findsNothing);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(harness.dispose);
  });

  testWidgets(
      'closes panel-owned media once on controller replacement and unmount', (
    tester,
  ) async {
    final first = _Harness();
    final second = _Harness(conversationId: const ConversationId('second'));
    await tester.runAsync(first.activate);
    await tester.runAsync(second.activate);
    final firstProvider = _provider();
    final secondProvider = _provider();
    final firstDelegate = FakeChatMediaDelegate(fallbackSession: firstProvider);
    final secondDelegate =
        FakeChatMediaDelegate(fallbackSession: secondProvider);

    await _pumpPanel(
      tester,
      first.controller,
      mediaDelegate: firstDelegate,
    );
    await _pumpUntil(tester, () => firstDelegate.connectCount == 1);
    expect(firstProvider.closeCount, 0);

    await _pumpPanel(
      tester,
      second.controller,
      mediaDelegate: secondDelegate,
    );
    await _pumpUntil(
      tester,
      () => firstProvider.closeCount == 1 && secondDelegate.connectCount == 1,
    );
    expect(firstProvider.closeCount, 1);
    expect(secondProvider.closeCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => secondProvider.closeCount == 1);
    expect(firstProvider.closeCount, 1);
    expect(secondProvider.closeCount, 1);
    expect(
      second.controller.reconcileCanonicalState(
        _state(_active(second.conversationId)),
      ),
      isTrue,
      reason: 'The panel must never dispose the caller-owned controller.',
    );

    await tester.runAsync(first.dispose);
    await tester.runAsync(second.dispose);
  });

  testWidgets('does not close supplied sessions or accept stale updates', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.runAsync(harness.activate);
    final firstProvider = _provider();
    final secondProvider = _provider();
    final firstSession = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: FakeChatMediaDelegate(fallbackSession: firstProvider),
    );
    final secondSession = ChatHuddleMediaSession(
      controller: harness.controller,
      delegate: FakeChatMediaDelegate(fallbackSession: secondProvider),
    );
    await tester.runAsync(firstSession.connect);
    await tester.runAsync(secondSession.connect);

    await _pumpPanel(
      tester,
      harness.controller,
      mediaSession: firstSession,
    );
    await _pumpPanel(
      tester,
      harness.controller,
      mediaSession: secondSession,
    );
    expect(firstProvider.closeCount, 0);

    firstProvider.emitActiveSpeakers(const [
      ChatMediaActiveSpeaker(participantId: 'user-alice', isSpeaking: true),
    ]);
    await tester.pump();
    expect(find.text('Speaking'), findsNothing);
    secondProvider.emitActiveSpeakers(const [
      ChatMediaActiveSpeaker(participantId: 'user-alice', isSpeaking: true),
    ]);
    await _pumpUntil(
      tester,
      () => find.text('Speaking').evaluate().isNotEmpty,
      diagnostic: () => 'session=${secondSession.state}; '
          'controller=${harness.controller.state}',
    );
    expect(find.text('Speaking'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    secondProvider.emitActiveSpeakers(const [
      ChatMediaActiveSpeaker(participantId: 'user-alice', isSpeaking: false),
    ]);
    harness.controller
        .reconcileCanonicalState(_state(_active(_conversationId)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(firstProvider.closeCount, 0);
    expect(secondProvider.closeCount, 0);

    await tester.runAsync(harness.dispose);
  });
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ChatHuddleController controller, {
  ChatHuddleMediaSession? mediaSession,
  ChatMediaDelegate? mediaDelegate,
  double width = 500,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        extensions: const [
          HandrailChatTheme(spacing: HandrailChatSpacing(medium: 10)),
        ],
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: width,
              child: HandrailHuddlePanel(
                controller: controller,
                mediaSession: mediaSession,
                mediaDelegate: mediaDelegate,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _chooseDropdown(
  WidgetTester tester,
  Key key,
  String label,
) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? diagnostic,
}) async {
  for (var cycle = 0; cycle < 10; cycle++) {
    var reached = condition();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100 && !reached; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        reached = condition();
      }
    });
    await tester.pump();
    if (reached || condition()) {
      return;
    }
  }
  fail(
    'The expected huddle state was not reached.'
    '${diagnostic == null ? '' : ' ${diagnostic()}'}',
  );
}

FakeChatMediaProviderSession _provider() => FakeChatMediaProviderSession(
      initialState: ChatMediaProviderState(
        devices: ChatMediaDeviceState(
          devices: const [
            ChatMediaDevice(
              id: 'input-built-in',
              kind: ChatMediaDeviceKind.audioInput,
              label: 'Built-in microphone',
              isDefault: true,
            ),
            ChatMediaDevice(
              id: 'input-usb',
              kind: ChatMediaDeviceKind.audioInput,
              label: 'USB microphone',
            ),
            ChatMediaDevice(
              id: 'output-speaker',
              kind: ChatMediaDeviceKind.audioOutput,
              label: 'Speaker',
              isDefault: true,
            ),
            ChatMediaDevice(
              id: 'output-headphones',
              kind: ChatMediaDeviceKind.audioOutput,
              label: 'Headphones',
            ),
          ],
          selectedAudioInputId: 'input-built-in',
          selectedAudioOutputId: 'output-speaker',
        ),
      ),
    );

final class _Harness {
  _Harness({
    this.conversationId = _conversationId,
    this.holdStart = false,
    this.failOperation,
    this.huddlesEnabled = true,
    this.denyEnd = false,
    this.withJoinedParticipant = false,
    ApplicationChatStorage? storage,
  }) {
    transport = _Transport(_handleRequest);
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: () async => 'access-token',
      transport: transport,
      localStorage: storage,
      requestedCapabilities: const {'huddles': true, 'media': true},
      commandRetryOptions: ChatCommandRetryOptions(
        maxAttempts: 1,
        backoff: (_) => Duration.zero,
        wait: (_, __) async {},
      ),
      onCommandDiagnostic: diagnostics.add,
      generateIdempotencyKey: () => 'panel-key-${++_keySequence}',
      huddleClock: () => _now,
      huddleTimerScheduler: (_, __) => () {},
    );
    controller = client.huddles.forConversation(conversationId);
  }

  final ConversationId conversationId;
  final bool holdStart;
  final String? failOperation;
  final bool huddlesEnabled;
  final bool denyEnd;
  final bool withJoinedParticipant;
  late final _Transport transport;
  late final HandrailChatClient client;
  late final ChatHuddleController controller;
  var _keySequence = 0;
  var _withDepartedParticipant = false;
  var responseCount = 0;
  final List<ChatCommandDiagnostic> diagnostics = [];
  final Completer<HandrailChatHttpResponse> _startGate = Completer();

  Future<void> initialize() async {
    await client.initialize();
  }

  Future<void> activate({bool withDepartedParticipant = false}) async {
    await controller.start();
    await controller.join();
    if (withDepartedParticipant) {
      _withDepartedParticipant = true;
      controller.reconcileCanonicalState(
        _state(_active(conversationId, withDeparted: true)),
      );
    }
  }

  void releaseStart() {
    if (!_startGate.isCompleted) {
      _startGate.complete(commandResponse('start_huddle'));
    }
  }

  HandrailChatHttpResponse commandResponse(String operation) {
    return _jsonResponse(<String, Object?>{
      'operation': operation,
      'outcome': 'ok',
      'reconciliationStatus': 'applied',
      'state': switch (operation) {
        'start_huddle' => _starting(conversationId),
        'join_huddle' => _active(conversationId,
            withJoined: withJoinedParticipant),
        'leave_huddle' => _left(
            conversationId,
            withDeparted: _withDepartedParticipant,
            withJoined: withJoinedParticipant,
          ),
        'end_huddle' => _ended(
            conversationId,
            withDeparted: _withDepartedParticipant,
          ),
        'set_huddle_screen_share' =>
          throw StateError('screen share needs its intent'),
        _ => throw StateError('Unexpected operation $operation'),
      },
      if (operation == 'start_huddle' || operation == 'join_huddle')
        'mediaJoin': const <String, Object?>{
          'kind': 'opaque_media_join',
          'descriptor': 'opaque-panel-descriptor',
          'expiresAt': '2030-01-01T00:04:00.000Z',
        },
    });
  }

  Future<HandrailChatHttpResponse> _handleRequest(
    HandrailChatHttpRequest request,
  ) async {
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return _jsonResponse(_metadata(huddlesEnabled));
    }
    final input = jsonDecode(request.body!) as Map<String, Object?>;
    final operation = input['operation']! as String;
    if (operation == 'end_huddle' && denyEnd) {
      return HandrailChatHttpResponse(
        statusCode: 403,
        body: jsonEncode(const {
          'error': {
            'code': 'HUDDLE_HOST_REQUIRED',
            'message': 'private huddle authorization fixture detail',
          },
        }),
      );
    }
    if (failOperation == operation) {
      return const HandrailChatHttpResponse(
        statusCode: 500,
        body: 'SERVER_PRIVATE_FAILURE',
      );
    }
    if (operation == 'start_huddle' && holdStart) {
      return _startGate.future;
    }
    if (operation == 'set_huddle_screen_share') {
      responseCount += 1;
      return _jsonResponse(<String, Object?>{
        'operation': operation,
        'outcome': 'ok',
        'reconciliationStatus': 'applied',
        'state': input['intent'] == 'set'
            ? _active(
                conversationId,
                withDeparted: _withDepartedParticipant,
                sharing: true,
              )
            : _active(
                conversationId,
                withDeparted: _withDepartedParticipant,
              ),
      });
    }
    responseCount += 1;
    return commandResponse(operation);
  }

  Future<void> dispose() => client.dispose();
}

final class _Transport implements HandrailChatHttpTransport {
  _Transport(this.handler);

  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final List<HandrailChatHttpRequest> requests = [];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

HandrailChatHttpResponse _jsonResponse(Object? value) =>
    HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(value));

HuddleSessionState _state(Map<String, Object?> value) =>
    HuddleSessionState.fromJson(value);

Map<String, Object?> _metadata(bool huddles) => <String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 1,
      'enabledFeatures': <String, Object?>{
        'huddles': huddles,
        'media': huddles,
        'realtime': true,
      },
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': handrailChatProtocolVersion - 1,
        'maximumVersion': handrailChatProtocolVersion,
      },
    };

Map<String, Object?> _starting(ConversationId conversationId) => {
      'status': 'starting',
      'conversationId': conversationId.value,
      'huddleSessionId': _sessionId.value,
      'startedAt': '2030-01-01T00:00:01.000Z',
      'participants': <Object?>[],
      'screenShareOwnerUserId': null,
    };

Map<String, Object?> _active(
  ConversationId conversationId, {
  bool withDeparted = false,
  bool withJoined = false,
  bool sharing = false,
}) =>
    {
      'status': 'active',
      'conversationId': conversationId.value,
      'huddleSessionId': _sessionId.value,
      'startedAt': '2030-01-01T00:00:01.000Z',
      'participants': <Object?>[
        const <String, Object?>{
          'userId': 'user-alice',
          'status': 'joined',
          'joinedAt': '2030-01-01T00:00:02.000Z',
        },
        if (withJoined)
          const <String, Object?>{
            'userId': 'user-bob',
            'status': 'joined',
            'joinedAt': '2030-01-01T00:00:03.000Z',
          },
        if (withDeparted)
          const <String, Object?>{
            'userId': 'user-bob',
            'status': 'left',
            'joinedAt': '2030-01-01T00:00:03.000Z',
            'leftAt': '2030-01-01T00:00:04.000Z',
          },
      ],
      'screenShareOwnerUserId': sharing ? 'user-alice' : null,
    };

Map<String, Object?> _left(
  ConversationId conversationId, {
  bool withDeparted = false,
  bool withJoined = false,
}) =>
    {
      ..._active(conversationId, withDeparted: withDeparted),
      'participants': <Object?>[
        const <String, Object?>{
          'userId': 'user-alice',
          'status': 'left',
          'joinedAt': '2030-01-01T00:00:02.000Z',
          'leftAt': '2030-01-01T00:00:05.000Z',
        },
        if (withJoined)
          const <String, Object?>{
            'userId': 'user-bob',
            'status': 'joined',
            'joinedAt': '2030-01-01T00:00:03.000Z',
          },
        if (withDeparted)
          const <String, Object?>{
            'userId': 'user-bob',
            'status': 'left',
            'joinedAt': '2030-01-01T00:00:03.000Z',
            'leftAt': '2030-01-01T00:00:04.000Z',
          },
      ],
    };

Map<String, Object?> _ended(
  ConversationId conversationId, {
  bool withDeparted = false,
}) =>
    {
      'status': 'ended',
      'conversationId': conversationId.value,
      'huddleSessionId': _sessionId.value,
      'startedAt': '2030-01-01T00:00:01.000Z',
      'endedAt': '2030-01-01T00:00:06.000Z',
      'endedByUserId': 'user-alice',
      'participants': _left(
        conversationId,
        withDeparted: withDeparted,
      )['participants'],
      'screenShareOwnerUserId': null,
    };
