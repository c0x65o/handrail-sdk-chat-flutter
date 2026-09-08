import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../../flutter.dart';
import '../../ui.dart';
import 'fake_chat_clock.dart';
import 'fake_chat_connectivity.dart';
import 'fake_chat_realtime.dart';
import 'in_memory_application_chat_storage.dart';
import 'scripted_access_token_provider.dart';
import 'scripted_http_transport.dart';

/// A deterministic current value and broadcast stream for [ChatStateBuilder].
///
/// This fixture is intentionally controller-neutral. Tests can script any
/// immutable public state without implementing or subclassing a Handrail
/// controller. [reset] clears observations and synchronously publishes a new
/// current value to attached builders.
final class ScriptedChatStateStream<Value> {
  ScriptedChatStateStream(Value initialState) : _state = initialState {
    _states = StreamController<Value>.broadcast(
      sync: true,
      onListen: () {
        _listenCount += 1;
        _activeListenerCount += 1;
      },
      onCancel: () {
        _cancelCount += 1;
        _activeListenerCount -= 1;
      },
    );
  }

  late final StreamController<Value> _states;
  final List<Value> _emissions = <Value>[];
  Value _state;
  var _listenCount = 0;
  var _cancelCount = 0;
  var _activeListenerCount = 0;
  var _disposed = false;

  Value get state => _state;
  Stream<Value> get states => _states.stream;
  List<Value> get emissions => List<Value>.unmodifiable(_emissions);
  int get listenCount => _listenCount;
  int get cancelCount => _cancelCount;
  int get activeListenerCount => _activeListenerCount;
  bool get isDisposed => _disposed;

  void emit(Value state) {
    _ensureActive();
    _state = state;
    _emissions.add(state);
    _states.add(state);
  }

  void emitAll(Iterable<Value> states) {
    for (final state in states) {
      emit(state);
    }
  }

  void reset(Value state) {
    _ensureActive();
    _state = state;
    _emissions.clear();
    _listenCount = _activeListenerCount;
    _cancelCount = 0;
    _states.add(state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _states.close();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('The scripted chat state is disposed.');
  }
}

/// Controllable push-token events with subscription and identity recording.
final class FakeChatPushTokenDelegate implements ChatPushTokenDelegate {
  FakeChatPushTokenDelegate({ChatPushToken? initialToken})
      : _fallbackInitialToken = initialToken {
    _rotations = StreamController<ChatPushToken>.broadcast(
      sync: true,
      onListen: () {
        _listenCount += 1;
        _activeListenerCount += 1;
      },
      onCancel: () {
        _cancelCount += 1;
        _activeListenerCount -= 1;
      },
    );
  }

  late final StreamController<ChatPushToken> _rotations;
  final Queue<Object?> _initialScripts = Queue<Object?>();
  final List<Object?> _identityScopeKeys = <Object?>[];
  ChatPushToken? _fallbackInitialToken;
  var _listenCount = 0;
  var _cancelCount = 0;
  var _activeListenerCount = 0;
  var _disposed = false;

  List<Object?> get identityScopeKeys =>
      List<Object?>.unmodifiable(_identityScopeKeys);
  int get initialRequestCount => _identityScopeKeys.length;
  int get listenCount => _listenCount;
  int get cancelCount => _cancelCount;
  int get activeListenerCount => _activeListenerCount;
  bool get isDisposed => _disposed;

  set fallbackInitialToken(ChatPushToken? value) {
    _ensureActive();
    _fallbackInitialToken = value;
  }

  void enqueueInitialToken(ChatPushToken? token) {
    _ensureActive();
    _initialScripts.add(token);
  }

  void enqueueInitialError(Object error, [StackTrace? stackTrace]) {
    _ensureActive();
    _initialScripts.add(
      _FlutterChatFixtureFailure(error, stackTrace ?? StackTrace.current),
    );
  }

  @override
  FutureOr<ChatPushToken?> getInitialPushToken({
    required Object? identityScopeKey,
  }) {
    _ensureActive();
    _identityScopeKeys.add(identityScopeKey);
    if (_initialScripts.isEmpty) return _fallbackInitialToken;
    final scripted = _initialScripts.removeFirst();
    if (scripted case final _FlutterChatFixtureFailure failure) {
      failure.throwError();
    }
    return scripted as ChatPushToken?;
  }

