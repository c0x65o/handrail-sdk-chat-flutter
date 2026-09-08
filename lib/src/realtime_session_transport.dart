import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'core/normalized_snapshot_state.dart';
import 'generated/durable_events.dart';
import 'generated/ephemeral_signals.dart';
import 'generated/identifiers.dart';
import 'generated/realtime_handshake.dart';
import 'generated/realtime_session.dart';

/// Resolves a fresh access token immediately before a socket is opened.
typedef ChatRealtimeAccessTokenProvider = FutureOr<String> Function();

/// Opens a socket using the ordered WebSocket subprotocols supplied by the
/// session. The returned socket is considered open and ready to send.
typedef ChatRealtimeSocketFactory = FutureOr<ChatRealtimeSocket> Function(
  Uri uri,
  List<String> protocols,
);

/// Receives stable, credential-safe runtime diagnostics.
typedef ChatRealtimeDiagnosticListener = void Function(
  ChatRealtimeDiagnostic diagnostic,
);

/// Atomically applies one trusted, strictly parsed durable event.
typedef ChatRealtimeDurableEventReducer = FutureOr<DurableEventReduction>
    Function(KnownDurableEvent event);

/// Settles one canonical event after reduction and before cursor persistence.
typedef ChatRealtimeCanonicalEventListener = FutureOr<void> Function(
  KnownDurableEvent event,
);

/// Releases a client-owned durable-state binding.
typedef ChatRealtimeDurableStateBindingRelease = void Function();

/// Releases one retained conversation subscription.
typedef ChatRealtimeConversationSubscriptionRelease = void Function();

/// Receives immutable conversation subscription state changes.
typedef ChatRealtimeConversationSubscriptionListener = void Function(
  ChatRealtimeConversationSubscriptionState state,
);

/// Receives the trusted identity whose accepted realtime session disconnected.
///
/// This is the lifecycle hook for session-scoped transient state cleanup. It
/// does not move feature-event reduction into the transport.
typedef ChatRealtimeEphemeralSessionDisconnectListener = void Function(
  TenantId tenantId,
  SessionId sessionId,
);

/// Rebuilds application state after the server can no longer replay a cursor.
typedef ChatRealtimeSnapshotHydrator = FutureOr<EventCursor?> Function(
  ChatRealtimeSnapshotHydrationInput input,
);

/// A connected, framework-neutral WebSocket boundary.
///
/// Text frames are emitted as [String] values. Any other value is treated as
/// an invalid server frame. Stream errors and completion both represent a lost
/// connection.
abstract interface class ChatRealtimeSocket {
  Stream<Object?> get frames;

  FutureOr<void> send(String data);

  FutureOr<void> close();
}

/// Provides current connectivity and subsequent online/offline changes.
abstract interface class ChatRealtimeNetwork {
  bool get isOnline;

  Stream<bool> get changes;
}

/// Maximum UTF-8 size of a host-defined replay-cursor identity scope.
const int maxChatRealtimeCursorStorageScopeUtf8Bytes = 256;

/// Opportunistic storage for the last server-accepted replay cursor.
///
/// Implementations must isolate every operation by [scope]. A scope is a
/// stable, non-secret identifier supplied by the trusted host account/device
/// boundary before the socket starts. It must never contain an access token,
/// credential, or another secret.
abstract interface class ChatRealtimeCursorStorage {
  FutureOr<String?> read({required String scope});

  FutureOr<void> write({required String scope, required String value});

  FutureOr<void> clear({required String scope});
}

/// A cancellable timer returned by [ChatRealtimeClock].
abstract interface class ChatRealtimeTimer {
  void cancel();
}

/// Injectable timer boundary used by reconnect scheduling.
abstract interface class ChatRealtimeClock {
  ChatRealtimeTimer schedule(Duration delay, void Function() callback);
}

/// Injectable wall clock and timer boundary for ephemeral realtime signals.
abstract interface class ChatRealtimeEphemeralClock {
  DateTime now();

  ChatRealtimeTimer schedule(Duration delay, void Function() callback);
}

/// Pure-Dart foreground boundary used to suspend private activity signals.
abstract interface class ChatRealtimeVisibility {
  bool get isVisible;

  void addListener(void Function() listener);

  void removeListener(void Function() listener);
}

/// Privacy classification authorized by the host for one conversation.
enum ChatRealtimeConversationVisibility {
  publicConversation('public'),
  privateConversation('private');

  const ChatRealtimeConversationVisibility(this.wireValue);

  final String wireValue;
}

/// Resolves the trusted visibility for a conversation and requested scope.
///
/// Returning `null` suppresses the typing signal. The transport also suppresses
/// a result that differs from a non-null requested visibility.
typedef ChatRealtimeConversationVisibilityResolver
    = ChatRealtimeConversationVisibility? Function(
  ConversationId conversationId,
  ChatRealtimeConversationVisibility? requestedVisibility,
);

/// Local privacy, timing, and rate controls for outbound ephemeral signals.
final class ChatRealtimeEphemeralSignalOptions {
  const ChatRealtimeEphemeralSignalOptions({
    this.clock,
    this.visibility,
    this.conversationVisibilityResolver,
    this.typingEnabled = true,
    this.presenceEnabled = true,
    this.typingTtl = const Duration(seconds: 10),
    this.typingHeartbeat = const Duration(seconds: 5),
    this.typingIdle = const Duration(seconds: 5),
    this.presenceTtl = const Duration(seconds: 60),
    this.presenceHeartbeat = const Duration(seconds: 30),
    this.presenceIdle = const Duration(seconds: 60),
    this.rateLimitMaxSignals = 10,
    this.rateLimitWindow = const Duration(seconds: 1),
  });

  final ChatRealtimeEphemeralClock? clock;
  final ChatRealtimeVisibility? visibility;
  final ChatRealtimeConversationVisibilityResolver?
      conversationVisibilityResolver;
  final bool typingEnabled;
  final bool presenceEnabled;
  final Duration typingTtl;
  final Duration typingHeartbeat;
  final Duration typingIdle;
  final Duration presenceTtl;
  final Duration presenceHeartbeat;
  final Duration presenceIdle;
  final int rateLimitMaxSignals;
  final Duration rateLimitWindow;
}

/// Bounded exponential reconnect configuration.
final class ChatRealtimeRetryOptions {
  const ChatRealtimeRetryOptions({
    this.initialDelay = const Duration(seconds: 1),
    this.maximumDelay = const Duration(seconds: 30),
    this.multiplier = 2,
    this.jitterRatio = 0.2,
  });

  final Duration initialDelay;
  final Duration maximumDelay;
  final double multiplier;
  final double jitterRatio;
}

/// Stable codes emitted by [ChatRealtimeSessionTransport].
abstract final class ChatRealtimeDiagnosticCode {
  static const String accessTokenFailed = 'access_token_failed';
  static const String socketConnectionFailed = 'socket_connection_failed';
  static const String connectionLost = 'connection_lost';
  static const String malformedServerFrame = 'malformed_server_frame';
  static const String snapshotHydrationFailed = 'snapshot_hydration_failed';
  static const String durableEventRecovery = 'durable_event_recovery';
}

/// An immutable diagnostic that never includes thrown values or wire data.
final class ChatRealtimeDiagnostic {
  const ChatRealtimeDiagnostic({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'ChatRealtimeDiagnostic(code: $code, message: $message)';
}

/// Server and durable-reducer reasons that require authoritative hydration.
enum ChatRealtimeSnapshotRecoveryReason {
  replayExpired('replay_expired'),
  replayUnavailable('replay_unavailable'),
  replayIncompatible('replay_incompatible'),
  replayOverflow('replay_overflow'),
  eventGap('event_gap'),
  eventIncompatible('event_incompatible'),
  eventInvalid('event_invalid');

  const ChatRealtimeSnapshotRecoveryReason(this.wireValue);

  factory ChatRealtimeSnapshotRecoveryReason.fromSnapshotRequired(
    SnapshotRequiredReason reason,
  ) =>
      switch (reason) {
        SnapshotRequiredReason.replayExpired => replayExpired,
        SnapshotRequiredReason.replayUnavailable => replayUnavailable,
        SnapshotRequiredReason.replayIncompatible => replayIncompatible,
        SnapshotRequiredReason.replayOverflow => replayOverflow,
      };

  factory ChatRealtimeSnapshotRecoveryReason.fromDurable(
    DurableEventRecoveryReason reason,
  ) =>
      switch (reason) {
        DurableEventRecoveryReason.eventGap => eventGap,
        DurableEventRecoveryReason.eventIncompatible => eventIncompatible,
        DurableEventRecoveryReason.eventInvalid => eventInvalid,
      };

  final String wireValue;
}

/// Input supplied to the coalesced authoritative snapshot recovery.
final class ChatRealtimeSnapshotHydrationInput {
  const ChatRealtimeSnapshotHydrationInput({
    required this.reason,
    required this.expiredCursor,
    required List<ConversationId> retainedConversationIds,
    List<ConversationId> Function()? currentRetainedConversationIds,
    this.diagnostic,
    bool Function()? isCancelled,
  })  : _retainedConversationIds = retainedConversationIds,
        _currentRetainedConversationIds = currentRetainedConversationIds,
        _isCancelled = isCancelled;

  final ChatRealtimeSnapshotRecoveryReason reason;
  final EventCursor expiredCursor;
  final List<ConversationId> _retainedConversationIds;
  final List<ConversationId> Function()? _currentRetainedConversationIds;

  /// Re-read during hydration so a newly opened thread joins this recovery.
  List<ConversationId> get retainedConversationIds =>
      _currentRetainedConversationIds?.call() ?? _retainedConversationIds;
  final DurableEventDiagnostic? diagnostic;
  final bool Function()? _isCancelled;

  /// Whether lifecycle authority was lost while hydration was in flight.
  bool get isCancelled => _isCancelled?.call() ?? false;

  @override
  String toString() =>
      'ChatRealtimeSnapshotHydrationInput(reason: ${reason.wireValue})';
}

/// Immutable lifecycle state exposed by the standalone realtime transport.
sealed class ChatRealtimeLifecycleState {
  const ChatRealtimeLifecycleState();

  String get state;

  @override
  String toString() => '$runtimeType(state: $state)';
}

final class ChatRealtimeIdleState extends ChatRealtimeLifecycleState {
  const ChatRealtimeIdleState();

  @override
  String get state => 'idle';
}

final class ChatRealtimeConnectingState extends ChatRealtimeLifecycleState {
  const ChatRealtimeConnectingState();

  @override
  String get state => 'connecting';
}

/// Tenant/user/device identity proven by an accepted realtime handshake.
final class ChatRealtimeAcceptedIdentity {
  const ChatRealtimeAcceptedIdentity({
    required this.tenantId,
    required this.userId,
    required this.deviceId,
  });

  factory ChatRealtimeAcceptedIdentity.fromMessage(
    ChatRealtimeSessionAcceptedMessage message,
  ) =>
      ChatRealtimeAcceptedIdentity(
        tenantId: message.tenantId,
        userId: UserId(message.actorStreamId.substring('user:'.length)),
        deviceId: message.deviceId,
      );

  final TenantId tenantId;
  final UserId userId;
  final DeviceId deviceId;
}

final class ChatRealtimeConnectedState extends ChatRealtimeLifecycleState {
  const ChatRealtimeConnectedState({
    required this.metadata,
    required this.identity,
  });

  @override
  String get state => 'connected';

  final ServerHandshakeMetadata metadata;
  final ChatRealtimeAcceptedIdentity identity;
}

final class ChatRealtimeReconnectingState extends ChatRealtimeLifecycleState {
  const ChatRealtimeReconnectingState({
    required this.attempt,
    required this.delay,
    required this.diagnostic,
  });

  @override
  String get state => 'reconnecting';

  final int attempt;
  final Duration delay;
  final ChatRealtimeDiagnostic diagnostic;

  @override
  String toString() => 'ChatRealtimeReconnectingState('
      'state: $state, attempt: $attempt, delayMs: ${delay.inMilliseconds}, '
      'diagnostic: $diagnostic)';
}

final class ChatRealtimeOfflineState extends ChatRealtimeLifecycleState {
  const ChatRealtimeOfflineState();

  @override
  String get state => 'offline';
}

final class ChatRealtimeHydratingSnapshotState
    extends ChatRealtimeLifecycleState {
  const ChatRealtimeHydratingSnapshotState({
    required this.reason,
    this.diagnostic,
  });

  @override
  String get state => 'hydratingSnapshot';

  final ChatRealtimeSnapshotRecoveryReason reason;
  final DurableEventDiagnostic? diagnostic;

  @override
  String toString() => 'ChatRealtimeHydratingSnapshotState('
      'state: $state, reason: ${reason.wireValue})';
}

final class ChatRealtimeRefreshRequiredState
    extends ChatRealtimeLifecycleState {
  const ChatRealtimeRefreshRequiredState({
    required this.requestedProtocolVersion,
    required this.metadata,
  });

  @override
  String get state => 'refreshRequired';

  String get reason => 'unsupported_protocol';
  String get message => chatRefreshRequiredMessage;
  final int requestedProtocolVersion;
  final ServerHandshakeMetadata metadata;
}

/// The wire operation awaiting acknowledgement for a conversation stream.
enum ChatRealtimeConversationSubscriptionOperation {
  subscribe,
  unsubscribe,
}

/// Immutable state for one caller-retained conversation subscription.
sealed class ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionState({
    required this.conversationId,
  });

  final ConversationId conversationId;
  String get state;

  @override
  String toString() => '$runtimeType('
      'conversationId: ${conversationId.value}, state: $state)';
}

/// A subscribe or unsubscribe operation is waiting for the current server.
final class ChatRealtimeConversationSubscriptionPendingState
    extends ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionPendingState({
    required super.conversationId,
    required this.operation,
    this.requestId,
  });

  @override
  String get state => 'pending';

  final ChatRealtimeConversationSubscriptionOperation operation;
  final String? requestId;
}

/// The current server accepted the conversation subscription.
final class ChatRealtimeConversationSubscriptionAcceptedState
    extends ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionAcceptedState({
    required super.conversationId,
    required this.requestId,
  });

  @override
  String get state => 'accepted';

  final String requestId;
}

/// The conversation subscription was removed or released before being sent.
final class ChatRealtimeConversationSubscriptionRemovedState
    extends ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionRemovedState({
    required super.conversationId,
    this.requestId,
  });

  @override
  String get state => 'removed';

  final String? requestId;
}

/// The current subscription operation was rejected by the server.
final class ChatRealtimeConversationSubscriptionRejectedState
    extends ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionRejectedState({
    required super.conversationId,
    required this.requestId,
    required this.code,
  });

  @override
  String get state => code.wireValue;

  final String requestId;
  final ChatRealtimeSubscriptionErrorCode code;
}

/// Access to an accepted conversation subscription was revoked by the server.
final class ChatRealtimeConversationSubscriptionRevokedState
    extends ChatRealtimeConversationSubscriptionState {
  const ChatRealtimeConversationSubscriptionRevokedState({
    required super.conversationId,
  });

  @override
  String get state => code.wireValue;

  ChatRealtimeSubscriptionErrorCode get code =>
      ChatRealtimeSubscriptionErrorCode.accessRevoked;
}

const ChatRealtimeDiagnostic _accessTokenDiagnostic = ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.accessTokenFailed,
  message: 'Chat realtime credentials could not be obtained.',
);
const ChatRealtimeDiagnostic _socketDiagnostic = ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.socketConnectionFailed,
  message: 'The chat realtime connection could not be opened.',
);
const ChatRealtimeDiagnostic _connectionLostDiagnostic = ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.connectionLost,
  message: 'The chat realtime connection was interrupted.',
);
const ChatRealtimeDiagnostic _malformedFrameDiagnostic = ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.malformedServerFrame,
  message: 'The chat server sent an invalid realtime frame.',
);
const ChatRealtimeDiagnostic _snapshotDiagnostic = ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.snapshotHydrationFailed,
  message: 'The chat snapshot could not be hydrated.',
);
const ChatRealtimeDiagnostic _durableRecoveryDiagnostic =
    ChatRealtimeDiagnostic(
  code: ChatRealtimeDiagnosticCode.durableEventRecovery,
  message: 'Chat state requires snapshot recovery before realtime can resume.',
);

/// An injectable, pure-Dart realtime WebSocket reliability runtime.
///
/// This class owns connection, handshake, replay-cursor, recovery, durable
/// frame routing, and reference-counted conversation subscriptions. Canonical
/// state ownership remains injectable so the transport stays pure Dart.
final class ChatRealtimeSessionTransport {
  ChatRealtimeSessionTransport({
    required this.endpoint,
    required this.clientPackageVersion,
    required this.protocolVersion,
    required this.tokenProvider,
    required this.socketFactory,
    ChatRealtimeNetwork? network,
    this.cursorStorage,
    String? cursorStorageScope,
    ChatRealtimeClock? clock,
    double Function()? random,
    this.retry = const ChatRealtimeRetryOptions(),
    this.ephemeralSignals = const ChatRealtimeEphemeralSignalOptions(),
    this.hydrateSnapshot,
    this.onCanonicalEvent,
    this.onDiagnostic,
    this.onStateChange,
    this.onConversationSubscriptionStateChange,
    this.onEphemeralSessionDisconnected,
  })  : cursorStorageScope = cursorStorageScope == null
            ? null
            : _validatedCursorStorageScope(cursorStorageScope),
        network = network ?? const _AlwaysOnlineNetwork(),
        clock = clock ?? const _SystemChatRealtimeClock(),
        random = random ?? math.Random().nextDouble,
        webSocketUri = _createWebSocketUri(endpoint) {
    if (clientPackageVersion.trim().isEmpty) {
      throw ArgumentError.value(
        clientPackageVersion,
        'clientPackageVersion',
        'must not be empty',
      );
    }
    if (protocolVersion < 1) {
      throw ArgumentError.value(
        protocolVersion,
        'protocolVersion',
        'must be positive',
      );
    }
    if (cursorStorage != null && this.cursorStorageScope == null) {
      throw ArgumentError(
        'cursorStorageScope is required when cursorStorage is configured.',
      );
    }
    _validateRetryOptions(retry);
    _validateEphemeralSignalOptions(ephemeralSignals);
    _states = _createStateStream();
  }

  final Uri endpoint;
  final Uri webSocketUri;
  final String clientPackageVersion;
  final int protocolVersion;
  final ChatRealtimeAccessTokenProvider tokenProvider;
  final ChatRealtimeSocketFactory socketFactory;
  final ChatRealtimeNetwork network;
  final ChatRealtimeCursorStorage? cursorStorage;

  /// Stable host account/device scope used for every persistent cursor access.
  ///
  /// This is required when [cursorStorage] is configured and must be known
  /// before [start]. It must not be derived from token contents or from the
  /// identity reported by an unaccepted socket.
  final String? cursorStorageScope;
  final ChatRealtimeClock clock;
  final double Function() random;
  final ChatRealtimeRetryOptions retry;
  final ChatRealtimeEphemeralSignalOptions ephemeralSignals;
  final ChatRealtimeSnapshotHydrator? hydrateSnapshot;
  final ChatRealtimeCanonicalEventListener? onCanonicalEvent;
  final ChatRealtimeDiagnosticListener? onDiagnostic;
  final void Function(ChatRealtimeLifecycleState state)? onStateChange;
  final ChatRealtimeConversationSubscriptionListener?
      onConversationSubscriptionStateChange;
  final ChatRealtimeEphemeralSessionDisconnectListener?
      onEphemeralSessionDisconnected;

  final StreamController<ChatRealtimeLifecycleState> _stateChanges =
      StreamController<ChatRealtimeLifecycleState>.broadcast(sync: true);
  final StreamController<ChatRealtimeConversationSubscriptionState>
      _conversationSubscriptionStateChanges =
      StreamController<ChatRealtimeConversationSubscriptionState>.broadcast(
    sync: true,
  );
  late final Stream<ChatRealtimeLifecycleState> _states;
  final StreamController<KnownDurableEvent> _canonicalEventChanges =
      StreamController<KnownDurableEvent>.broadcast(sync: true);
  final Map<String, _ConversationSubscription> _conversationSubscriptions =
      <String, _ConversationSubscription>{};
  final Map<String, ChatRealtimeConversationSubscriptionState>
      _latestConversationSubscriptionStates =
      <String, ChatRealtimeConversationSubscriptionState>{};
  final Map<String, _SubscriptionOperationContext> _subscriptionOperations =
      <String, _SubscriptionOperationContext>{};
  late final _ChatRealtimeEphemeralSignalEngine _ephemeralSignalEngine =
      _ChatRealtimeEphemeralSignalEngine(
    options: ephemeralSignals,
    send: _sendEphemeralSignal,
    onSessionDisconnected: onEphemeralSessionDisconnected,
  );
  ChatRealtimeLifecycleState _state = const ChatRealtimeIdleState();
  StreamSubscription<bool>? _networkSubscription;
  StreamSubscription<Object?>? _socketSubscription;
  ChatRealtimeSocket? _socket;
  ChatRealtimeTimer? _retryTimer;
  EventCursor? _cursor;
  Future<void>? _startOperation;
  Future<void>? _recoveryOperation;
  Future<void> _frameProcessing = Future<void>.value();
  Future<void> _cursorStorageOperations = Future<void>.value();
  var _cursorStorageSequence = 0;
  _ChatRealtimeDurableStateBinding? _durableStateBinding;
  var _generation = 0;
  var _lifecycleEpoch = 0;
  var _retryAttempt = 0;
  var _subscriptionRequestSequence = 0;
  var _subscriptionEpochSequence = 0;
  int? _acceptedGeneration;
  String? _actorStreamId;
  var _started = false;
  var _disposed = false;
  var _cursorLoaded = false;