  @override
  Stream<ChatPushToken> get pushTokenRotations => _rotations.stream;

  void emit(ChatPushToken token) {
    _ensureActive();
    _rotations.add(token);
  }

  void emitError(Object error, [StackTrace? stackTrace]) {
    _ensureActive();
    _rotations.addError(error, stackTrace ?? StackTrace.current);
  }

  /// Clears scripts and observations while retaining active subscriptions.
  void reset({ChatPushToken? initialToken}) {
    _ensureActive();
    _initialScripts.clear();
    _identityScopeKeys.clear();
    _fallbackInitialToken = initialToken;
    _listenCount = _activeListenerCount;
    _cancelCount = 0;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _initialScripts.clear();
    await _rotations.close();
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('The fake push-token delegate is disposed.');
    }
  }

  @override
  String toString() => 'FakeChatPushTokenDelegate('
      'initialRequestCount: $initialRequestCount, listenCount: $listenCount, '
      'cancelCount: $cancelCount, disposed: $_disposed)';
}

/// A keyed row and sequence suitable for a [ChatReadTracker] sample.
final class ChatReadVisibilitySample {
  ChatReadVisibilitySample({
    required this.sequence,
    GlobalKey? key,
  }) : key = key ?? GlobalKey();

  final GlobalKey key;
  final MessageSequence sequence;

  ChatReadTrackedItem get trackedItem =>
      ChatReadTrackedItem(key: key, sequence: sequence);

  Widget buildRow({
    Widget child = const SizedBox.expand(),
    double height = 48,
  }) =>
      SizedBox(key: key, height: height, child: child);
}

/// Deterministic read-visibility policy fixture backed by the real coordinator.
final class ChatReadVisibilityFixture {
  ChatReadVisibilityFixture({
    FakeChatClock? clock,
    this.userId = const UserId('fixture-user'),
    Duration minimumExposure = const Duration(milliseconds: 500),
  }) : clock = clock ?? FakeChatClock() {
    coordinator = ChatReadVisibilityCoordinator(
      markRead: _markRead,
      minimumExposure: minimumExposure,
      clock: this.clock.now,
      scheduler: this.clock,
      generateIdempotencyKey: _nextIdempotencyKey,
    );
  }

  final FakeChatClock clock;
  final UserId userId;
  final List<ChatMarkReadInput> _markReadInputs = <ChatMarkReadInput>[];
  late ChatReadVisibilityCoordinator coordinator;
  var _nextIdempotencySequence = 0;
  var _disposed = false;

  List<ChatMarkReadInput> get markReadInputs =>
      List<ChatMarkReadInput>.unmodifiable(_markReadInputs);
  bool get isDisposed => _disposed;

  void setEligible(
    ConversationId conversationId, {
    bool applicationForeground = true,
    bool conversationActive = true,
  }) {
    coordinator
      ..setApplicationForeground(applicationForeground)
      ..setConversationActive(
        conversationId,
        isActive: conversationActive,
      );
  }

  void report(
    ConversationId conversationId,
    MessageSequence sequence,
  ) =>
      coordinator.reportVisibleThrough(
        conversationId: conversationId,
        sequence: sequence,
      );