  ChatRealtimeLifecycleState get state => _state;

  /// A broadcast stream that gives each listener the current state first.
  Stream<ChatRealtimeLifecycleState> get states => _states;

  /// Broadcast events that completed strict parsing, atomic reduction,
  /// canonical settling, and required cursor persistence.
  Stream<KnownDurableEvent> get canonicalEvents =>
      _canonicalEventChanges.stream;

  /// Broadcast subscription state events for caller-retained conversations.
  Stream<ChatRealtimeConversationSubscriptionState>
      get conversationSubscriptionStates =>
          _conversationSubscriptionStateChanges.stream;

  /// The latest immutable state for each conversation observed by this session.
  Map<String, ChatRealtimeConversationSubscriptionState>
      get conversationSubscriptionStatesById =>
          Map<String, ChatRealtimeConversationSubscriptionState>.unmodifiable(
            _latestConversationSubscriptionStates,
          );

  bool get isStarted => _started;
  bool get isDisposed => _disposed;

  /// Attaches the client-owned reducer and authorized snapshot hydrator.
  ///
  /// A second active binding is rejected. Releasing a stale binding is
  /// harmless and never removes a newer binding.
  ChatRealtimeDurableStateBindingRelease bindDurableState({
    required ChatRealtimeDurableEventReducer reduceDurableEvent,
    required ChatRealtimeSnapshotHydrator hydrateSnapshot,
  }) {
    if (_disposed) {
      throw StateError('The chat realtime session has been disposed.');
    }
    if (_durableStateBinding != null) {
      throw StateError('The chat realtime durable state is already bound.');
    }
    final binding = _ChatRealtimeDurableStateBinding(
      reduceDurableEvent: reduceDurableEvent,
      hydrateSnapshot: hydrateSnapshot,
    );
    _durableStateBinding = binding;
    return () {
      if (identical(_durableStateBinding, binding)) {
        _durableStateBinding = null;
      }
    };
  }

  /// Starts or refreshes this actor's typing signal for a conversation.
  ///
  /// Returns `false` unless the current socket is accepted, typing is enabled
  /// both locally and by the server, the application is visible, the host
  /// authorizes the conversation, and the rate limit permits the first frame.
  bool startTyping(
    ConversationId conversationId, {
    ChatRealtimeConversationVisibility? visibility,
  }) {
    if (_disposed) return false;
    return _ephemeralSignalEngine.startTyping(
      _validatedConversationId(conversationId),
      visibility,
    );
  }

  /// Sends a terminal typing stop for an active conversation.
  void stopTyping(ConversationId conversationId) {
    if (_disposed) return;
    _ephemeralSignalEngine.stopTyping(_validatedConversationId(conversationId));
  }

  /// Updates the desired presence state for this reusable session.
  void setPresence(PresenceSignalState state) {
    if (_disposed) return;
    _ephemeralSignalEngine.setPresence(state);
  }

  /// Reports user activity, recovering idle-away presence when appropriate.
  void notifyActivity() {
    if (_disposed) return;
    _ephemeralSignalEngine.notifyActivity();
  }