  void reset() {
    _ensureActive();
    coordinator.dispose();
    _markReadInputs.clear();
    _nextIdempotencySequence = 0;
    clock.reset();
    coordinator = ChatReadVisibilityCoordinator(
      markRead: _markRead,
      minimumExposure: coordinator.minimumExposure,
      failureRetryDelay: coordinator.failureRetryDelay,
      rapidScrollVelocityThreshold: coordinator.rapidScrollVelocityThreshold,
      clock: clock.now,
      scheduler: clock,
      generateIdempotencyKey: _nextIdempotencyKey,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    coordinator.dispose();
    clock.dispose();
  }

  Future<ChatCommandResult<ReadCursorMutationResult>> _markRead(
    ChatMarkReadInput input,
  ) async {
    if (_disposed) {
      return const ChatCommandClosed<ReadCursorMutationResult>();
    }
    _markReadInputs.add(input);
    return ChatCommandSuccess<ReadCursorMutationResult>(
      ReadCursorMutationResult(
        operation: ReadCursorMutationOperation.markRead,
        reconciliationStatus: ReadCursorReconciliationStatus.applied,
        idempotencyKey: input.idempotencyKey ?? 'fixture-read-result',
        conversationId: input.conversationId,
        readState: ConversationReadState(
          conversationId: input.conversationId,
          userId: userId,
          lastReadSequence: input.throughSequence,
          updatedAt: IsoTimestamp(clock.now().toIso8601String()),
        ),
        latestSequence: input.throughSequence,
        unreadCount: 0,
      ),
    );
  }

  String _nextIdempotencyKey() => 'fixture-read-${++_nextIdempotencySequence}';

  void _ensureActive() {
    if (_disposed) throw StateError('The visibility fixture is disposed.');
  }
}

/// Host application hooks that record every public delegate invocation.
final class RecordingChatApplicationDelegates {
  RecordingChatApplicationDelegates({
    this.result = ChatApplicationDelegateResult.handled,
    ChatAttachmentPickerResult? attachmentResult,
  }) : attachmentResult =
            attachmentResult ?? const ChatAttachmentPickerCancelled() {
    delegates = ChatApplicationDelegates(
      openUser: _openUser,
      openEntity: _openEntity,
      openThread: _openThread,
      pickAttachment: _pickAttachment,
      openAttachment: _openAttachment,
      reportMessage: _reportMessage,
      showNotificationSettings: _showNotificationSettings,
      openExternalLink: _openExternalLink,
      openMessageSearchHit: _openMessageSearchHit,
    );
  }

  ChatApplicationDelegateResult result;
  ChatAttachmentPickerResult attachmentResult;
  late final ChatApplicationDelegates delegates;
  final List<UserId> openedUsers = <UserId>[];
  final List<HostEntityReference> openedEntities = <HostEntityReference>[];
  final List<ConversationId> openedThreads = <ConversationId>[];
  final List<MessageAttachmentMetadata> openedAttachments =
      <MessageAttachmentMetadata>[];
  final List<MessageId> reportedMessages = <MessageId>[];
  final List<Uri> openedExternalLinks = <Uri>[];
  final List<HandrailMessageSearchHit> openedSearchHits =
      <HandrailMessageSearchHit>[];
  var attachmentPickerCallCount = 0;
  var notificationSettingsCallCount = 0;

  Future<ChatApplicationDelegateResult> _openUser(UserId userId) async {
    openedUsers.add(userId);
    return result;
  }

  Future<ChatApplicationDelegateResult> _openEntity(
    HostEntityReference entity,
  ) async {
    openedEntities.add(entity);
    return result;
  }

  Future<ChatApplicationDelegateResult> _openThread(
    ConversationId conversationId,
  ) async {
    openedThreads.add(conversationId);
    return result;
  }

  Future<ChatAttachmentPickerResult> _pickAttachment() async {
    attachmentPickerCallCount += 1;
    return attachmentResult;
  }

  Future<ChatApplicationDelegateResult> _openAttachment(
    MessageAttachmentMetadata attachment,
  ) async {
    openedAttachments.add(attachment);
    return result;
  }

  Future<ChatApplicationDelegateResult> _reportMessage(
    MessageId messageId,
  ) async {
    reportedMessages.add(messageId);
    return result;
  }

  Future<ChatApplicationDelegateResult> _showNotificationSettings() async {
    notificationSettingsCallCount += 1;
    return result;
  }

  Future<ChatApplicationDelegateResult> _openExternalLink(Uri uri) async {
    openedExternalLinks.add(uri);
    return result;
  }

  Future<ChatApplicationDelegateResult> _openMessageSearchHit(
    HandrailMessageSearchHit hit,
  ) async {
    openedSearchHits.add(hit);
    return result;
  }