  /// Retains a conversation stream and returns an idempotent release callback.
  ///
  /// The caller supplies only a typed conversation identifier. Tenant, actor,
  /// device, and session identity are always derived from session acceptance.
  ChatRealtimeConversationSubscriptionRelease subscribeConversation(
    ConversationId conversationId,
  ) {
    if (_disposed) {
      throw StateError('The chat realtime session has been disposed.');
    }
    final canonicalId = _validatedConversationId(conversationId);
    final streamId = canonicalId.value;
    final existing = _conversationSubscriptions[streamId];
    if (existing == null) {
      final subscription = _ConversationSubscription(
        conversationId: canonicalId,
        retainCount: 1,
        epoch: ++_subscriptionEpochSequence,
      );
      _conversationSubscriptions[streamId] = subscription;
      _emitConversationSubscriptionState(
        ChatRealtimeConversationSubscriptionPendingState(
          conversationId: canonicalId,
          operation: ChatRealtimeConversationSubscriptionOperation.subscribe,
        ),
      );
      _sendConversationSubscription(
        subscription,
        ChatRealtimeConversationSubscriptionOperation.subscribe,
      );
    } else if (existing.retainCount == 0) {
      existing
        ..retainCount = 1
        ..epoch = ++_subscriptionEpochSequence;
      _emitConversationSubscriptionState(
        ChatRealtimeConversationSubscriptionPendingState(
          conversationId: existing.conversationId,
          operation: ChatRealtimeConversationSubscriptionOperation.subscribe,
        ),
      );
      _sendConversationSubscription(
        existing,
        ChatRealtimeConversationSubscriptionOperation.subscribe,
      );
    } else {
      existing.retainCount += 1;
    }

    var active = true;
    return () {
      if (!active) return;
      active = false;
      final subscription = _conversationSubscriptions[streamId];
      if (subscription == null || subscription.retainCount == 0) return;
      if (subscription.retainCount > 1) {
        subscription.retainCount -= 1;
        return;
      }

      subscription
        ..retainCount = 0
        ..epoch = ++_subscriptionEpochSequence;
      if (_canSendSubscriptions) {
        _sendConversationSubscription(
          subscription,
          ChatRealtimeConversationSubscriptionOperation.unsubscribe,
        );
      } else {
        _conversationSubscriptions.remove(streamId);
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRemovedState(
            conversationId: subscription.conversationId,
          ),
        );
      }
    };
  }

  /// Releases every retained reference for a conversation after access loss.
  ///
  /// Previously returned release callbacks become harmless. A connected
  /// session sends one unsubscribe request; an offline or idle session removes
  /// the desired subscription immediately so it cannot replay on reconnect.
  void clearConversationSubscription(ConversationId conversationId) {
    if (_disposed) return;
    final canonicalId = _validatedConversationId(conversationId);
    final streamId = canonicalId.value;
    final subscription = _conversationSubscriptions[streamId];
    _subscriptionOperations.removeWhere(
      (_, operation) =>
          !operation.isActorStream && operation.streamId == streamId,
    );
    if (subscription == null) {
      if (_latestConversationSubscriptionStates.containsKey(streamId)) {
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRemovedState(
            conversationId: canonicalId,
          ),
        );
      }
      return;
    }
    subscription
      ..retainCount = 0
      ..epoch = ++_subscriptionEpochSequence;
    if (_canSendSubscriptions) {
      _sendConversationSubscription(
        subscription,
        ChatRealtimeConversationSubscriptionOperation.unsubscribe,
      );
    } else {
      _conversationSubscriptions.remove(streamId);
      _emitConversationSubscriptionState(
        ChatRealtimeConversationSubscriptionRemovedState(
          conversationId: canonicalId,
        ),
      );
    }
  }

  /// Loads the last valid cursor and begins connecting when online.
  Future<void> start() {
    if (_disposed) {
      throw StateError('The chat realtime session has been disposed.');
    }
    if (_started) return _startOperation ?? Future<void>.value();

    _started = true;
    final epoch = ++_lifecycleEpoch;
    _attachNetworkListener();
    final operation = _start(epoch);
    _startOperation = operation;
    return operation;
  }

  Future<void> _start(int epoch) async {
    await _loadCursor(epoch);
    if (!_started || _disposed || epoch != _lifecycleEpoch) return;
    if (!network.isOnline) {
      _emit(const ChatRealtimeOfflineState());
      return;
    }
    await _connect();
  }

  /// Resumes this reusable session from its last persisted replay cursor.
  ///
  /// The returned future settles only after the server accepts the session, or
  /// with `false` when this lifecycle attempt is superseded by suspension,
  /// disposal, or a refresh-required response. Snapshot recovery and reconnect
  /// attempts remain owned by the transport and therefore settle before a
  /// successful result.
  Future<bool> resumeFromCursor() async {
    if (_disposed) return false;
    await start();
    if (_disposed || !_started) return false;
    if (_state is ChatRealtimeConnectedState) return true;
    if (_state is ChatRealtimeRefreshRequiredState) return false;

    final epoch = _lifecycleEpoch;
    final settled = Completer<bool>();
    late final StreamSubscription<ChatRealtimeLifecycleState> subscription;
    subscription = states.listen(
      (state) {
        if (settled.isCompleted) return;
        if (_disposed || !_started || epoch != _lifecycleEpoch) {
          settled.complete(false);
        } else if (state is ChatRealtimeConnectedState) {
          settled.complete(true);
        } else if (state is ChatRealtimeRefreshRequiredState ||
            state is ChatRealtimeIdleState) {
          settled.complete(false);
        }
      },
      onDone: () {
        if (!settled.isCompleted) settled.complete(false);
      },
    );
    try {
      return await settled.future;
    } finally {
      await subscription.cancel();
    }
  }

  /// Suspends socket, reconnect, recovery, and ephemeral activity.
  ///
  /// Durable cursor storage and retained conversation intent are preserved so
  /// [resumeFromCursor] can restore the same session intent later.
  Future<void> suspend() => close();

  /// Stops and starts the session using a fresh cursor load and token.
  Future<void> restart() async {
    if (_disposed) {
      throw StateError('The chat realtime session has been disposed.');
    }
    await close();
    await start();
  }

  /// Stops the reusable session and releases all active resources.
  Future<void> close() async {
    if (!_started && _state is ChatRealtimeIdleState) {
      await _detachNetworkListener();
      return;
    }
    _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
    _started = false;
    _recoveryOperation = null;
    ++_lifecycleEpoch;
    ++_generation;
    ++_cursorStorageSequence;
    _resetSubscriptionConnection();
    _cancelRetry();
    await _releaseSocket(closeSocket: true);
    await _detachNetworkListener();
    _retryAttempt = 0;
    _cursor = null;
    _cursorLoaded = false;
    _startOperation = null;
    _emit(const ChatRealtimeIdleState());
  }

  /// Permanently disposes the session. Repeated calls are harmless.
  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    _conversationSubscriptions.clear();
    _subscriptionOperations.clear();
    _durableStateBinding = null;
    await _stateChanges.close();
    await _conversationSubscriptionStateChanges.close();
    await _canonicalEventChanges.close();
  }

  Future<void> _connect() async {
    if (!_canConnect) return;
    _cancelRetry();
    if (!network.isOnline) {
      _goOffline();
      return;
    }

    _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
    final currentGeneration = ++_generation;
    _resetSubscriptionConnection();
    await _releaseSocket(closeSocket: true);
    if (!_hasAuthority(currentGeneration)) return;
    _emit(const ChatRealtimeConnectingState());

    String token;
    try {
      token = await tokenProvider();
    } catch (_) {
      if (_hasAuthority(currentGeneration)) {
        _scheduleReconnect(_accessTokenDiagnostic);
      }
      return;
    }
    if (!_hasAuthority(currentGeneration)) return;
    if (token.trim().isEmpty) {
      _scheduleReconnect(_accessTokenDiagnostic);
      return;
    }

    late final String bearerProtocol;
    try {
      bearerProtocol = _encodeBearerProtocol(token);
    } catch (_) {
      _scheduleReconnect(_accessTokenDiagnostic);
      return;
    }

    late final ChatRealtimeSocket nextSocket;
    try {
      nextSocket = await socketFactory(
        webSocketUri,
        List<String>.unmodifiable(<String>[
          chatRealtimeSubprotocol,
          bearerProtocol,
        ]),
      );
    } catch (_) {
      if (_hasAuthority(currentGeneration)) {
        _scheduleReconnect(_socketDiagnostic);
      }
      return;
    }
    if (!_hasAuthority(currentGeneration)) {
      await _safelyClose(nextSocket);
      return;
    }

    _socket = nextSocket;
    _socketSubscription = nextSocket.frames.listen(
      (frame) => _enqueueFrame(frame, currentGeneration, nextSocket),
      onError: (Object _, StackTrace __) {
        if (_ownsSocket(currentGeneration, nextSocket)) {
          _scheduleReconnect(_socketDiagnostic);
        }
      },
      onDone: () {
        if (_ownsSocket(currentGeneration, nextSocket)) {
          _scheduleReconnect(_connectionLostDiagnostic);
        }
      },
    );

    final handshake = ClientHandshakeInput(
      clientPackageVersion: clientPackageVersion,
      protocolVersion: protocolVersion,
      resumeFrom: _cursor,
    );
    try {
      await nextSocket.send(jsonEncode(handshake.toJson()));
    } catch (_) {
      if (_ownsSocket(currentGeneration, nextSocket)) {
        _scheduleReconnect(_socketDiagnostic);
      }
    }
  }

  void _enqueueFrame(
    Object? frame,
    int generation,
    ChatRealtimeSocket socket,
  ) {
    _frameProcessing = _frameProcessing
        .then((_) => _receiveFrame(frame, generation, socket))
        .catchError((Object _) {
      if (_ownsSocket(generation, socket)) {
        _scheduleReconnect(_malformedFrameDiagnostic);
      }
    });
  }

  Future<void> _receiveFrame(
    Object? rawFrame,
    int currentGeneration,
    ChatRealtimeSocket currentSocket,
  ) async {
    if (!_ownsSocket(currentGeneration, currentSocket)) return;
    if (rawFrame is! String) {
      _scheduleReconnect(_malformedFrameDiagnostic);
      return;
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(rawFrame);
    } catch (_) {
      _scheduleReconnect(_malformedFrameDiagnostic);
      return;
    }
    if (!_ownsSocket(currentGeneration, currentSocket)) return;

    if (decoded is! Map<Object?, Object?> || decoded['type'] is! String) {
      _scheduleReconnect(_malformedFrameDiagnostic);
      return;
    }
    final type = decoded['type']! as String;

    if (type.startsWith('chat.subscription.')) {
      if (_acceptedGeneration != currentGeneration) return;
      late final ChatRealtimeSubscriptionServerMessage message;
      try {
        message = ChatRealtimeSubscriptionServerMessage.fromJson(decoded);
      } catch (_) {
        _scheduleReconnect(_malformedFrameDiagnostic);
        return;
      }
      _receiveSubscriptionMessage(message, currentGeneration);
      return;
    }

    if (chatRealtimeSessionMessageTypes.values.contains(type)) {
      late final ChatRealtimeControlMessage message;
      try {
        message = ChatRealtimeControlMessage.fromJson(decoded);
      } catch (_) {
        _scheduleReconnect(_malformedFrameDiagnostic);
        return;
      }
      await _receiveControlMessage(
        message,
        currentGeneration,
        currentSocket,
      );
      return;
    }

    if (type == 'typing.signal' || type == 'presence.signal') {
      // Ephemeral state has its own accepted-session runtime and never moves
      // the durable replay cursor.
      return;
    }
    if (_acceptedGeneration != currentGeneration) return;
    await _receiveDurableFrame(decoded, currentGeneration, currentSocket);
  }

  Future<void> _receiveControlMessage(
    ChatRealtimeControlMessage message,
    int currentGeneration,
    ChatRealtimeSocket currentSocket,
  ) async {
    if (!_ownsSocket(currentGeneration, currentSocket)) return;

    switch (message) {
      case ChatRealtimeSessionAcceptedMessage():
        if (message.metadata.protocolVersion != protocolVersion ||
            _acceptedGeneration == currentGeneration) {
          _scheduleReconnect(_malformedFrameDiagnostic);
          return;
        }
        _retryAttempt = 0;
        _acceptedGeneration = currentGeneration;
        _actorStreamId = message.actorStreamId;
        if (message.resumeFrom case final cursor?) {
          await _persistCursor(cursor, currentGeneration);
          if (!_ownsSocket(currentGeneration, currentSocket)) return;
        }
        _emit(ChatRealtimeConnectedState(
          metadata: message.metadata,
          identity: ChatRealtimeAcceptedIdentity.fromMessage(message),
        ));
        _sendActorSubscription(message.actorStreamId);
        _restoreConversationSubscriptions();
        _ephemeralSignalEngine.accept(
          _AcceptedEphemeralSession.fromMessage(message),
        );
      case ChatRealtimeRefreshRequiredMessage():
        if (message.requestedProtocolVersion != protocolVersion) {
          _scheduleReconnect(_malformedFrameDiagnostic);
          return;
        }
        _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
        ++_generation;
        _resetSubscriptionConnection();
        _cancelRetry();
        await _releaseSocket(closeSocket: true);
        if (!_started || _disposed) return;
        _emit(
          ChatRealtimeRefreshRequiredState(
            requestedProtocolVersion: message.requestedProtocolVersion,
            metadata: message.metadata,
          ),
        );
      case ChatRealtimeSnapshotRequiredMessage():
        _requestSnapshotRecovery(
          reason: ChatRealtimeSnapshotRecoveryReason.fromSnapshotRequired(
            message.reason,
          ),
          expiredCursor: message.resumeFrom,
        );
    }
  }

  Future<void> _receiveDurableFrame(
    Object? decoded,
    int currentGeneration,
    ChatRealtimeSocket currentSocket,
  ) async {
    final binding = _durableStateBinding;
    final connected = _state;
    if (binding == null || connected is! ChatRealtimeConnectedState) return;

    late final KnownDurableEvent event;
    try {
      event = KnownDurableEvent.fromJson(
        decoded,
        trustedIdentity: DurableEventTrustedIdentity(
          tenantId: connected.identity.tenantId,
          userId: connected.identity.userId,
        ),
      );
    } on DurableEventFormatException catch (error) {
      final diagnostic = _durableParseDiagnostic(decoded, error.code);
      _notifyDiagnostic(_durableRecoveryDiagnostic);
      _requestSnapshotRecovery(
        reason: ChatRealtimeSnapshotRecoveryReason.fromDurable(
          diagnostic.reason,
        ),
        expiredCursor: _cursor ?? EventCursor(eventId: diagnostic.eventId),
        diagnostic: diagnostic,
      );
      return;
    } catch (_) {
      return;
    }
    if (!_ownsSocket(currentGeneration, currentSocket)) return;

    late final DurableEventReduction reduction;
    try {
      reduction = await binding.reduceDurableEvent(event);
    } on DurableEventReductionError catch (error) {
      if (!_ownsSocket(currentGeneration, currentSocket)) return;
      _notifyDiagnostic(_durableRecoveryDiagnostic);
      _requestSnapshotRecovery(
        reason: ChatRealtimeSnapshotRecoveryReason.fromDurable(
          error.diagnostic.reason,
        ),
        expiredCursor: _cursor ?? EventCursor(eventId: event.eventId),
        diagnostic: error.diagnostic,
      );
      return;
    } catch (_) {
      if (!_ownsSocket(currentGeneration, currentSocket)) return;
      _notifyDiagnostic(_durableRecoveryDiagnostic);
      _requestSnapshotRecovery(
        reason: ChatRealtimeSnapshotRecoveryReason.eventInvalid,
        expiredCursor: _cursor ?? EventCursor(eventId: event.eventId),
      );
      return;
    }
    if (!_ownsSocket(currentGeneration, currentSocket) ||
        reduction.status != DurableEventReductionStatus.applied) {
      return;
    }

    try {
      await onCanonicalEvent?.call(event);
    } catch (_) {
      if (_ownsSocket(currentGeneration, currentSocket)) {
        _notifyDiagnostic(_durableRecoveryDiagnostic);
        _requestSnapshotRecovery(
          reason: ChatRealtimeSnapshotRecoveryReason.eventInvalid,
          expiredCursor: _cursor ?? EventCursor(eventId: event.eventId),
        );
      }
      return;
    }
    if (!_ownsSocket(currentGeneration, currentSocket)) return;

    final persisted = await _persistRequiredCursor(
      EventCursor(eventId: event.eventId),
      currentGeneration,
    );
    if (!persisted) {
      if (_ownsSocket(currentGeneration, currentSocket)) {
        _notifyDiagnostic(_durableRecoveryDiagnostic);
        _requestSnapshotRecovery(
          reason: ChatRealtimeSnapshotRecoveryReason.eventInvalid,
          expiredCursor: _cursor ?? EventCursor(eventId: event.eventId),
        );
      }
      return;
    }
    if (_ownsSocket(currentGeneration, currentSocket) &&
        !_canonicalEventChanges.isClosed) {
      _canonicalEventChanges.add(event);
    }
  }

  DurableEventDiagnostic _durableParseDiagnostic(
    Object? decoded,
    DurableEventParseErrorCode code,
  ) {
    String safeField(String key, String fallback) {
      if (decoded case final Map<Object?, Object?> value) {
        final field = value[key];
        if (field is String && field.trim().isNotEmpty) return field.trim();
      }
      return fallback;
    }

    final (diagnosticCode, reason, message) = switch (code) {
      DurableEventParseErrorCode.unknownEventType => (
          DurableEventDiagnosticCode.unsupportedEventType,
          DurableEventRecoveryReason.eventIncompatible,
          'The durable event type is not supported by this client.',
        ),
      DurableEventParseErrorCode.tenantMismatch => (
          DurableEventDiagnosticCode.incoherentPayload,
          DurableEventRecoveryReason.eventInvalid,
          'The durable event did not match the trusted tenant.',
        ),
      DurableEventParseErrorCode.privateStreamMismatch => (
          DurableEventDiagnosticCode.privateStreamMismatch,
          DurableEventRecoveryReason.eventInvalid,
          'The durable event did not match the trusted private stream.',
        ),
      DurableEventParseErrorCode.incoherentPayload => (
          DurableEventDiagnosticCode.incoherentPayload,
          DurableEventRecoveryReason.eventInvalid,
          'The durable event envelope was invalid.',
        ),
    };
    return DurableEventDiagnostic(
      code: diagnosticCode,
      reason: reason,
      eventId: safeField('eventId', 'unparseable-event'),
      streamId: safeField('streamId', 'unparseable-stream'),
      eventType: safeField('type', 'unparseable-event-type'),
      message: message,
    );
  }

  void _restoreConversationSubscriptions() {
    for (final subscription in List<_ConversationSubscription>.of(
        _conversationSubscriptions.values)) {
      if (subscription.retainCount > 0) {
        _sendConversationSubscription(
          subscription,
          ChatRealtimeConversationSubscriptionOperation.subscribe,
        );
      }
    }
  }

  void _sendActorSubscription(String actorStreamId) {
    if (!_canSendSubscriptions || actorStreamId != _actorStreamId) return;
    final requestId = _nextSubscriptionRequestId();
    _subscriptionOperations[requestId] = _SubscriptionOperationContext(
      requestId: requestId,
      streamId: actorStreamId,
      generation: _generation,
      operation: ChatRealtimeConversationSubscriptionOperation.subscribe,
      subscriptionEpoch: null,
      isActorStream: true,
    );
    _sendSubscriptionRequest(
      ChatRealtimeSubscribeRequest(
        requestId: requestId,
        streamId: actorStreamId,
      ),
      _generation,
    );
  }

  void _sendConversationSubscription(
    _ConversationSubscription subscription,
    ChatRealtimeConversationSubscriptionOperation operation,
  ) {
    if (!_canSendSubscriptions) return;
    if (operation == ChatRealtimeConversationSubscriptionOperation.subscribe &&
        subscription.retainCount == 0) {
      return;
    }
    if (operation ==
            ChatRealtimeConversationSubscriptionOperation.unsubscribe &&
        subscription.retainCount != 0) {
      return;
    }

    final requestId = _nextSubscriptionRequestId();
    final streamId = subscription.conversationId.value;
    _subscriptionOperations[requestId] = _SubscriptionOperationContext(
      requestId: requestId,
      streamId: streamId,
      generation: _generation,
      operation: operation,
      subscriptionEpoch: subscription.epoch,
      isActorStream: false,
    );
    _emitConversationSubscriptionState(
      ChatRealtimeConversationSubscriptionPendingState(
        conversationId: subscription.conversationId,
        operation: operation,
        requestId: requestId,
      ),
    );
    final request = switch (operation) {
      ChatRealtimeConversationSubscriptionOperation.subscribe =>
        ChatRealtimeSubscribeRequest(
          requestId: requestId,
          streamId: streamId,
        ),
      ChatRealtimeConversationSubscriptionOperation.unsubscribe =>
        ChatRealtimeUnsubscribeRequest(
          requestId: requestId,
          streamId: streamId,
        ),
    };
    _sendSubscriptionRequest(request, _generation);
  }

  void _sendSubscriptionRequest(
    ChatRealtimeSubscriptionRequest request,
    int operationGeneration,
  ) {
    final socket = _socket;
    if (socket == null || !_ownsSocket(operationGeneration, socket)) return;
    unawaited(() async {
      try {
        await socket.send(jsonEncode(request.toJson()));
      } catch (_) {
        if (_ownsSocket(operationGeneration, socket)) {
          _scheduleReconnect(_socketDiagnostic);
        }
      }
    }());
  }

  bool _sendEphemeralSignal(EphemeralSignalEvent event) {
    final socket = _socket;
    final sendGeneration = _generation;
    if (socket == null || !_canSendSubscriptions) return false;
    try {
      final result = socket.send(jsonEncode(event.toJson()));
      if (result is Future<void>) {
        unawaited(result.catchError((Object _) {
          _handleEphemeralSendFailure(sendGeneration, socket);
        }));
      }
      return true;
    } catch (_) {
      _handleEphemeralSendFailure(sendGeneration, socket);
      return false;
    }
  }

  void _handleEphemeralSendFailure(
    int sendGeneration,
    ChatRealtimeSocket socket,
  ) {
    scheduleMicrotask(() {
      if (_ownsSocket(sendGeneration, socket)) {
        _scheduleReconnect(_socketDiagnostic);
      }
    });
  }

  void _receiveSubscriptionMessage(
    ChatRealtimeSubscriptionServerMessage message,
    int currentGeneration,
  ) {
    switch (message) {
      case ChatRealtimeSubscriptionAcceptedMessage():
        final operation = _takeCurrentSubscriptionOperation(
          requestId: message.requestId,
          streamId: message.streamId,
          generation: currentGeneration,
          expectedOperation:
              ChatRealtimeConversationSubscriptionOperation.subscribe,
        );
        if (operation == null || operation.isActorStream) return;
        final subscription = _matchingSubscription(operation);
        if (subscription == null || subscription.retainCount == 0) return;
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionAcceptedState(
            conversationId: subscription.conversationId,
            requestId: message.requestId,
          ),
        );
      case ChatRealtimeSubscriptionRemovedMessage():
        final operation = _takeCurrentSubscriptionOperation(
          requestId: message.requestId,
          streamId: message.streamId,
          generation: currentGeneration,
          expectedOperation:
              ChatRealtimeConversationSubscriptionOperation.unsubscribe,
        );
        if (operation == null || operation.isActorStream) return;
        final subscription = _matchingSubscription(operation);
        if (subscription == null || subscription.retainCount != 0) return;
        _conversationSubscriptions.remove(operation.streamId);
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRemovedState(
            conversationId: subscription.conversationId,
            requestId: message.requestId,
          ),
        );
      case ChatRealtimeSubscriptionRejectedMessage():
        final requestId = message.requestId;
        if (requestId == null) return;
        final operation = _subscriptionOperations.remove(requestId);
        if (operation == null ||
            operation.generation != currentGeneration ||
            operation.isActorStream) {
          return;
        }
        final subscription = _matchingSubscription(operation);
        if (subscription == null) return;
        if (operation.operation ==
                ChatRealtimeConversationSubscriptionOperation.subscribe &&
            subscription.retainCount == 0) {
          return;
        }
        if (operation.operation ==
                ChatRealtimeConversationSubscriptionOperation.unsubscribe &&
            subscription.retainCount != 0) {
          return;
        }
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRejectedState(
            conversationId: subscription.conversationId,
            requestId: requestId,
            code: message.code,
          ),
        );
      case ChatRealtimeSubscriptionRevokedMessage():
        if (message.streamId == _actorStreamId) return;
        final subscription = _conversationSubscriptions[message.streamId];
        final latest = _latestConversationSubscriptionStates[message.streamId];
        if (subscription == null ||
            subscription.retainCount == 0 ||
            latest is! ChatRealtimeConversationSubscriptionAcceptedState) {
          return;
        }
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRevokedState(
            conversationId: subscription.conversationId,
          ),
        );
    }
  }

  _SubscriptionOperationContext? _takeCurrentSubscriptionOperation({
    required String requestId,
    required String streamId,
    required int generation,
    required ChatRealtimeConversationSubscriptionOperation expectedOperation,
  }) {
    final operation = _subscriptionOperations[requestId];
    if (operation == null ||
        operation.streamId != streamId ||
        operation.generation != generation ||
        operation.operation != expectedOperation) {
      return null;
    }
    _subscriptionOperations.remove(requestId);
    return operation;
  }

  _ConversationSubscription? _matchingSubscription(
    _SubscriptionOperationContext operation,
  ) {
    final subscription = _conversationSubscriptions[operation.streamId];
    if (subscription == null ||
        operation.subscriptionEpoch != subscription.epoch) {
      return null;
    }
    return subscription;
  }

  void _resetSubscriptionConnection() {
    _acceptedGeneration = null;
    _actorStreamId = null;
    _subscriptionOperations.clear();
    for (final entry in List<MapEntry<String, _ConversationSubscription>>.of(
      _conversationSubscriptions.entries,
    )) {
      final subscription = entry.value;
      if (subscription.retainCount == 0) {
        _conversationSubscriptions.remove(entry.key);
        _emitConversationSubscriptionState(
          ChatRealtimeConversationSubscriptionRemovedState(
            conversationId: subscription.conversationId,
          ),
        );
        continue;
      }
      final latest = _latestConversationSubscriptionStates[entry.key];
      if (latest is ChatRealtimeConversationSubscriptionPendingState &&
          latest.operation ==
              ChatRealtimeConversationSubscriptionOperation.subscribe &&
          latest.requestId == null) {
        continue;
      }
      _emitConversationSubscriptionState(
        ChatRealtimeConversationSubscriptionPendingState(
          conversationId: subscription.conversationId,
          operation: ChatRealtimeConversationSubscriptionOperation.subscribe,
        ),
      );
    }
  }

  void _emitConversationSubscriptionState(
    ChatRealtimeConversationSubscriptionState nextState,
  ) {
    if (_disposed) return;
    _latestConversationSubscriptionStates[nextState.conversationId.value] =
        nextState;
    if (!_conversationSubscriptionStateChanges.isClosed) {
      _conversationSubscriptionStateChanges.add(nextState);
    }
    try {
      onConversationSubscriptionStateChange?.call(nextState);
    } catch (_) {
      // Subscription observers cannot alter transport reliability.
    }
  }

  String _nextSubscriptionRequestId() =>
      'chat-realtime-${++_subscriptionRequestSequence}';

  void _requestSnapshotRecovery({
    required ChatRealtimeSnapshotRecoveryReason reason,
    required EventCursor expiredCursor,
    DurableEventDiagnostic? diagnostic,
  }) {
    if (!_canConnect || _recoveryOperation != null) return;
    late final Future<void> operation;
    operation = _recoverSnapshot(
      reason: reason,
      expiredCursor: expiredCursor,
      diagnostic: diagnostic,
    ).whenComplete(() {
      if (identical(_recoveryOperation, operation)) {
        _recoveryOperation = null;
      }
    });
    _recoveryOperation = operation;
  }

  Future<void> _recoverSnapshot({
    required ChatRealtimeSnapshotRecoveryReason reason,
    required EventCursor expiredCursor,
    DurableEventDiagnostic? diagnostic,
  }) async {
    _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
    final recoveryGeneration = ++_generation;
    _resetSubscriptionConnection();
    _cancelRetry();
    await _releaseSocket(closeSocket: true);
    if (!_hasAuthority(recoveryGeneration)) return;
    _emit(ChatRealtimeHydratingSnapshotState(
      reason: reason,
      diagnostic: diagnostic,
    ));
    await _clearCursor(recoveryGeneration);
    if (!_hasAuthority(recoveryGeneration)) return;

    EventCursor? nextCursor;
    try {
      final hydrator = _durableStateBinding?.hydrateSnapshot ?? hydrateSnapshot;
      nextCursor = await hydrator?.call(
        ChatRealtimeSnapshotHydrationInput(
          reason: reason,
          expiredCursor: expiredCursor,
          retainedConversationIds: List<ConversationId>.unmodifiable(
            _conversationSubscriptions.values
                .where((subscription) => subscription.retainCount > 0)
                .map((subscription) => subscription.conversationId)
                .toList(growable: false)
              ..sort((left, right) => left.value.compareTo(right.value)),
          ),
          diagnostic: diagnostic,
          currentRetainedConversationIds: () =>
              List<ConversationId>.unmodifiable(
            _conversationSubscriptions.values
                .where((subscription) => subscription.retainCount > 0)
                .map((subscription) => subscription.conversationId),
          ),
          isCancelled: () => !_hasAuthority(recoveryGeneration),
        ),
      );
      if (!_hasAuthority(recoveryGeneration)) return;
      if (nextCursor != null) {
        nextCursor = _validatedCursor(nextCursor);
        if (nextCursor == null) throw const FormatException();
        if (!await _persistRequiredCursor(
          nextCursor,
          recoveryGeneration,
        )) {
          throw const FormatException();
        }
      }
    } catch (_) {
      if (_hasAuthority(recoveryGeneration)) {
        _scheduleReconnect(_snapshotDiagnostic);
      }
      return;
    }
    if (_hasAuthority(recoveryGeneration)) {
      _scheduleReconnect(_connectionLostDiagnostic, immediate: true);
    }
  }

  void _scheduleReconnect(
    ChatRealtimeDiagnostic diagnostic, {
    bool immediate = false,
  }) {
    if (!_started || _disposed || _state is ChatRealtimeRefreshRequiredState) {
      return;
    }
    _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
    _recoveryOperation = null;
    ++_generation;
    _resetSubscriptionConnection();
    _cancelRetry();
    unawaited(_releaseSocket(closeSocket: true));
    _notifyDiagnostic(diagnostic);
    if (!network.isOnline) {
      _emit(const ChatRealtimeOfflineState());
      return;
    }

    final delay = immediate ? Duration.zero : _calculateRetryDelay();
    _retryAttempt += 1;
    _emit(
      ChatRealtimeReconnectingState(
        attempt: _retryAttempt,
        delay: delay,
        diagnostic: diagnostic,
      ),
    );
    final scheduledGeneration = _generation;
    try {
      _retryTimer = clock.schedule(delay, () {
        _retryTimer = null;
        if (_hasAuthority(scheduledGeneration)) unawaited(_connect());
      });
    } catch (_) {
      // A host clock failure cannot be safely retried without another clock.
    }
  }

  Duration _calculateRetryDelay() {
    final initialMs = retry.initialDelay.inMilliseconds.toDouble();
    final maximumMs = retry.maximumDelay.inMilliseconds.toDouble();
    final exponential = initialMs * math.pow(retry.multiplier, _retryAttempt);
    final baseMs = math.min(maximumMs, exponential).toDouble();
    var sample = 0.5;
    try {
      sample = random();
    } catch (_) {
      // A deterministic midpoint keeps retry safe when host randomness fails.
    }
    if (!sample.isFinite) sample = 0.5;
    sample = sample.clamp(0, 1).toDouble();
    final factor = 1 - retry.jitterRatio + 2 * retry.jitterRatio * sample;
    final jittered = (baseMs * factor).round().clamp(0, maximumMs.round());
    return Duration(milliseconds: jittered);
  }

  void _goOffline() {
    if (!_started || _disposed || _state is ChatRealtimeRefreshRequiredState) {
      return;
    }
    _ephemeralSignalEngine.deactivate(sendTerminalSignals: true);
    _recoveryOperation = null;
    ++_generation;
    _resetSubscriptionConnection();
    _cancelRetry();
    unawaited(_releaseSocket(closeSocket: true));
    _emit(const ChatRealtimeOfflineState());
  }

  void _attachNetworkListener() {
    if (_networkSubscription != null) return;
    _networkSubscription = network.changes.listen(
      (online) {
        if (!_started ||
            _disposed ||
            _state is ChatRealtimeRefreshRequiredState) {
          return;
        }
        if (!online) {
          _goOffline();
        } else if (_state is ChatRealtimeOfflineState && _cursorLoaded) {
          unawaited(_connect());
        }
      },
      onError: (Object _, StackTrace __) {
        // Connectivity observation is advisory; the current value remains.
      },
    );
  }

  Future<void> _detachNetworkListener() async {
    final subscription = _networkSubscription;
    _networkSubscription = null;
    await subscription?.cancel();
  }

  Future<void> _loadCursor(int lifecycleEpoch) async {
    if (_cursorLoaded) return;
    String? serialized;
    try {
      await _runCursorStorageOperation(() async {
        if (!_hasLifecycleAuthority(lifecycleEpoch)) return;
        final storage = cursorStorage;
        if (storage == null) return;
        serialized = await storage.read(scope: cursorStorageScope!);
      });
      if (!_hasLifecycleAuthority(lifecycleEpoch)) return;
      if (serialized case final value?) {
        _cursor = _validatedCursor(jsonDecode(value));
      }
    } catch (_) {
      // Cursor storage is opportunistic and never blocks a live session.
    } finally {
      if (_hasLifecycleAuthority(lifecycleEpoch)) _cursorLoaded = true;
    }
  }

  Future<void> _persistCursor(
    EventCursor cursor,
    int authorityGeneration,
  ) async {
    final validated = _validatedCursor(cursor);
    if (validated == null || !_hasAuthority(authorityGeneration)) return;
    final storageSequence = ++_cursorStorageSequence;
    _cursor = validated;
    if (!await _runCursorStorageOperation(
      () async {
        if (!_hasCursorStorageAuthority(
          authorityGeneration,
          storageSequence,
        )) {
          return;
        }
        final storage = cursorStorage;
        if (storage == null) return;
        await storage.write(
          scope: cursorStorageScope!,
          value: jsonEncode(validated.toJson()),
        );
        if (!_hasCursorStorageAuthority(
          authorityGeneration,
          storageSequence,
        )) {
          await storage.clear(scope: cursorStorageScope!);
        }
      },
    )) {
      // Preserve the validated in-memory cursor when storage is unavailable.
    }
  }

  Future<bool> _persistRequiredCursor(
    EventCursor cursor,
    int authorityGeneration,
  ) async {
    final validated = _validatedCursor(cursor);
    if (validated == null || !_hasAuthority(authorityGeneration)) return false;
    final storageSequence = ++_cursorStorageSequence;
    var retained = false;
    final written = await _runCursorStorageOperation(
      () async {
        if (!_hasCursorStorageAuthority(
          authorityGeneration,
          storageSequence,
        )) {
          return;
        }
        final storage = cursorStorage;
        if (storage != null) {
          await storage.write(
            scope: cursorStorageScope!,
            value: jsonEncode(validated.toJson()),
          );
          if (!_hasCursorStorageAuthority(
            authorityGeneration,
            storageSequence,
          )) {
            await storage.clear(scope: cursorStorageScope!);
            return;
          }
        }
        retained = true;
      },
    );
    if (!written || !retained) {
      return false;
    }
    _cursor = validated;
    return true;
  }

  Future<void> _clearCursor(int authorityGeneration) async {
    if (!_hasAuthority(authorityGeneration)) return;
    final storageSequence = ++_cursorStorageSequence;
    _cursor = null;
    if (!await _runCursorStorageOperation(() async {
      if (!_hasCursorStorageAuthority(
        authorityGeneration,
        storageSequence,
      )) {
        return;
      }
      await cursorStorage?.clear(scope: cursorStorageScope!);
    })) {
      // Snapshot recovery remains usable with in-memory cursor state.
    }
  }

  bool _hasLifecycleAuthority(int lifecycleEpoch) =>
      _started && !_disposed && lifecycleEpoch == _lifecycleEpoch;

  bool _hasCursorStorageAuthority(int generation, int storageSequence) =>
      _hasAuthority(generation) && storageSequence == _cursorStorageSequence;

  Future<bool> _runCursorStorageOperation(
    FutureOr<void> Function() operation,
  ) async {
    final pending = _cursorStorageOperations.then((_) async {
      await operation();
    });
    _cursorStorageOperations = pending.catchError((Object _) {});
    try {
      await pending;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _releaseSocket({required bool closeSocket}) async {
    _ephemeralSignalEngine.deactivate(sendTerminalSignals: false);
    final subscription = _socketSubscription;
    final socket = _socket;
    _socketSubscription = null;
    _socket = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // A failed stream cancellation does not retain session authority.
    }
    if (closeSocket && socket != null) await _safelyClose(socket);
  }

  Future<void> _safelyClose(ChatRealtimeSocket socket) async {
    try {
      await socket.close();
    } catch (_) {
      // A transport that already failed still counts as released.
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool get _canConnect =>
      _started && !_disposed && _state is! ChatRealtimeRefreshRequiredState;

  bool get _canSendSubscriptions =>
      _acceptedGeneration == _generation &&
      _socket != null &&
      _state is ChatRealtimeConnectedState;

  bool _hasAuthority(int generation) =>
      _canConnect && generation == _generation;

  bool _ownsSocket(int generation, ChatRealtimeSocket socket) =>
      _hasAuthority(generation) && identical(socket, _socket);

  ChatRealtimeLifecycleState _emit(ChatRealtimeLifecycleState nextState) {
    if (_disposed) return _state;
    _state = nextState;
    if (!_stateChanges.isClosed) _stateChanges.add(nextState);
    try {
      onStateChange?.call(nextState);
    } catch (_) {
      // State observers cannot alter transport reliability.
    }
    return nextState;
  }

  void _notifyDiagnostic(ChatRealtimeDiagnostic diagnostic) {
    try {
      onDiagnostic?.call(diagnostic);
    } catch (_) {
      // Diagnostic observers cannot alter transport reliability.
    }
  }

  Stream<ChatRealtimeLifecycleState> _createStateStream() =>
      Stream<ChatRealtimeLifecycleState>.multi(
        (events) {
          events.add(_state);
          final subscription = _stateChanges.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          events.onCancel = () {
            unawaited(subscription.cancel());
          };
        },
        isBroadcast: true,
      );

  @override
  String toString() => 'ChatRealtimeSessionTransport('
      'state: ${_state.state}, started: $_started, disposed: $_disposed)';
}

final class _ConversationSubscription {
  _ConversationSubscription({
    required this.conversationId,
    required this.retainCount,
    required this.epoch,
  });

  final ConversationId conversationId;
  int retainCount;
  int epoch;
}

final class _SubscriptionOperationContext {
  const _SubscriptionOperationContext({
    required this.requestId,
    required this.streamId,
    required this.generation,
    required this.operation,
    required this.subscriptionEpoch,
    required this.isActorStream,
  });

  final String requestId;
  final String streamId;
  final int generation;
  final ChatRealtimeConversationSubscriptionOperation operation;
  final int? subscriptionEpoch;
  final bool isActorStream;
}

final class _ChatRealtimeDurableStateBinding {
  const _ChatRealtimeDurableStateBinding({
    required this.reduceDurableEvent,
    required this.hydrateSnapshot,
  });

  final ChatRealtimeDurableEventReducer reduceDurableEvent;
  final ChatRealtimeSnapshotHydrator hydrateSnapshot;
}

final class _AcceptedEphemeralSession {
  const _AcceptedEphemeralSession({
    required this.protocolVersion,
    required this.tenantId,
    required this.actorUserId,
    required this.deviceId,
    required this.sessionId,
    required this.enabledFeatures,
  });

  factory _AcceptedEphemeralSession.fromMessage(
    ChatRealtimeSessionAcceptedMessage message,
  ) =>
      _AcceptedEphemeralSession(
        protocolVersion: message.metadata.protocolVersion,
        tenantId: message.tenantId,
        actorUserId: UserId(message.actorStreamId.substring('user:'.length)),
        deviceId: message.deviceId,
        sessionId: message.sessionId,
        enabledFeatures: message.metadata.enabledFeatures,
      );

  final int protocolVersion;
  final TenantId tenantId;
  final UserId actorUserId;
  final DeviceId deviceId;
  final SessionId sessionId;
  final EnabledFeatures enabledFeatures;
}

final class _ActiveTypingSignal {
  _ActiveTypingSignal(this.scope);

  final TypingSignalScope scope;
  ChatRealtimeTimer? heartbeatTimer;
  ChatRealtimeTimer? idleTimer;
}

final class _ChatRealtimeEphemeralSignalEngine {
  _ChatRealtimeEphemeralSignalEngine({
    required ChatRealtimeEphemeralSignalOptions options,
    required bool Function(EphemeralSignalEvent event) send,
    required ChatRealtimeEphemeralSessionDisconnectListener?
        onSessionDisconnected,
  })  : _options = options,
        _clock = options.clock ?? const _SystemChatRealtimeEphemeralClock(),
        _visibility = options.visibility ?? const _AlwaysVisibleBoundary(),
        _send = send,
        _onSessionDisconnected = onSessionDisconnected;

  final ChatRealtimeEphemeralSignalOptions _options;
  final ChatRealtimeEphemeralClock _clock;
  final ChatRealtimeVisibility _visibility;
  final bool Function(EphemeralSignalEvent event) _send;
  final ChatRealtimeEphemeralSessionDisconnectListener? _onSessionDisconnected;
  final Map<String, _ActiveTypingSignal> _activeTyping =
      <String, _ActiveTypingSignal>{};
  final List<int> _rateTimestamps = <int>[];
  late final void Function() _visibilityListener = _onVisibilityChanged;

  _AcceptedEphemeralSession? _accepted;
  PresenceSignalState _desiredPresence = PresenceSignalState.online;
  ChatRealtimeTimer? _presenceHeartbeatTimer;
  ChatRealtimeTimer? _presenceIdleTimer;
  var _idleAway = false;
  var _visibilityAttached = false;
  var _sequence = 0;
  int? _lastWireTimestamp;

  void accept(_AcceptedEphemeralSession session) {
    deactivate(sendTerminalSignals: false);
    _accepted = session;
    _sequence = 0;
    _lastWireTimestamp = null;
    _rateTimestamps.clear();
    _idleAway = false;
    _attachVisibility();
    if (_featureEnabled(EphemeralSignalFeature.presence) &&
        _desiredPresence != PresenceSignalState.offline) {
      _emitPresence(_effectivePresence());
    }
    _schedulePresenceHeartbeat();
    _schedulePresenceIdle();
  }

  void deactivate({required bool sendTerminalSignals}) {
    final disconnectedSession = _accepted;
    _stopAllTyping(sendStops: sendTerminalSignals);
    _presenceHeartbeatTimer?.cancel();
    _presenceHeartbeatTimer = null;
    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = null;
    if (sendTerminalSignals && _accepted != null) {
      _emitPresence(PresenceSignalState.offline, terminal: true);
    }
    _accepted = null;
    _detachVisibility();
    if (disconnectedSession != null) {
      try {
        _onSessionDisconnected?.call(
          disconnectedSession.tenantId,
          disconnectedSession.sessionId,
        );
      } catch (_) {
        // Cleanup observers cannot alter transport reliability.
      }
    }
  }

  bool startTyping(
    ConversationId conversationId,
    ChatRealtimeConversationVisibility? requestedVisibility,
  ) {
    if (!_featureEnabled(EphemeralSignalFeature.typing) ||
        !_isVisible ||
        _desiredPresence == PresenceSignalState.offline) {
      return false;
    }
    final resolver = _options.conversationVisibilityResolver;
    ChatRealtimeConversationVisibility? authorizedVisibility;
    try {
      authorizedVisibility = resolver?.call(
        conversationId,
        requestedVisibility,
      );
    } catch (_) {
      return false;
    }
    if (authorizedVisibility == null ||
        (requestedVisibility != null &&
            requestedVisibility != authorizedVisibility)) {
      return false;
    }

    notifyActivity();
    final existing = _activeTyping[conversationId.value];
    if (existing != null) {
      _scheduleTypingIdle(conversationId, existing);
      return true;
    }

    final scope = switch (authorizedVisibility) {
      ChatRealtimeConversationVisibility.publicConversation =>
        PublicConversationSignalScope(conversationId),
      ChatRealtimeConversationVisibility.privateConversation =>
        PrivateConversationSignalScope(conversationId),
    };
    final typing = _ActiveTypingSignal(scope);
    if (!_emitTyping(TypingSignalState.start, scope)) return false;
    _activeTyping[conversationId.value] = typing;
    _scheduleTypingHeartbeat(conversationId, typing);
    _scheduleTypingIdle(conversationId, typing);
    return true;
  }

  void stopTyping(ConversationId conversationId) {
    final typing = _activeTyping.remove(conversationId.value);
    if (typing == null) return;
    typing.heartbeatTimer?.cancel();
    typing.idleTimer?.cancel();
    _emitTyping(TypingSignalState.stop, typing.scope, terminal: true);
  }

  void setPresence(PresenceSignalState state) {
    _desiredPresence = state;
    _idleAway = false;
    if (state == PresenceSignalState.offline) {
      _stopAllTyping(sendStops: true);
    }
    _emitPresence(
      _effectivePresence(),
      terminal: state == PresenceSignalState.offline,
    );
    _schedulePresenceHeartbeat();
    _schedulePresenceIdle();
  }

  void notifyActivity() {
    if (_desiredPresence != PresenceSignalState.online || !_isVisible) return;
    final wasAway = _idleAway;
    _idleAway = false;
    if (wasAway) _emitPresence(PresenceSignalState.online);
    _schedulePresenceIdle();
  }

  bool _emitTyping(
    TypingSignalState state,
    TypingSignalScope scope, {
    bool terminal = false,
  }) =>
      _emit(
        EphemeralSignalFeature.typing,
        terminal: terminal,
        create: (session, sequence, sentAt, expiresAt) => TypingSignalEvent(
          eventId: 'client-ephemeral-${session.sessionId.value}-$sequence',
          protocolVersion: session.protocolVersion,
          tenantId: session.tenantId,
          streamId: scope.conversationId,
          occurredAt: sentAt,
          payload: TypingSignalPayload(
            actorUserId: session.actorUserId,
            deviceId: session.deviceId,
            sessionId: session.sessionId,
            sequence: sequence,
            sentAt: sentAt,
            expiresAt: expiresAt,
            state: state,
            scope: scope,
          ),
        ),
      );

  bool _emitPresence(
    PresenceSignalState state, {
    bool terminal = false,
  }) =>
      _emit(
        EphemeralSignalFeature.presence,
        terminal: terminal,
        create: (session, sequence, sentAt, expiresAt) => PresenceSignalEvent(
          eventId: 'client-ephemeral-${session.sessionId.value}-$sequence',
          protocolVersion: session.protocolVersion,
          tenantId: session.tenantId,
          streamId: 'user:${session.actorUserId.value}',
          occurredAt: sentAt,
          payload: PresenceSignalPayload(
            actorUserId: session.actorUserId,
            deviceId: session.deviceId,
            sessionId: session.sessionId,
            sequence: sequence,
            sentAt: sentAt,
            expiresAt: expiresAt,
            state: state,
            scope: UserPrivateSignalScope(session.actorUserId),
          ),
        ),
      );

  bool _emit(
    EphemeralSignalFeature feature, {
    required bool terminal,
    required EphemeralSignalEvent Function(
      _AcceptedEphemeralSession session,
      int sequence,
      IsoTimestamp sentAt,
      IsoTimestamp expiresAt,
    ) create,
  }) {
    final session = _accepted;
    if (session == null || !_featureEnabled(feature)) return false;
    final rateNow = _nowMilliseconds;
    if (!_consumeRate(rateNow, terminal: terminal) ||
        _sequence >= maxEphemeralSignalSequence) {
      return false;
    }
    final wallTimestamp = _nowMilliseconds;
    final minimumTimestamp = (_lastWireTimestamp ?? (wallTimestamp - 1)) + 1;
    final wireTimestamp = math.max(wallTimestamp, minimumTimestamp);
    _lastWireTimestamp = wireTimestamp;
    final sequence = ++_sequence;
    final sentAt = IsoTimestamp(_isoTimestamp(wireTimestamp));
    final ttl = feature == EphemeralSignalFeature.typing
        ? _options.typingTtl
        : _options.presenceTtl;
    final expiresAt = IsoTimestamp(
      _isoTimestamp(wireTimestamp + ttl.inMilliseconds),
    );
    return _send(create(session, sequence, sentAt, expiresAt));
  }

  bool _consumeRate(int timestamp, {required bool terminal}) {
    if (terminal) return true;
    final cutoff = timestamp - _options.rateLimitWindow.inMilliseconds;
    while (_rateTimestamps.isNotEmpty && _rateTimestamps.first <= cutoff) {
      _rateTimestamps.removeAt(0);
    }
    if (_rateTimestamps.length >= _options.rateLimitMaxSignals) return false;
    _rateTimestamps.add(timestamp);
    return true;
  }

  bool _featureEnabled(EphemeralSignalFeature feature) {
    final locallyEnabled = switch (feature) {
      EphemeralSignalFeature.typing => _options.typingEnabled,
      EphemeralSignalFeature.presence => _options.presenceEnabled,
    };
    return locallyEnabled &&
        _accepted?.enabledFeatures[feature.wireValue] == true;
  }

  PresenceSignalState _effectivePresence() {
    if (_desiredPresence == PresenceSignalState.offline) {
      return PresenceSignalState.offline;
    }
    if (!_isVisible ||
        _desiredPresence == PresenceSignalState.away ||
        _idleAway) {
      return PresenceSignalState.away;
    }
    return PresenceSignalState.online;
  }

  void _schedulePresenceHeartbeat() {
    _presenceHeartbeatTimer?.cancel();
    _presenceHeartbeatTimer = null;
    if (!_featureEnabled(EphemeralSignalFeature.presence) ||
        _effectivePresence() == PresenceSignalState.offline) {
      return;
    }
    _presenceHeartbeatTimer = _schedule(
      _options.presenceHeartbeat,
      () {
        _presenceHeartbeatTimer = null;
        if (_accepted == null) return;
        _emitPresence(_effectivePresence());
        _schedulePresenceHeartbeat();
      },
    );
  }

  void _schedulePresenceIdle() {
    _presenceIdleTimer?.cancel();
    _presenceIdleTimer = null;
    if (!_featureEnabled(EphemeralSignalFeature.presence) ||
        _desiredPresence != PresenceSignalState.online ||
        !_isVisible) {
      return;
    }
    _presenceIdleTimer = _schedule(
      _options.presenceIdle,
      () {
        _presenceIdleTimer = null;
        if (_accepted == null) return;
        _idleAway = true;
        _emitPresence(PresenceSignalState.away);
        _schedulePresenceHeartbeat();
      },
    );
  }

  void _scheduleTypingHeartbeat(
    ConversationId conversationId,
    _ActiveTypingSignal typing,
  ) {
    typing.heartbeatTimer?.cancel();
    typing.heartbeatTimer = _schedule(
      _options.typingHeartbeat,
      () {
        typing.heartbeatTimer = null;
        if (_accepted == null ||
            !identical(_activeTyping[conversationId.value], typing)) {
          return;
        }
        _emitTyping(TypingSignalState.start, typing.scope);
        _scheduleTypingHeartbeat(conversationId, typing);
      },
    );
  }

  void _scheduleTypingIdle(
    ConversationId conversationId,
    _ActiveTypingSignal typing,
  ) {
    typing.idleTimer?.cancel();
    typing.idleTimer = _schedule(
      _options.typingIdle,
      () {
        typing.idleTimer = null;
        if (identical(_activeTyping[conversationId.value], typing)) {
          stopTyping(conversationId);
        }
      },
    );
  }

  ChatRealtimeTimer? _schedule(Duration delay, void Function() callback) {
    try {
      return _clock.schedule(delay, callback);
    } catch (_) {
      return null;
    }
  }

  void _stopAllTyping({required bool sendStops}) {
    for (final entry in List<MapEntry<String, _ActiveTypingSignal>>.of(
      _activeTyping.entries,
    )) {
      final typing = entry.value;
      typing.heartbeatTimer?.cancel();
      typing.idleTimer?.cancel();
      _activeTyping.remove(entry.key);
      if (sendStops) {
        _emitTyping(TypingSignalState.stop, typing.scope, terminal: true);
      }
    }
  }

  void _onVisibilityChanged() {
    if (!_isVisible) {
      _stopAllTyping(sendStops: true);
      _presenceIdleTimer?.cancel();
      _presenceIdleTimer = null;
      if (_desiredPresence != PresenceSignalState.offline) {
        _emitPresence(PresenceSignalState.away, terminal: true);
      }
    } else {
      _idleAway = false;
      if (_desiredPresence != PresenceSignalState.offline) {
        _emitPresence(_effectivePresence());
      }
      _schedulePresenceIdle();
    }
    _schedulePresenceHeartbeat();
  }

  void _attachVisibility() {
    if (_visibilityAttached) return;
    _visibilityAttached = true;
    try {
      _visibility.addListener(_visibilityListener);
    } catch (_) {
      _visibilityAttached = false;
    }
  }

  void _detachVisibility() {
    if (!_visibilityAttached) return;
    _visibilityAttached = false;
    try {
      _visibility.removeListener(_visibilityListener);
    } catch (_) {
      // Host visibility cleanup is best effort after local authority is gone.
    }
  }

  bool get _isVisible {
    try {
      return _visibility.isVisible;
    } catch (_) {
      return false;
    }
  }

  int get _nowMilliseconds => _clock.now().toUtc().millisecondsSinceEpoch;
}

EventCursor? _validatedCursor(Object? value) {
  try {
    final cursor = value is EventCursor
        ? EventCursor.fromJson(value.toJson())
        : EventCursor.fromJson(value);
    return EventCursor(eventId: cursor.eventId);
  } catch (_) {
    return null;
  }
}

String _validatedCursorStorageScope(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed != value ||
      utf8.encode(value).length > maxChatRealtimeCursorStorageScopeUtf8Bytes ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
    throw ArgumentError(
      'cursorStorageScope must be a nonblank, trimmed host identity scope no '
      'larger than $maxChatRealtimeCursorStorageScopeUtf8Bytes UTF-8 bytes.',
    );
  }
  return value;
}

ConversationId _validatedConversationId(ConversationId conversationId) {
  final value = conversationId.value;
  if (value.trim().isEmpty ||
      value != value.trim() ||
      RegExp(r'^user:', caseSensitive: false).hasMatch(value) ||
      RegExp(r'[\u0000-\u0020\u007f*?]').hasMatch(value) ||
      RegExp(
        r'^(?:all|tenant|organization|org)(?::|/|$)',
        caseSensitive: false,
      ).hasMatch(value)) {
    throw ArgumentError.value(
      conversationId,
      'conversationId',
      'is not a valid conversation subscription identifier',
    );
  }
  return ConversationId(value);
}

String _encodeBearerProtocol(String token) {
  final encoded = base64Url.encode(utf8.encode(token)).replaceAll('=', '');
  return '$chatRealtimeBearerSubprotocolPrefix$encoded';
}

Uri _createWebSocketUri(Uri endpoint) {
  if (endpoint.userInfo.isNotEmpty) {
    throw ArgumentError.value(
        endpoint, 'endpoint', 'must not contain credentials');
  }
  if (endpoint.hasQuery || endpoint.hasFragment) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'must not contain a query or fragment',
    );
  }
  if (!const <String>{'', 'http', 'https', 'ws', 'wss'}
      .contains(endpoint.scheme.toLowerCase())) {
    throw ArgumentError.value(
        endpoint, 'endpoint', 'has an unsupported scheme');
  }
  final scheme = switch (endpoint.scheme.toLowerCase()) {
    'http' => 'ws',
    'https' => 'wss',
    final scheme => scheme,
  };
  final trimmedPath = endpoint.path.replaceFirst(RegExp(r'/+$'), '');
  final path = trimmedPath.isEmpty ? '/_realtime' : '$trimmedPath/_realtime';
  return endpoint.replace(scheme: scheme, path: path);
}