  void reset({
    ChatApplicationDelegateResult? result,
    ChatAttachmentPickerResult? attachmentResult,
  }) {
    if (result != null) this.result = result;
    if (attachmentResult != null) this.attachmentResult = attachmentResult;
    openedUsers.clear();
    openedEntities.clear();
    openedThreads.clear();
    openedAttachments.clear();
    reportedMessages.clear();
    openedExternalLinks.clear();
    openedSearchHits.clear();
    attachmentPickerCallCount = 0;
    notificationSettingsCallCount = 0;
  }
}

/// Public widget builders that record each immutable rendering input.
///
/// The returned widgets are inert keyed boxes, so tests can verify invocation
/// without depending on Handrail's default Material renderers.
final class RecordingChatWidgetBuilders {
  RecordingChatWidgetBuilders() {
    builders = ChatWidgetBuilders(
      message: (context, input) {
        messages.add(input);
        return _output('message');
      },
      avatar: (context, input) {
        avatars.add(input);
        return _output('avatar');
      },
      entityReference: (context, input) {
        entityReferences.add(input);
        return _output('entity-reference');
      },
      attachmentPreview: (context, input) {
        attachmentPreviews.add(input);
        return _output('attachment-preview');
      },
      emptyConversation: (context, input) {
        emptyConversations.add(input);
        return _output('empty-conversation');
      },
      loading: (context, input) {
        loadingStates.add(input);
        return _output('loading');
      },
      error: (context, input) {
        errors.add(input);
        return _output('error');
      },
    );
  }

  late final ChatWidgetBuilders builders;
  final List<ChatMessageBuilderInput> messages = <ChatMessageBuilderInput>[];
  final List<ChatAvatarBuilderInput> avatars = <ChatAvatarBuilderInput>[];
  final List<ChatEntityReferenceBuilderInput> entityReferences =
      <ChatEntityReferenceBuilderInput>[];
  final List<ChatAttachmentPreviewBuilderInput> attachmentPreviews =
      <ChatAttachmentPreviewBuilderInput>[];
  final List<ChatEmptyConversationBuilderInput> emptyConversations =
      <ChatEmptyConversationBuilderInput>[];
  final List<ChatLoadingBuilderInput> loadingStates =
      <ChatLoadingBuilderInput>[];
  final List<ChatErrorBuilderInput> errors = <ChatErrorBuilderInput>[];

  void reset() {
    messages.clear();
    avatars.clear();
    entityReferences.clear();
    attachmentPreviews.clear();
    emptyConversations.clear();
    loadingStates.clear();
    errors.clear();
  }

  Widget _output(String name) => KeyedSubtree(
        key: ValueKey<String>('recording-chat-builder-$name'),
        child: const SizedBox.shrink(),
      );
}

/// A real client plus host-edge controls for focused Flutter widget tests.
///
/// The harness owns its client and testing edges. Unmount [buildScope] before
/// calling [dispose] so ChatScope can release its lifecycle and integration
/// subscriptions first.
final class FlutterChatWidgetHarness {
  factory FlutterChatWidgetHarness({
    Uri? apiBaseUri,
    Object? identityScopeKey = 'fixture-identity',
    String deviceId = 'fixture-device',
    ChatConnectivityStatus connectivity = ChatConnectivityStatus.offline,
    ChatPushToken? initialPushToken,
    DateTime? initialTime,
  }) {
    final resolvedApiBaseUri =
        apiBaseUri ?? Uri.parse('https://chat.example.test/api/chat');
    final accessTokens =
        ScriptedAccessTokenProvider(fallbackToken: 'fixture-access-token');
    final realtimeTokens =
        ScriptedAccessTokenProvider(fallbackToken: 'fixture-realtime-token');
    final http = ScriptedHandrailChatHttpTransport();
    final clock = FakeChatClock(initialTime);
    final storage = InMemoryApplicationChatStorage();
    final resolvedDeviceId = DeviceId(deviceId);
    var commandSequence = 0;
    final client = HandrailChatClient(
      apiBaseUri: resolvedApiBaseUri,
      tokenProvider: accessTokens.call,
      transport: http,
      localStorage: storage,
      storageIdentity: ApplicationChatStorageIdentity(
        tenantId: const TenantId('fixture-tenant'),
        userId: const UserId('fixture-user'),
        deviceId: resolvedDeviceId,
      ),
      readVisibilityClock: clock.now,
      readVisibilityScheduler: clock,
      generateIdempotencyKey: () => 'fixture-command-${++commandSequence}',
    );
    return FlutterChatWidgetHarness._(
      identityScopeKey: identityScopeKey,
      deviceId: resolvedDeviceId,
      client: client,
      accessTokens: accessTokens,
      realtimeTokens: realtimeTokens,
      http: http,
      clock: clock,
      storage: storage,
      connectivity: FakeChatConnectivityDelegate(current: connectivity),
      deviceIdentity:
          FakeChatDeviceIdentityDelegate(fallbackDeviceId: deviceId),
      pushTokens: FakeChatPushTokenDelegate(initialToken: initialPushToken),
    );
  }

  FlutterChatWidgetHarness._({
    required this.identityScopeKey,
    required this.deviceId,
    required this.client,
    required this.accessTokens,
    required this.realtimeTokens,
    required this.http,
    required this.clock,
    required this.storage,
    required this.connectivity,
    required this.deviceIdentity,
    required this.pushTokens,
  });

  final Object? identityScopeKey;
  final DeviceId deviceId;
  final HandrailChatClient client;
  final ScriptedAccessTokenProvider accessTokens;
  final ScriptedAccessTokenProvider realtimeTokens;
  final ScriptedHandrailChatHttpTransport http;
  final FakeChatClock clock;
  final InMemoryApplicationChatStorage storage;
  final FakeChatConnectivityDelegate connectivity;
  final FakeChatDeviceIdentityDelegate deviceIdentity;
  final FakeChatPushTokenDelegate pushTokens;
  final FakeChatRealtimeSocketFactory realtimeSockets =
      FakeChatRealtimeSocketFactory();
  final List<ChatScopeIntegrationDiagnostic> integrationDiagnostics =
      <ChatScopeIntegrationDiagnostic>[];
  final List<ChatRealtimeSessionTransport> realtimeSessions =
      <ChatRealtimeSessionTransport>[];
  var _disposed = false;

  bool get isDisposed => _disposed;

  Widget buildScope({
    required Widget child,
    Key? key,
    bool withApplicationBindings = true,
  }) =>
      ChatScope(
        key: key,
        client: client,
        connectivityDelegate: withApplicationBindings ? connectivity : null,
        deviceIdentityDelegate: withApplicationBindings ? deviceIdentity : null,
        identityScopeKey: identityScopeKey,
        realtimeSessionFactory:
            withApplicationBindings ? _createRealtimeSession : null,
        pushTokenDelegate: withApplicationBindings ? pushTokens : null,
        onIntegrationDiagnostic: integrationDiagnostics.add,
        child: child,
      );

  Widget buildHost({
    required Widget child,
    TextDirection textDirection = TextDirection.ltr,
  }) =>
      Directionality(textDirection: textDirection, child: child);

  Widget buildApp({
    required Widget child,
    Key? scopeKey,
    bool withApplicationBindings = true,
  }) =>
      buildHost(
        child: buildScope(
          key: scopeKey,
          withApplicationBindings: withApplicationBindings,
          child: child,
        ),
      );

  void enqueueReadyMetadata({
    Map<String, bool> enabledFeatures = const <String, bool>{
      'realtime': true,
    },
  }) {
    http.enqueueJson(<String, Object?>{
      'packageVersion': '0.1.3',
      'protocolVersion': handrailChatProtocolVersion,
      'schemaVersion': 7,
      'enabledFeatures': enabledFeatures,
      'supportedProtocolRange': <String, int>{
        'minimumVersion': handrailChatProtocolVersion - 1,
        'maximumVersion': handrailChatProtocolVersion,
      },
    });
  }

  void enqueueTimeline({
    required ConversationId conversationId,
    Iterable<MessageTimelineMessage> messages =
        const <MessageTimelineMessage>[],
    MessageSequence? olderCursor,
    MessageSequence? newerCursor,
    String resumeEventId = 'fixture-timeline-event',
  }) {
    http.enqueueJson(<String, Object?>{
      'conversationId': conversationId.toJson(),
      'messages': messages.map((message) => message.toJson()).toList(),
      'pagination': <String, Object?>{
        'older': olderCursor == null
            ? const <String, Object?>{'available': false}
            : <String, Object?>{
                'available': true,
                'cursor': olderCursor.toJson(),
              },
        'newer': newerCursor == null
            ? const <String, Object?>{'available': false}
            : <String, Object?>{
                'available': true,
                'cursor': newerCursor.toJson(),
              },
      },
      'replay': <String, Object?>{
        'resumeFrom': <String, Object?>{'eventId': resumeEventId},
      },
    });
  }