void _validateRetryOptions(ChatRealtimeRetryOptions retry) {
  if (retry.initialDelay.isNegative ||
      retry.maximumDelay.isNegative ||
      retry.maximumDelay < retry.initialDelay ||
      !retry.multiplier.isFinite ||
      retry.multiplier <= 0 ||
      !retry.jitterRatio.isFinite ||
      retry.jitterRatio < 0 ||
      retry.jitterRatio > 1) {
    throw ArgumentError.value(retry, 'retry', 'contains invalid values');
  }
}

void _validateEphemeralSignalOptions(
  ChatRealtimeEphemeralSignalOptions options,
) {
  void requirePositive(Duration value, String name, {int? maximumMs}) {
    final milliseconds = value.inMilliseconds;
    if (milliseconds < 1 || (maximumMs != null && milliseconds > maximumMs)) {
      throw ArgumentError.value(value, name, 'contains an invalid duration');
    }
  }

  requirePositive(
    options.typingTtl,
    'ephemeralSignals.typingTtl',
    maximumMs: maxTypingSignalTtlMs,
  );
  requirePositive(
    options.typingHeartbeat,
    'ephemeralSignals.typingHeartbeat',
  );
  requirePositive(options.typingIdle, 'ephemeralSignals.typingIdle');
  requirePositive(
    options.presenceTtl,
    'ephemeralSignals.presenceTtl',
    maximumMs: maxPresenceSignalTtlMs,
  );
  requirePositive(
    options.presenceHeartbeat,
    'ephemeralSignals.presenceHeartbeat',
  );
  requirePositive(options.presenceIdle, 'ephemeralSignals.presenceIdle');
  requirePositive(
    options.rateLimitWindow,
    'ephemeralSignals.rateLimitWindow',
  );
  if (options.typingHeartbeat >= options.typingTtl ||
      options.presenceHeartbeat >= options.presenceTtl ||
      options.rateLimitMaxSignals < 1) {
    throw ArgumentError.value(
      options,
      'ephemeralSignals',
      'contains invalid heartbeat or rate-limit values',
    );
  }
}

String _isoTimestamp(int millisecondsSinceEpoch) =>
    DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch, isUtc: true)
        .toIso8601String();

final class _SystemChatRealtimeTimer implements ChatRealtimeTimer {
  _SystemChatRealtimeTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final class _SystemChatRealtimeClock implements ChatRealtimeClock {
  const _SystemChatRealtimeClock();

  @override
  ChatRealtimeTimer schedule(Duration delay, void Function() callback) =>
      _SystemChatRealtimeTimer(Timer(delay, callback));
}

final class _SystemChatRealtimeEphemeralClock
    implements ChatRealtimeEphemeralClock {
  const _SystemChatRealtimeEphemeralClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  ChatRealtimeTimer schedule(Duration delay, void Function() callback) =>
      _SystemChatRealtimeTimer(Timer(delay, callback));
}

final class _AlwaysVisibleBoundary implements ChatRealtimeVisibility {
  const _AlwaysVisibleBoundary();

  @override
  bool get isVisible => true;

  @override
  void addListener(void Function() listener) {}

  @override
  void removeListener(void Function() listener) {}
}

final class _AlwaysOnlineNetwork implements ChatRealtimeNetwork {
  const _AlwaysOnlineNetwork();

  @override
  bool get isOnline => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}