  void enqueuePushTokenSuccess({
    DevicePushTokenOperation operation = DevicePushTokenOperation.register,
    String idempotencyKey = 'fixture-command-1',
    int tokenRevision = 1,
    DevicePlatform platform = DevicePlatform.ios,
    DevicePushProvider provider = DevicePushProvider.apns,
    DevicePushProviderEnvironment environment =
        DevicePushProviderEnvironment.sandbox,
  }) {
    http.enqueueJson(<String, Object?>{
      'operation': operation.toJson(),
      'reconciliationStatus': 'applied',
      'idempotencyKey': idempotencyKey,
      'devicePushToken': <String, Object?>{
        'deviceId': deviceId.toJson(),
        'status': operation == DevicePushTokenOperation.unregister
            ? 'unregistered'
            : 'active',
        'platform': platform.toJson(),
        'provider': provider.toJson(),
        'environment': environment.toJson(),
        'tokenRevision': tokenRevision,
        'updatedAt': clock.now().toIso8601String(),
      },
    });
  }

  FakeChatRealtimeSocket enqueueRealtimeSocket() {
    final socket = FakeChatRealtimeSocket();
    realtimeSockets.enqueueSocket(socket);
    return socket;
  }

  Future<ChatClientLifecycleState> initializeClient() => client.initialize();

  /// Emits a lifecycle event through the binding observed by ChatScope.
  void emitApplicationLifecycleState(AppLifecycleState state) {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
  }

  /// Uses Flutter's valid synthesized transition order for foreground changes.
  void setApplicationForeground(bool foreground) {
    final current = WidgetsBinding.instance.lifecycleState;
    if (foreground) {
      switch (current) {
        case null:
        case AppLifecycleState.detached:
        case AppLifecycleState.inactive:
          emitApplicationLifecycleState(AppLifecycleState.resumed);
        case AppLifecycleState.hidden:
          emitApplicationLifecycleState(AppLifecycleState.inactive);
          emitApplicationLifecycleState(AppLifecycleState.resumed);
        case AppLifecycleState.paused:
          emitApplicationLifecycleState(AppLifecycleState.hidden);
          emitApplicationLifecycleState(AppLifecycleState.inactive);
          emitApplicationLifecycleState(AppLifecycleState.resumed);
        case AppLifecycleState.resumed:
          break;
      }
      return;
    }

    switch (current) {
      case null:
        emitApplicationLifecycleState(AppLifecycleState.paused);
      case AppLifecycleState.resumed:
        emitApplicationLifecycleState(AppLifecycleState.inactive);
        emitApplicationLifecycleState(AppLifecycleState.hidden);
        emitApplicationLifecycleState(AppLifecycleState.paused);
      case AppLifecycleState.inactive:
        emitApplicationLifecycleState(AppLifecycleState.hidden);
        emitApplicationLifecycleState(AppLifecycleState.paused);
      case AppLifecycleState.hidden:
        emitApplicationLifecycleState(AppLifecycleState.paused);
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.detached:
        emitApplicationLifecycleState(AppLifecycleState.resumed);
        setApplicationForeground(false);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await client.dispose();
    await connectivity.dispose();
    await pushTokens.dispose();
    clock.dispose();
    http.dispose();
    accessTokens.reset();
    realtimeTokens.reset();
    realtimeSockets.reset();
  }

  ChatRealtimeSessionTransport _createRealtimeSession(
    ChatScopeRealtimeSessionConfig config,
  ) {
    final session = ChatRealtimeSessionTransport(
      endpoint: config.client.apiBaseUri,
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: realtimeTokens.call,
      socketFactory: realtimeSockets.call,
      network: config.network,
      clock: clock,
      random: () => 0.5,
    );
    realtimeSessions.add(session);
    return session;
  }
}

final class _FlutterChatFixtureFailure {
  const _FlutterChatFixtureFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  Never throwError() => Error.throwWithStackTrace(error, stackTrace);
}
