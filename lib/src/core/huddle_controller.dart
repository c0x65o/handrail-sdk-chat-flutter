part of '../handrail_chat_client.dart';

/// Canonical snapshot loading state for one huddle controller.
enum ChatHuddleHydrationStatus { idle, loading, ready, error }

/// Current authenticated actor's canonical participation, independent of media.
enum ChatHuddleActorParticipation {
  /// No trusted runtime identity is active; cached users are not identity.
  unknownIdentity,

  /// The controller/runtime is disposed, or a known actor has no live huddle.
  unavailable,

  /// The known actor has no participant entry in the live canonical huddle.
  absent,

  /// The known actor's live canonical participant entry is joined.
  joined,

  /// The known actor's live canonical participant entry is left.
  left,
}

/// Recovery disposition for a descriptor-free durable huddle command.
enum ChatHuddleRecoveryStatus { pending, conflict }

/// Stable, renderer-safe huddle failure categories.
enum ChatHuddleErrorCode {
  validation('validation'),
  authentication('authentication'),
  conflict('conflict'),
  featureDisabled('feature_disabled'),
  unsupported('unsupported'),
  rejected('rejected'),
  malformedResponse('malformed_response'),
  transport('transport'),
  aborted('aborted'),
  closed('closed');

  const ChatHuddleErrorCode(this.value);

  final String value;
}

/// Operations exposed by [ChatHuddleController].
enum ChatHuddleActionOperation {
  hydrate('hydrate'),
  start('start_huddle'),
  join('join_huddle'),
  leave('leave_huddle'),
  setScreenShare('set_huddle_screen_share'),
  end('end_huddle');

  const ChatHuddleActionOperation(this.value);

  final String value;
}

/// Why live canonical state needs fresh private media join material.
enum ChatHuddleRejoinReason {
  notJoined('not_joined'),
  descriptorExpired('descriptor_expired'),
  sessionReplaced('session_replaced');

  const ChatHuddleRejoinReason(this.value);

  final String value;
}

/// Public, descriptor-free media readiness state.
sealed class ChatHuddleMediaState {
  const ChatHuddleMediaState();

  String get state;

  @override
  String toString() => '$runtimeType(state: $state)';
}

final class ChatHuddleMediaIdleState extends ChatHuddleMediaState {
  const ChatHuddleMediaIdleState();

  @override
  String get state => 'idle';
}

final class ChatHuddleMediaReadyState extends ChatHuddleMediaState {
  const ChatHuddleMediaReadyState({
    required this.huddleSessionId,
    required this.expiresAt,
  });

  @override
  String get state => 'ready';

  final HuddleSessionId huddleSessionId;
  final IsoTimestamp expiresAt;
}

final class ChatHuddleMediaRejoinRequiredState extends ChatHuddleMediaState {
  const ChatHuddleMediaRejoinRequiredState({required this.reason});

  @override
  String get state => 'rejoin_required';

  final ChatHuddleRejoinReason reason;

  @override
  String toString() => '$runtimeType(state: $state, reason: ${reason.value})';
}

/// Typed state used when negotiated huddle/media capability is unavailable.
final class ChatHuddleMediaUnavailableState extends ChatHuddleMediaState {
  const ChatHuddleMediaUnavailableState();

  @override
  String get state => 'unavailable';

  String get reason => 'feature_disabled';
}

final class ChatHuddleMediaErrorState extends ChatHuddleMediaState {
  const ChatHuddleMediaErrorState({
    required this.code,
    required this.message,
    required this.retryable,
    this.httpStatus,
  });

  @override
  String get state => 'error';

  final ChatHuddleErrorCode code;
  final String message;
  final bool retryable;
  final int? httpStatus;

  @override
  String toString() => '$runtimeType(state: $state, code: ${code.value}, '
      'retryable: $retryable, httpStatus: $httpStatus)';
}

/// Immutable renderer state for one conversation's huddle.
final class ChatHuddleState {
  const ChatHuddleState({
    required this.conversationId,
    required this.canonicalState,
    required this.hydrationStatus,
    required this.media,
    this.pendingOperation,
    this.recoveryStatus,
    this.recoveryOperation,
  });

  final ConversationId conversationId;
  final HuddleSessionState canonicalState;
  final ChatHuddleHydrationStatus hydrationStatus;
  final ChatHuddleMediaState media;
  final ChatHuddleActionOperation? pendingOperation;
  final ChatHuddleRecoveryStatus? recoveryStatus;
  final ChatHuddleActionOperation? recoveryOperation;

  @override
  String toString() => 'ChatHuddleState('
      'conversationId: ${conversationId.value}, '
      'canonicalStatus: ${canonicalState.status.name}, '
      'hydrationStatus: ${hydrationStatus.name}, '
      'media: $media, pendingOperation: ${pendingOperation?.value}, '
      'recoveryStatus: ${recoveryStatus?.name}, '
      'recoveryOperation: ${recoveryOperation?.value})';
}

/// Per-action cancellation and optional caller-owned idempotency identity.
final class ChatHuddleActionOptions {
  const ChatHuddleActionOptions({
    this.idempotencyKey,
    this.cancellationSignal,
  });

  final String? idempotencyKey;
  final ChatCommandCancellationSignal? cancellationSignal;
}

sealed class ChatHuddleActionResult {
  const ChatHuddleActionResult({required this.operation});

  final ChatHuddleActionOperation operation;
  String get status;

  @override
  String toString() => '$runtimeType('
      'status: $status, operation: ${operation.value})';
}

final class ChatHuddleActionSuccess extends ChatHuddleActionResult {
  const ChatHuddleActionSuccess({
    required super.operation,
    required this.state,
    required this.applied,
    this.reconciliationStatus,
  });

  @override
  String get status => 'success';

  final HuddleSessionState state;
  final bool applied;
  final HuddleReconciliationStatus? reconciliationStatus;
}

/// Local or server-confirmed feature-disabled result that preserves state.
final class ChatHuddleActionFeatureDisabled extends ChatHuddleActionResult {
  const ChatHuddleActionFeatureDisabled({
    required super.operation,
    required this.state,
  });

  @override
  String get status => 'feature_disabled';

  final HuddleSessionState state;
  String get message => 'Huddle media is unavailable.';
}

final class ChatHuddleActionFailure extends ChatHuddleActionResult {
  const ChatHuddleActionFailure({
    required super.operation,
    required this.code,
    required this.message,
    required this.retryable,
    this.httpStatus,
  });

  @override
  String get status => 'error';

  final ChatHuddleErrorCode code;
  final String message;
  final bool retryable;
  final int? httpStatus;

  @override
  String toString() => '$runtimeType(status: $status, '
      'operation: ${operation.value}, code: ${code.value}, '
      'retryable: $retryable, httpStatus: $httpStatus)';
}

/// Wall-clock boundary used only to expire opaque join descriptors.
typedef ChatHuddleClock = DateTime Function();

/// Returns an idempotent callback that cancels a scheduled descriptor expiry.
typedef ChatHuddleTimerScheduler = void Function() Function(
  Duration delay,
  void Function() callback,
);

/// Computes the bounded delay before replaying an ambiguous huddle command.
typedef ChatHuddleRetryBackoff = Duration Function(int retryNumber);

/// Injectable cancellation-aware wait used by retained huddle recovery.
typedef ChatHuddleRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Descriptor-free identity-scoped view of one retained huddle command.
final class ChatQueuedHuddleCommand {
  const ChatQueuedHuddleCommand._({
    required this.identity,
    required this.request,
    required this.conversationId,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.status,
  });

  final ApplicationChatStorageIdentity identity;
  final HuddleCommandInput request;
  final ConversationId conversationId;
  final int enqueueOrder;
  final DateTime enqueuedAt;
  final ChatHuddleRecoveryStatus status;

  @override
  String toString() => 'ChatQueuedHuddleCommand('
      'conversationId: ${conversationId.value}, operation: ${request.operation}, '
      'enqueueOrder: $enqueueOrder, status: ${status.name})';
}

typedef _ChatHuddleConversationSubscriber
    = ChatRealtimeConversationSubscriptionRelease Function(
  ConversationId conversationId,
);

/// The only controller surface that can reveal opaque media join material.
///
/// The descriptor is never placed in [ChatHuddleState], action results,
/// diagnostics, serialization, errors, or `toString` output.
final class ChatHuddleMediaBoundary {
  ChatHuddleMediaBoundary._(this._controller);

  final ChatHuddleController _controller;

  HuddleMediaJoinDescriptor? readJoinDescriptor() =>
      _controller._readJoinDescriptor();

  @override
  String toString() => 'ChatHuddleMediaBoundary(hasDescriptor: '
      '${_controller._descriptor != null})';
}

/// Stable per-conversation huddle controller registry.
final class ChatHuddlesController {
  ChatHuddlesController._({
    required Uri apiBaseUri,
    required HandrailChatAccessTokenProvider tokenProvider,
    required HandrailChatHttpTransport transport,
    required ChatCommandDispatcher commandDispatcher,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
    required bool Function() isFeatureEnabled,
    required _ChatHuddleConversationSubscriber? subscribeConversation,
    required ChatHuddleClock clock,
    required ChatHuddleTimerScheduler scheduleTimer,
    required ApplicationChatStorage? storage,
    required NormalizedSnapshotStore normalizedState,
    required ChatHuddleRetryBackoff retryBackoff,
    required ChatHuddleRetryWait retryWait,
    required bool lifecycleManaged,
    required void Function(String code, String message) onStorageDiagnostic,
  })  : _apiBaseUri = apiBaseUri,
        _tokenProvider = tokenProvider,
        _transport = transport,
        _commandDispatcher = commandDispatcher,
        _generateIdempotencyKey = generateIdempotencyKey,
        _isFeatureEnabled = isFeatureEnabled,
        _subscribeConversation = subscribeConversation,
        _clock = clock,
        _scheduleTimer = scheduleTimer,
        _storage = storage,
        _normalizedState = normalizedState,
        _retryBackoff = retryBackoff,
        _retryWait = retryWait,
        _lifecycleManaged = lifecycleManaged,
        _onStorageDiagnostic = onStorageDiagnostic;

  final Uri _apiBaseUri;
  final HandrailChatAccessTokenProvider _tokenProvider;
  final HandrailChatHttpTransport _transport;
  final ChatCommandDispatcher _commandDispatcher;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final bool Function() _isFeatureEnabled;
  final _ChatHuddleConversationSubscriber? _subscribeConversation;
  final ChatHuddleClock _clock;
  final ChatHuddleTimerScheduler _scheduleTimer;
  final ApplicationChatStorage? _storage;
  final NormalizedSnapshotStore _normalizedState;
  final ChatHuddleRetryBackoff _retryBackoff;
  final ChatHuddleRetryWait _retryWait;
  final bool _lifecycleManaged;
  final void Function(String code, String message) _onStorageDiagnostic;
  final Map<ConversationId, ChatHuddleController> _controllers = {};
  final List<ChatQueuedHuddleCommand> _intents = [];
  final Map<ConversationId, Future<void>> _recoveryPumps = {};
  final Map<ConversationId, ChatCommandCancellationController> _retryWaits = {};
  Future<void> _storageMutation = Future<void>.value();
  ApplicationChatStorageIdentity? _identity;
  var _generation = 0;
  var _epoch = 0;
  var _metadataReady = false;
  var _connectivityOnline = false;
  var _realtimeConnected = false;
  var _applicationForeground = true;
  bool _disposed = false;

  List<ChatQueuedHuddleCommand> get queuedCommands =>
      List.unmodifiable(_intents);

  bool get _ready =>
      !_disposed &&
      _storage != null &&
      _identity != null &&
      _metadataReady &&
      _connectivityOnline &&
      _applicationForeground &&
      (!_lifecycleManaged || _realtimeConnected);

  /// Returns the same controller instance for a conversation until disposal.
  ChatHuddleController forConversation(ConversationId conversationId) =>
      _controllers.putIfAbsent(
        conversationId,
        () => ChatHuddleController._(
          conversationId: conversationId,
          apiBaseUri: _apiBaseUri,
          tokenProvider: _tokenProvider,
          transport: _transport,
          commandDispatcher: _commandDispatcher,
          generateIdempotencyKey: _generateIdempotencyKey,
          isFeatureEnabled: _isFeatureEnabled,
          subscribeConversation: _subscribeConversation,
          clock: _clock,
          scheduleTimer: _scheduleTimer,
          owner: this,
          initiallyDisposed: _disposed,
        ),
      );

  /// Applies already-ordered canonical event state to its stable controller.
  bool reconcileCanonicalState(HuddleSessionState state) {
    final accepted =
        forConversation(state.conversationId).reconcileCanonicalState(state);
    if (accepted) unawaited(_settleCanonicalState(state));
    return accepted;
  }

  void prepareActivation(
    ApplicationChatStorageIdentity identity, {
    required int generation,
  }) {
    if (_disposed) return;
    _invalidateWork();
    _identity = identity;
    _generation = generation;
    ++_epoch;
    _intents.clear();
    for (final controller in _controllers.values) {
      controller._resetForIdentityChange();
    }
  }

  Future<void> activate(
    ApplicationChatStorageIdentity identity, {
    required int generation,
  }) async {
    if (_storage == null || _disposed) return;
    if (_identity != identity || _generation != generation) {
      prepareActivation(identity, generation: generation);
    }
    final scope = _currentScope;
    if (scope == null) return;

    for (final state in _normalizedState.state.huddles.values) {
      if (!_scopeActive(scope)) return;
      forConversation(state.conversationId)._installHydratedCanonical(state);
    }

    await _serialized<void>(() async {
      if (!_scopeActive(scope)) return;
      ApplicationChatQueuedHuddleCommandIntentsRecord? record;
      try {
        record = await _readRecord(identity);
        if (!_scopeActive(scope)) return;
      } on FormatException {
        if (!_scopeActive(scope)) return;
        _diagnostic(
          ChatClientDiagnosticCode.huddleIntentsRejected,
          'The stored huddle-command intents were rejected and quarantined.',
        );
        return;
      } catch (_) {
        if (_scopeActive(scope)) {
          _diagnostic(
            ChatClientDiagnosticCode.huddleIntentsReadFailed,
            'The stored huddle-command intents could not be read.',
          );
        }
        return;
      }
      if (_scopeActive(scope)) _publish(record);
    });
    if (!_scopeActive(scope)) return;
    _refreshProjections();
    _startPumps();
  }

  void updateReadiness({
    required bool metadataReady,
    required bool connectivityOnline,
    required bool realtimeConnected,
    required bool applicationForeground,
  }) {
    if (_disposed) return;
    _metadataReady = metadataReady;
    _connectivityOnline = connectivityOnline;
    _realtimeConnected = realtimeConnected;
    _applicationForeground = applicationForeground;
    if (!_ready) {
      _invalidateWork();
      return;
    }
    _refreshProjections();
    _startPumps();
  }

  _HuddlePersistenceScope? get _currentScope {
    final identity = _identity;
    return identity == null
        ? null
        : _HuddlePersistenceScope(identity, _generation, _epoch);
  }

  bool _scopeActive(_HuddlePersistenceScope scope) =>
      !_disposed &&
      _identity == scope.identity &&
      _generation == scope.generation &&
      _epoch == scope.epoch;

  bool _needsMediaJoin(HuddleSessionState state) {
    if (state is! LiveHuddleState) return false;
    final actor = _identity?.userId;
    if (actor == null) return true;
    return state.participants.any(
      (participant) =>
          participant.userId == actor &&
          participant.status == HuddleParticipantStatus.joined,
    );
  }

  Future<_PersistedHuddleCommand?> _persist(
    ConversationId conversationId,
    HuddleCommandInput request,
  ) async {
    if (_storage == null) return const _PersistedHuddleCommand.ephemeral();
    final scope = _currentScope;
    if (scope == null || !_scopeActive(scope)) return null;
    return _serialized(() async {
      if (!_scopeActive(scope)) return null;
      try {
        final enqueuedAt = IsoTimestamp(_clock().toUtc().toIso8601String());
        final committed = await _mutateRecord(scope.identity, (current) {
          if (!_scopeActive(scope)) return current;
          final highest = current?.intents.fold<int>(
                0,
                (value, intent) => max(value, intent.enqueueOrder),
              ) ??
              0;
          final stored = ApplicationChatQueuedHuddleCommandIntent(
            request: request,
            conversationId: conversationId,
            enqueueOrder: highest + 1,
            enqueuedAt: enqueuedAt,
          );
          return ApplicationChatQueuedHuddleCommandIntentsRecord(
            identity: scope.identity,
            intents: [...?current?.intents, stored],
          );
        });
        if (!_scopeActive(scope)) return null;
        _publish(committed);
        final retained = _intents.where(
          (intent) => intent.request.idempotencyKey == request.idempotencyKey,
        );
        if (retained.isEmpty) return null;
        return _PersistedHuddleCommand(retained.single, scope);
      } catch (_) {
        if (_scopeActive(scope)) {
          _diagnostic(
            ChatClientDiagnosticCode.huddleIntentsWriteFailed,
            'The huddle command could not be stored before dispatch.',
          );
        }
        return null;
      }
    });
  }

  Future<bool> _remove(_PersistedHuddleCommand persisted) async {
    if (persisted.ephemeral) return true;
    final scope = persisted.scope!;
    if (!_scopeActive(scope)) return false;
    return _serialized(() async {
      if (!_scopeActive(scope)) return false;
      try {
        final intent = persisted.intent!;
        final committed = await _mutateRecord(scope.identity, (current) {
          if (!_scopeActive(scope) || current == null) return current;
          final remaining = current.intents
              .where((candidate) =>
                  candidate.conversationId != intent.conversationId ||
                  candidate.enqueueOrder != intent.enqueueOrder ||
                  DateTime.parse(candidate.enqueuedAt.value).toUtc() !=
                      intent.enqueuedAt ||
                  jsonEncode(candidate.request.toJson()) !=
                      jsonEncode(intent.request.toJson()))
              .toList(growable: false);
          if (remaining.length == current.intents.length) return current;
          return remaining.isEmpty
              ? null
              : ApplicationChatQueuedHuddleCommandIntentsRecord(
                  identity: scope.identity,
                  intents: remaining,
                );
        });
        if (!_scopeActive(scope)) return false;
        _publish(committed);
        // Absence is settled; a replacement reusing the key is not this
        // dispatch. Derive the outcome only from the committed retry.
        return !(committed?.intents.any((candidate) =>
                candidate.request.idempotencyKey ==
                intent.request.idempotencyKey) ??
            false);
      } catch (_) {
        if (_scopeActive(scope)) {
          _diagnostic(
            ChatClientDiagnosticCode.huddleIntentsWriteFailed,
            'A settled huddle command could not be removed from storage.',
          );
        }
        return false;
      }
    });
  }

  Future<bool> _settleResult(
    _PersistedHuddleCommand persisted,
    ChatHuddleActionResult result,
  ) async {
    if (persisted.ephemeral) return true;
    if (result is ChatHuddleActionSuccess ||
        result is ChatHuddleActionFeatureDisabled ||
        result is ChatHuddleActionFailure && _terminal(result)) {
      final removed = await _remove(persisted);
      final intent = persisted.intent;
      if (removed && intent != null) {
        forConversation(intent.conversationId)._clearRecovery(
          intent.request.operation,
        );
      }
      return removed;
    }
    if (result is ChatHuddleActionFailure &&
        result.code == ChatHuddleErrorCode.conflict) {
      _markConflict(persisted.intent!.request.idempotencyKey);
    }
    return false;
  }

  bool _terminal(ChatHuddleActionFailure result) =>
      result.code == ChatHuddleErrorCode.validation ||
      result.code == ChatHuddleErrorCode.authentication ||
      result.code == ChatHuddleErrorCode.featureDisabled ||
      result.code == ChatHuddleErrorCode.unsupported ||
      result.code == ChatHuddleErrorCode.rejected &&
          result.httpStatus != 408 &&
          result.httpStatus != 425 &&
          result.httpStatus != 429 ||
      result.httpStatus == 404;

  Future<void> _settleCanonicalState(HuddleSessionState state) async {
    final scope = _currentScope;
    if (scope == null || !_scopeActive(scope)) return;
    final candidates = _intents
        .where((intent) => intent.conversationId == state.conversationId)
        .toList(growable: false);
    for (final intent in candidates) {
      if (!_scopeActive(scope)) return;
      final decision =
          _authorityDecision(intent.request, state, scope.identity.userId);
      if (decision == _HuddleAuthorityDecision.conflict) {
        _markConflict(intent.request.idempotencyKey);
        continue;
      }
      if (decision != _HuddleAuthorityDecision.equal) continue;
      final persisted = _PersistedHuddleCommand(intent, scope);
      if (await _remove(persisted) && _scopeActive(scope)) {
        final controller = forConversation(intent.conversationId);
        controller._completeFromAuthority(
          intent.request.idempotencyKey,
          _operationForHuddleInput(intent.request),
          state,
        );
        controller._settledRecovered(intent.request);
      }
    }
    _startPumps();
  }

  void _startPumps() {
    if (!_ready) return;
    for (final conversationId
        in _intents.map((intent) => intent.conversationId).toSet()) {
      _startPump(conversationId);
    }
  }

  void _startPump(ConversationId conversationId) {
    if (!_ready || _recoveryPumps.containsKey(conversationId)) return;
    final scope = _currentScope;
    if (scope == null || _head(conversationId) == null) return;
    late final Future<void> pump;
    pump = _drain(scope, conversationId).whenComplete(() {
      if (identical(_recoveryPumps[conversationId], pump)) {
        _recoveryPumps.remove(conversationId);
      }
    });
    _recoveryPumps[conversationId] = pump;
    unawaited(pump);
  }

  Future<void> _drain(
    _HuddlePersistenceScope scope,
    ConversationId conversationId,
  ) async {
    var retryNumber = 0;
    while (_ready && _scopeActive(scope)) {
      final intent = _head(conversationId);
      if (intent == null ||
          intent.status == ChatHuddleRecoveryStatus.conflict) {
        return;
      }
      final persisted = _PersistedHuddleCommand(intent, scope);
      final controller = forConversation(conversationId);
      final cancellation = ChatCommandCancellationController();
      ChatHuddleActionResult hydrated;
      try {
        hydrated = await controller.hydrate(
          options: ChatHuddleActionOptions(
            cancellationSignal: cancellation.signal,
          ),
        );
      } finally {
        cancellation.cancel();
      }
      if (!_ready || !_scopeActive(scope)) return;
      if (hydrated is ChatHuddleActionSuccess) {
        final decision = _authorityDecision(
          intent.request,
          controller.state.canonicalState,
          scope.identity.userId,
        );
        if (decision == _HuddleAuthorityDecision.equal) {
          if (await _remove(persisted) && _scopeActive(scope)) {
            controller._settledRecovered(intent.request);
            retryNumber = 0;
            continue;
          }
        } else if (decision == _HuddleAuthorityDecision.conflict) {
          _markConflict(intent.request.idempotencyKey);
          return;
        } else {
          final result = await controller._executeRetained(persisted);
          if (!_scopeActive(scope)) return;
          if (result is ChatHuddleActionSuccess ||
              result is ChatHuddleActionFeatureDisabled) {
            retryNumber = 0;
            continue;
          }
          if (result is ChatHuddleActionFailure &&
              result.code == ChatHuddleErrorCode.conflict) {
            _markConflict(intent.request.idempotencyKey);
            return;
          }
        }
      } else if (hydrated is ChatHuddleActionFeatureDisabled ||
          hydrated is ChatHuddleActionFailure && _terminal(hydrated)) {
        if (await _remove(persisted) && _scopeActive(scope)) {
          controller._clearRecovery(intent.request.operation);
          retryNumber = 0;
          continue;
        }
      }
      retryNumber += 1;
      if (!await _waitBeforeRetry(scope, conversationId, retryNumber)) return;
    }
  }

  Future<bool> _waitBeforeRetry(
    _HuddlePersistenceScope scope,
    ConversationId conversationId,
    int retryNumber,
  ) async {
    late final Duration delay;
    try {
      delay = _retryBackoff(retryNumber);
      if (delay.isNegative || delay > const Duration(seconds: 60)) return false;
    } catch (_) {
      return false;
    }
    final cancellation = ChatCommandCancellationController();
    _retryWaits[conversationId] = cancellation;
    if (!_ready || !_scopeActive(scope)) {
      cancellation.cancel();
      return false;
    }
    try {
      await _raceHuddleOperation(
        Future<void>.sync(() => _retryWait(delay, cancellation.signal)),
        cancellation.signal,
      );
      return _ready && _scopeActive(scope);
    } catch (_) {
      return false;
    } finally {
      if (identical(_retryWaits[conversationId], cancellation)) {
        _retryWaits.remove(conversationId);
      }
    }
  }

  ChatQueuedHuddleCommand? _head(ConversationId conversationId) {
    for (final intent in _intents) {
      if (intent.conversationId == conversationId) return intent;
    }
    return null;
  }

  void _refreshProjections() {
    for (final intent in _intents) {
      final controller = forConversation(intent.conversationId);
      if (controller.state.hydrationStatus != ChatHuddleHydrationStatus.ready) {
        controller._markRecovery(
          intent.request.operation,
          ChatHuddleRecoveryStatus.pending,
        );
        continue;
      }
      final decision = _authorityDecision(
        intent.request,
        controller.state.canonicalState,
        _identity!.userId,
      );
      if (decision == _HuddleAuthorityDecision.conflict) {
        _markConflict(intent.request.idempotencyKey);
      } else {
        controller._markRecovery(intent.request.operation, intent.status);
      }
    }
  }

  void _markConflict(String idempotencyKey) {
    final index = _intents.indexWhere(
      (intent) => intent.request.idempotencyKey == idempotencyKey,
    );
    if (index < 0) return;
    final intent = _intents[index];
    if (intent.status != ChatHuddleRecoveryStatus.conflict) {
      _intents[index] = ChatQueuedHuddleCommand._(
        identity: intent.identity,
        request: intent.request,
        conversationId: intent.conversationId,
        enqueueOrder: intent.enqueueOrder,
        enqueuedAt: intent.enqueuedAt,
        status: ChatHuddleRecoveryStatus.conflict,
      );
    }
    forConversation(intent.conversationId)._markRecovery(
      intent.request.operation,
      ChatHuddleRecoveryStatus.conflict,
    );
  }

  void _publish(ApplicationChatQueuedHuddleCommandIntentsRecord? record) {
    final identity = _identity;
    if (identity == null) return;
    final priorStatuses = <String, ChatHuddleRecoveryStatus>{
      for (final intent in _intents)
        intent.request.idempotencyKey: intent.status,
    };
    _intents
      ..clear()
      ..addAll([
        for (final intent in record?.intents ??
            const <ApplicationChatQueuedHuddleCommandIntent>[])
          ChatQueuedHuddleCommand._(
            identity: identity,
            request: intent.request,
            conversationId: intent.conversationId,
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: DateTime.parse(intent.enqueuedAt.value).toUtc(),
            status: priorStatuses[intent.request.idempotencyKey] ??
                ChatHuddleRecoveryStatus.pending,
          ),
      ]);
  }

  Future<ApplicationChatQueuedHuddleCommandIntentsRecord?> _readRecord(
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateRecord(identity, (current) => current);

  Future<ApplicationChatQueuedHuddleCommandIntentsRecord?> _mutateRecord(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageUpdater<
            ApplicationChatQueuedHuddleCommandIntentsRecord>
        updater,
  ) =>
      ApplicationChatStorageMutator(_storage!)
          .mutate<ApplicationChatQueuedHuddleCommandIntentsRecord>(
        identity,
        ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        updater,
      );

  Future<Result> _serialized<Result>(Future<Result> Function() operation) {
    final completer = Completer<Result>();
    _storageMutation = _storageMutation.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _invalidateWork() {
    ++_epoch;
    for (final cancellation in _retryWaits.values) {
      cancellation.cancel();
    }
    _retryWaits.clear();
    for (final controller in _controllers.values) {
      controller._cancelForRecoveryPause();
    }
  }

  void _diagnostic(String code, String message) {
    try {
      _onStorageDiagnostic(code, message);
    } catch (_) {
      // Diagnostics cannot alter huddle recovery.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    _invalidateWork();
    _identity = null;
    _intents.clear();
    await Future.wait(
      _controllers.values.map((controller) => controller.dispose()),
    );
  }
}

final class _HuddlePersistenceScope {
  const _HuddlePersistenceScope(this.identity, this.generation, this.epoch);
  final ApplicationChatStorageIdentity identity;
  final int generation;
  final int epoch;
}

final class _PersistedHuddleCommand {
  const _PersistedHuddleCommand(this.intent, this.scope) : ephemeral = false;
  const _PersistedHuddleCommand.ephemeral()
      : intent = null,
        scope = null,
        ephemeral = true;
  final ChatQueuedHuddleCommand? intent;
  final _HuddlePersistenceScope? scope;
  final bool ephemeral;
}

enum _HuddleAuthorityDecision { equal, replay, conflict }

final class _HuddleOperationInterrupted implements Exception {
  const _HuddleOperationInterrupted();
}

final class _HuddleAuthenticationInterrupted implements Exception {
  const _HuddleAuthenticationInterrupted();
}

/// Framework-neutral lifecycle orchestration for one conversation huddle.
final class ChatHuddleController {
  ChatHuddleController._({
    required this.conversationId,
    required Uri apiBaseUri,
    required HandrailChatAccessTokenProvider tokenProvider,
    required HandrailChatHttpTransport transport,
    required ChatCommandDispatcher commandDispatcher,
    required ChatCommandIdempotencyKeyGenerator generateIdempotencyKey,
    required bool Function() isFeatureEnabled,
    required _ChatHuddleConversationSubscriber? subscribeConversation,
    required ChatHuddleClock clock,
    required ChatHuddleTimerScheduler scheduleTimer,
    required ChatHuddlesController owner,
    required bool initiallyDisposed,
  })  : _apiBaseUri = apiBaseUri,
        _tokenProvider = tokenProvider,
        _transport = transport,
        _commandDispatcher = commandDispatcher,
        _generateIdempotencyKey = generateIdempotencyKey,
        _isFeatureEnabled = isFeatureEnabled,
        _subscribeConversation = subscribeConversation,
        _clock = clock,
        _scheduleTimer = scheduleTimer,
        _owner = owner,
        _state = ChatHuddleState(
          conversationId: conversationId,
          canonicalState: InactiveHuddleState(
            conversationId: conversationId,
          ),
          hydrationStatus: ChatHuddleHydrationStatus.idle,
          media: const ChatHuddleMediaIdleState(),
        ),
        _disposed = initiallyDisposed {
    mediaBoundary = ChatHuddleMediaBoundary._(this);
    _states = _createStateStream();
    if (initiallyDisposed) unawaited(_stateChanges.close());
  }

  final ConversationId conversationId;
  final Uri _apiBaseUri;
  final HandrailChatAccessTokenProvider _tokenProvider;
  final HandrailChatHttpTransport _transport;
  final ChatCommandDispatcher _commandDispatcher;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final bool Function() _isFeatureEnabled;
  final _ChatHuddleConversationSubscriber? _subscribeConversation;
  final ChatHuddleClock _clock;
  final ChatHuddleTimerScheduler _scheduleTimer;
  final ChatHuddlesController _owner;
  final StreamController<ChatHuddleState> _stateChanges =
      StreamController<ChatHuddleState>.broadcast(sync: true);
  final Set<ChatCommandCancellationController> _activeCancellations = {};
  final Set<Future<void>> _commandDrains = {};
  final Map<String, Completer<ChatHuddleActionSuccess>> _authoritySettlements =
      {};
  late final Stream<ChatHuddleState> _states;
  late final ChatHuddleMediaBoundary mediaBoundary;
  ChatHuddleState _state;
  Future<ChatHuddleActionResult>? _hydration;
  Future<void> _commandTail = Future<void>.value();
  HuddleMediaJoinDescriptor? _descriptor;
  HuddleSessionId? _descriptorSessionId;
  void Function()? _cancelDescriptorTimer;
  ChatRealtimeConversationSubscriptionRelease? _releaseRealtime;
  var _observerCount = 0;
  var _watermark = 0;
  bool _disposed;

  ChatHuddleState get state => _state;

  /// Projects current canonical participation using only the trusted runtime
  /// identity. Reads do not hydrate, dispatch commands, or access media material.
  /// This is participation evidence, not a permission or media-readiness check.
  ///
  /// Disposal takes precedence and returns [ChatHuddleActorParticipation.unavailable]
  /// even if [state] retains a live snapshot. Otherwise missing identity returns
  /// [ChatHuddleActorParticipation.unknownIdentity]. For a known actor, inactive
  /// and ended snapshots return [ChatHuddleActorParticipation.unavailable]; only
  /// live snapshots (starting or active) project participant entries.
  /// Identity activation resets canonical state before projecting the new actor.
  ChatHuddleActorParticipation get currentActorParticipation {
    if (_disposed || _owner._disposed) {
      return ChatHuddleActorParticipation.unavailable;
    }
    final actor = _owner._identity?.userId;
    if (actor == null) return ChatHuddleActorParticipation.unknownIdentity;
    final canonical = _state.canonicalState;
    if (canonical is! LiveHuddleState) {
      return ChatHuddleActorParticipation.unavailable;
    }
    for (final participant in canonical.participants) {
      if (participant.userId == actor) {
        return switch (participant.status) {
          HuddleParticipantStatus.joined => ChatHuddleActorParticipation.joined,
          HuddleParticipantStatus.left => ChatHuddleActorParticipation.left,
        };
      }
    }
    return ChatHuddleActorParticipation.absent;
  }

  /// A broadcast stream that gives every observer the current state first.
  /// The first observer retains one realtime conversation subscription and the
  /// final observer releases it.
  Stream<ChatHuddleState> get states => _states;

  Future<ChatHuddleActionResult> hydrate({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    if (_disposed) {
      return Future.value(_closed(ChatHuddleActionOperation.hydrate));
    }
    final disabled = _featureDisabled(ChatHuddleActionOperation.hydrate);
    if (disabled != null) return Future.value(disabled);
    final active = _hydration;
    if (active != null) return active;

    late final Future<ChatHuddleActionResult> request;
    request = _hydrate(options).whenComplete(() {
      if (identical(_hydration, request)) _hydration = null;
    });
    _hydration = request;
    return request;
  }

  Future<ChatHuddleActionResult> start({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    if (_state.canonicalState is! InactiveHuddleState) {
      return Future.value(_validation(ChatHuddleActionOperation.start));
    }
    return _enqueue(
      ChatHuddleActionOperation.start,
      (key) => StartHuddleInput(
        conversationId: conversationId,
        idempotencyKey: key,
      ),
      options,
    );
  }

  Future<ChatHuddleActionResult> join({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    final canonical = _state.canonicalState;
    if (canonical is! LiveHuddleState) {
      return Future.value(_validation(ChatHuddleActionOperation.join));
    }
    return _enqueue(
      ChatHuddleActionOperation.join,
      (key) => JoinHuddleInput(
        huddleSessionId: canonical.huddleSessionId,
        idempotencyKey: key,
      ),
      options,
    );
  }

  Future<ChatHuddleActionResult> leave({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    final canonical = _state.canonicalState;
    if (canonical is! ActiveHuddleState) {
      return Future.value(_validation(ChatHuddleActionOperation.leave));
    }
    return _enqueue(
      ChatHuddleActionOperation.leave,
      (key) => LeaveHuddleInput(
        huddleSessionId: canonical.huddleSessionId,
        idempotencyKey: key,
      ),
      options,
    );
  }

  Future<ChatHuddleActionResult> setScreenShare(
    HuddleScreenShareIntent intent, {
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    final canonical = _state.canonicalState;
    if (canonical is! ActiveHuddleState) {
      return Future.value(
        _validation(ChatHuddleActionOperation.setScreenShare),
      );
    }
    return _enqueue(
      ChatHuddleActionOperation.setScreenShare,
      (key) => SetHuddleScreenShareInput(
        huddleSessionId: canonical.huddleSessionId,
        intent: intent,
        idempotencyKey: key,
      ),
      options,
    );
  }

  Future<ChatHuddleActionResult> clearScreenShare({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) =>
      setScreenShare(HuddleScreenShareIntent.clear, options: options);

  Future<ChatHuddleActionResult> end({
    ChatHuddleActionOptions options = const ChatHuddleActionOptions(),
  }) {
    final canonical = _state.canonicalState;
    if (canonical is! LiveHuddleState) {
      return Future.value(_validation(ChatHuddleActionOperation.end));
    }
    return _enqueue(
      ChatHuddleActionOperation.end,
      (key) => EndHuddleInput(
        huddleSessionId: canonical.huddleSessionId,
        idempotencyKey: key,
      ),
      options,
    );
  }

  /// Accepts canonical state only after an ordered event reducer selects it.
  /// Calling this method advances the response watermark, so older hydration
  /// and command responses cannot replace the event state.
  bool reconcileCanonicalState(HuddleSessionState next) {
    if (_disposed || next.conversationId != conversationId) return false;
    late final HuddleSessionState validated;
    try {
      validated = HuddleSessionState.fromJson(next.toJson());
    } catch (_) {
      return false;
    }
    _watermark += 1;
    _setCanonical(validated, eventReconciliation: true);
    return true;
  }

  Future<ChatHuddleActionResult> _hydrate(
    ChatHuddleActionOptions options,
  ) async {
    final operation = ChatHuddleActionOperation.hydrate;
    final expectedWatermark = _watermark;
    _emit(_copyState(hydrationStatus: ChatHuddleHydrationStatus.loading));
    final active = ChatCommandCancellationController();
    _activeCancellations.add(active);
    final callerSubscription = _forwardCancellation(
      options.cancellationSignal,
      active,
    );

    ChatHuddleActionResult result;
    try {
      if (active.signal.isCancelled) throw const _HuddleOperationInterrupted();
      final token = await _raceHuddleOperation(
        _resolveAccessToken(),
        active.signal,
      );
      if (token.trim().isEmpty) {
        result = _failure(
          operation,
          ChatHuddleErrorCode.authentication,
          retryable: true,
        );
      } else {
        final response = await _raceHuddleOperation(
          _transport.send(
            HandrailChatHttpRequest(
              method: 'GET',
              uri: _snapshotEndpointUri(
                _apiBaseUri,
                <String>[
                  'conversations',
                  conversationId.value,
                  'huddle',
                ],
              ),
              headers: <String, String>{
                'Accept': 'application/json',
                'Authorization': 'Bearer $token',
              },
              cancellationSignal: active.signal,
            ),
          ),
          active.signal,
        );
        result = _parseHydrationResponse(response, expectedWatermark);
      }
    } on _HuddleOperationInterrupted {
      result = _disposed ? _closed(operation) : _aborted(operation);
    } on _HuddleAuthenticationInterrupted {
      result = _failure(
        operation,
        ChatHuddleErrorCode.authentication,
        retryable: true,
      );
    } catch (_) {
      result = _failure(
        operation,
        ChatHuddleErrorCode.transport,
        retryable: true,
      );
    } finally {
      await callerSubscription?.cancel();
      _activeCancellations.remove(active);
    }

    if (!_disposed) {
      _emit(
        _copyState(
          hydrationStatus: result is ChatHuddleActionFailure
              ? ChatHuddleHydrationStatus.error
              : ChatHuddleHydrationStatus.ready,
          media: result is ChatHuddleActionFailure
              ? _mediaError(result)
              : _mediaAfterCanonical(_state.canonicalState),
        ),
      );
    }
    return result;
  }

  Future<String> _resolveAccessToken() async {
    try {
      return await _tokenProvider();
    } catch (_) {
      throw const _HuddleAuthenticationInterrupted();
    }
  }

  ChatHuddleActionResult _parseHydrationResponse(
    HandrailChatHttpResponse response,
    int expectedWatermark,
  ) {
    const operation = ChatHuddleActionOperation.hydrate;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        return _failure(
          operation,
          ChatHuddleErrorCode.authentication,
          retryable: true,
          httpStatus: response.statusCode,
        );
      }
      return _failure(
        operation,
        response.statusCode >= 500
            ? ChatHuddleErrorCode.transport
            : ChatHuddleErrorCode.rejected,
        retryable: response.statusCode >= 500,
        httpStatus: response.statusCode,
      );
    }
    try {
      final snapshot = HuddleSessionState.fromJson(jsonDecode(response.body));
      if (snapshot.conversationId != conversationId) {
        throw const FormatException();
      }
      final applied = _applyCanonical(expectedWatermark, snapshot);
      return ChatHuddleActionSuccess(
        operation: operation,
        state: _state.canonicalState,
        applied: applied,
      );
    } catch (_) {
      return _failure(
        operation,
        ChatHuddleErrorCode.malformedResponse,
        retryable: true,
        httpStatus: response.statusCode,
      );
    }
  }

  Future<ChatHuddleActionResult> _enqueue(
    ChatHuddleActionOperation operation,
    HuddleCommandInput Function(String idempotencyKey) createInput,
    ChatHuddleActionOptions options,
  ) {
    if (_disposed) return Future.value(_closed(operation));
    final disabled = _featureDisabled(operation);
    if (disabled != null) return Future.value(disabled);

    late final HuddleCommandInput input;
    try {
      input = createInput(
        options.idempotencyKey ?? _generateIdempotencyKey(),
      );
      HuddleCommandInput.fromJson(input.toJson());
    } catch (_) {
      return Future.value(_validation(operation));
    }

    final completer = Completer<ChatHuddleActionResult>();
    final previous = _commandTail;
    late final Future<void> drain;
    drain = previous.then((_) async {
      if (options.cancellationSignal?.isCancelled == true) {
        completer.complete(_aborted(operation));
        return;
      }
      if (_disposed) {
        completer.complete(_closed(operation));
        return;
      }
      completer.complete(await _executeCommand(operation, input, options));
    }, onError: (_) async {
      if (!completer.isCompleted) {
        completer.complete(await _executeCommand(operation, input, options));
      }
    }).whenComplete(() {
      _commandDrains.remove(drain);
    });
    _commandDrains.add(drain);
    _commandTail = drain;
    return completer.future;
  }

  Future<ChatHuddleActionResult> _executeCommand(
    ChatHuddleActionOperation operation,
    HuddleCommandInput input,
    ChatHuddleActionOptions options, {
    _PersistedHuddleCommand? retained,
  }) async {
    if (_disposed) return _closed(operation);
    final recovering = retained != null;
    final disabled = _featureDisabled(operation);
    if (disabled != null) return disabled;
    final persisted = retained ?? await _owner._persist(conversationId, input);
    if (persisted == null) {
      return _owner._disposed
          ? _closed(operation)
          : _failure(
              operation,
              ChatHuddleErrorCode.transport,
              retryable: true,
            );
    }
    if (options.cancellationSignal?.isCancelled == true) {
      await _owner._remove(persisted);
      return _aborted(operation);
    }
    if (_disposed ||
        (!persisted.ephemeral && !_owner._scopeActive(persisted.scope!))) {
      return _closed(operation);
    }
    final previousState = _state.canonicalState;
    final expectedWatermark = ++_watermark;
    final active = ChatCommandCancellationController();
    _activeCancellations.add(active);
    final callerSubscription = _forwardCancellation(
      options.cancellationSignal,
      active,
    );
    if (operation == ChatHuddleActionOperation.leave ||
        operation == ChatHuddleActionOperation.end) {
      _clearDescriptor();
    }
    _emit(_copyState(pendingOperation: operation, clearPending: false));

    final authority = Completer<ChatHuddleActionSuccess>();
    _authoritySettlements[input.idempotencyKey] = authority;
    late final ChatCommandResult<HuddleCommandResult> dispatched;
    try {
      final dispatch = _commandDispatcher.dispatch(
        _huddleCommandDescriptor(input, _clock),
        input,
        options: ChatCommandDispatchOptions(
          idempotencyKey: input.idempotencyKey,
          cancellationSignal: active.signal,
        ),
      );
      final outcome = await Future.any<Object>(<Future<Object>>[
        dispatch,
        authority.future,
      ]);
      if (outcome is ChatHuddleActionSuccess) {
        active.cancel();
        unawaited(dispatch);
        return outcome;
      }
      dispatched = outcome as ChatCommandResult<HuddleCommandResult>;
    } finally {
      if (identical(_authoritySettlements[input.idempotencyKey], authority)) {
        _authoritySettlements.remove(input.idempotencyKey);
      }
      await callerSubscription?.cancel();
      _activeCancellations.remove(active);
    }
    if (_disposed ||
        (!persisted.ephemeral && !_owner._scopeActive(persisted.scope!))) {
      return _closed(operation);
    }
    _emit(_copyState(clearPending: true));

    if (dispatched is! ChatCommandSuccess<HuddleCommandResult>) {
      final failure = _mapCommandFailure(operation, dispatched);
      if (operation == ChatHuddleActionOperation.start ||
          operation == ChatHuddleActionOperation.join ||
          operation == ChatHuddleActionOperation.leave ||
          operation == ChatHuddleActionOperation.end) {
        _clearDescriptor();
        _emit(_copyState(media: _mediaError(failure)));
      }
      await _owner._settleResult(persisted, failure);
      return failure;
    }

    final command = dispatched.value;
    if (command is HuddleFeatureDisabledResult) {
      if (!_sameHuddleState(previousState, command.state)) {
        final failure = _failure(
          operation,
          ChatHuddleErrorCode.malformedResponse,
          retryable: true,
        );
        _clearDescriptor();
        _emit(_copyState(media: _mediaError(failure)));
        await _owner._settleResult(persisted, failure);
        return failure;
      }
      _clearDescriptor();
      _applyCanonical(expectedWatermark, command.state);
      _emit(_copyState(media: const ChatHuddleMediaUnavailableState()));
      final result = ChatHuddleActionFeatureDisabled(
        operation: operation,
        state: _state.canonicalState,
      );
      await _owner._settleResult(persisted, result);
      return result;
    }

    if (_watermark == expectedWatermark &&
        command.reconciliationStatus == HuddleReconciliationStatus.applied) {
      try {
        if (input is StartHuddleInput) {
          validateHuddleStateTransition(previousState, command.state, input);
        } else if (!_matchesHttpCommandOutcome(input, command.state)) {
          throw const FormatException('Huddle command outcome mismatch');
        }
      } catch (_) {
        final failure = _failure(
          operation,
          ChatHuddleErrorCode.malformedResponse,
          retryable: true,
        );
        _clearDescriptor();
        _emit(_copyState(media: _mediaError(failure)));
        await _owner._settleResult(persisted, failure);
        return failure;
      }
    }

    final applied = _applyCanonical(expectedWatermark, command.state);
    if (applied && command is StartHuddleResult && !recovering) {
      _storeDescriptor(
        (command.state as StartingHuddleState).huddleSessionId,
        command.mediaJoin,
      );
    } else if (applied && command is JoinHuddleResult && !recovering) {
      _storeDescriptor(
        (command.state as ActiveHuddleState).huddleSessionId,
        command.mediaJoin,
      );
    }
    final result = ChatHuddleActionSuccess(
      operation: operation,
      state: _state.canonicalState,
      applied: applied,
      reconciliationStatus: command.reconciliationStatus,
    );
    await _owner._settleResult(persisted, result);
    if (recovering) _settledRecovered(input);
    return result;
  }

  bool _matchesHttpCommandOutcome(
    HuddleCommandInput input,
    HuddleSessionState state,
  ) {
    // HTTP snapshots may include unseen mutations by other participants. Check
    // the requested outcome; exact deltas require a server transaction snapshot.
    final sessionId = switch (state) {
      LiveHuddleState(:final huddleSessionId) => huddleSessionId,
      EndedHuddleState(:final huddleSessionId) => huddleSessionId,
      _ => null,
    };
    if (state.conversationId != conversationId ||
        sessionId != (input as SessionHuddleInput).huddleSessionId) {
      return false;
    }
    if (input is EndHuddleInput) return state is EndedHuddleState;
    if (state is! ActiveHuddleState) return false;

    final cached = _owner._normalizedState.state;
    final actor = _owner._identity?.userId ??
        cached.currentUserReadStates[conversationId]?.userId ??
        cached.currentUserPreferences[conversationId]?.userId;
    if (input is JoinHuddleInput || input is LeaveHuddleInput) {
      final expectedStatus = input is JoinHuddleInput
          ? HuddleParticipantStatus.joined
          : HuddleParticipantStatus.left;
      return actor != null &&
          state.participants.any((participant) =>
              participant.userId == actor &&
              participant.status == expectedStatus);
    }
    final share = input as SetHuddleScreenShareInput;
    return share.intent == HuddleScreenShareIntent.clear
        ? state.screenShareOwnerUserId == null
        : actor != null && state.screenShareOwnerUserId == actor;
  }

  Future<ChatHuddleActionResult> _executeRetained(
    _PersistedHuddleCommand persisted,
  ) {
    final request = persisted.intent!.request;
    return _executeCommand(
      _operationForHuddleInput(request),
      request,
      const ChatHuddleActionOptions(),
      retained: persisted,
    );
  }

  void _completeFromAuthority(
    String idempotencyKey,
    ChatHuddleActionOperation operation,
    HuddleSessionState canonical,
  ) {
    final completer = _authoritySettlements.remove(idempotencyKey);
    if (completer == null || completer.isCompleted) return;
    completer.complete(ChatHuddleActionSuccess(
      operation: operation,
      state: canonical,
      applied: false,
      reconciliationStatus: HuddleReconciliationStatus.replayed,
    ));
  }

  void _installHydratedCanonical(HuddleSessionState canonical) {
    if (_disposed || canonical.conversationId != conversationId) return;
    ++_watermark;
    _setCanonical(canonical, eventReconciliation: true);
    _emit(_copyState(hydrationStatus: ChatHuddleHydrationStatus.ready));
  }

  void _markRecovery(
    String operation,
    ChatHuddleRecoveryStatus status,
  ) {
    if (_disposed) return;
    final action = _operationForWireValue(operation);
    _emit(_copyState(
      pendingOperation:
          status == ChatHuddleRecoveryStatus.pending ? action : null,
      clearPending: status == ChatHuddleRecoveryStatus.conflict,
      recoveryStatus: status,
      recoveryOperation: action,
    ));
  }

  void _clearRecovery(String operation) {
    if (_disposed ||
        _state.recoveryStatus == null ||
        _state.pendingOperation != null &&
            _state.pendingOperation != _operationForWireValue(operation)) {
      return;
    }
    _emit(_copyState(clearPending: true, clearRecovery: true));
  }

  void _settledRecovered(HuddleCommandInput request) {
    _clearRecovery(request.operation);
    if ((request is StartHuddleInput || request is JoinHuddleInput) &&
        _owner._needsMediaJoin(_state.canonicalState)) {
      _clearDescriptor();
      _emit(_copyState(
        media: const ChatHuddleMediaRejoinRequiredState(
          reason: ChatHuddleRejoinReason.notJoined,
        ),
      ));
    }
  }

  void _cancelForRecoveryPause() {
    for (final cancellation in _activeCancellations.toList(growable: false)) {
      cancellation.cancel();
    }
  }

  void _resetForIdentityChange() {
    if (_disposed) return;
    ++_watermark;
    _cancelForRecoveryPause();
    _authoritySettlements.clear();
    _clearDescriptor();
    _emit(ChatHuddleState(
      conversationId: conversationId,
      canonicalState: InactiveHuddleState(conversationId: conversationId),
      hydrationStatus: ChatHuddleHydrationStatus.idle,
      media: const ChatHuddleMediaIdleState(),
    ));
  }

  ChatHuddleActionFeatureDisabled? _featureDisabled(
    ChatHuddleActionOperation operation,
  ) {
    if (_isFeatureEnabled()) return null;
    _clearDescriptor();
    _emit(_copyState(media: const ChatHuddleMediaUnavailableState()));
    return ChatHuddleActionFeatureDisabled(
      operation: operation,
      state: _state.canonicalState,
    );
  }

  bool _applyCanonical(int expectedWatermark, HuddleSessionState next) {
    if (_disposed || expectedWatermark != _watermark) return false;
    _setCanonical(next);
    return true;
  }

  void _setCanonical(
    HuddleSessionState next, {
    bool eventReconciliation = false,
  }) {
    final previous = _state.canonicalState;
    var media = _state.media;
    final storedSession = _descriptorSessionId;
    final nextSession = next is LiveHuddleState ? next.huddleSessionId : null;
    if (storedSession != null && storedSession != nextSession) {
      _clearDescriptor();
      media = next is LiveHuddleState
          ? const ChatHuddleMediaRejoinRequiredState(
              reason: ChatHuddleRejoinReason.sessionReplaced,
            )
          : const ChatHuddleMediaIdleState();
    } else if (next is! LiveHuddleState) {
      _clearDescriptor();
      media = const ChatHuddleMediaIdleState();
    } else if (storedSession != null && !_owner._needsMediaJoin(next)) {
      _clearDescriptor();
      media = const ChatHuddleMediaIdleState();
    } else if (_descriptor == null &&
        (media is ChatHuddleMediaIdleState ||
            media is ChatHuddleMediaReadyState ||
            media is ChatHuddleMediaErrorState ||
            eventReconciliation)) {
      media = _owner._needsMediaJoin(next)
          ? const ChatHuddleMediaRejoinRequiredState(
              reason: ChatHuddleRejoinReason.notJoined,
            )
          : const ChatHuddleMediaIdleState();
    }
    if (_sameHuddleState(previous, next) && identical(media, _state.media)) {
      return;
    }
    _emit(_copyState(canonicalState: next, media: media));
  }

  ChatHuddleMediaState _mediaAfterCanonical(HuddleSessionState canonical) {
    if (_state.media is ChatHuddleMediaUnavailableState) return _state.media;
    if (canonical is LiveHuddleState) {
      if (_descriptor != null &&
          _descriptorSessionId == canonical.huddleSessionId) {
        return ChatHuddleMediaReadyState(
          huddleSessionId: canonical.huddleSessionId,
          expiresAt: _descriptor!.expiresAt,
        );
      }
      return _owner._needsMediaJoin(canonical)
          ? const ChatHuddleMediaRejoinRequiredState(
              reason: ChatHuddleRejoinReason.notJoined,
            )
          : const ChatHuddleMediaIdleState();
    }
    return const ChatHuddleMediaIdleState();
  }

  void _storeDescriptor(
    HuddleSessionId sessionId,
    HuddleMediaJoinDescriptor descriptor,
  ) {
    _clearDescriptor();
    final delay =
        DateTime.parse(descriptor.expiresAt.value).difference(_clock());
    if (delay <= Duration.zero) {
      _emit(
        _copyState(
          media: const ChatHuddleMediaRejoinRequiredState(
            reason: ChatHuddleRejoinReason.descriptorExpired,
          ),
        ),
      );
      return;
    }
    _descriptor = descriptor;
    _descriptorSessionId = sessionId;
    try {
      _cancelDescriptorTimer = _scheduleTimer(delay, () {
        if (_descriptor != descriptor) return;
        _descriptor = null;
        _descriptorSessionId = null;
        _cancelDescriptorTimer = null;
        if (!_disposed) {
          _emit(
            _copyState(
              media: _state.canonicalState is LiveHuddleState
                  ? const ChatHuddleMediaRejoinRequiredState(
                      reason: ChatHuddleRejoinReason.descriptorExpired,
                    )
                  : const ChatHuddleMediaIdleState(),
            ),
          );
        }
      });
    } catch (_) {
      _descriptor = null;
      _descriptorSessionId = null;
      _emit(
        _copyState(
          media: const ChatHuddleMediaRejoinRequiredState(
            reason: ChatHuddleRejoinReason.descriptorExpired,
          ),
        ),
      );
      return;
    }
    _emit(
      _copyState(
        media: ChatHuddleMediaReadyState(
          huddleSessionId: sessionId,
          expiresAt: descriptor.expiresAt,
        ),
      ),
    );
  }

  HuddleMediaJoinDescriptor? _readJoinDescriptor() {
    final descriptor = _descriptor;
    if (descriptor == null) return null;
    if (!DateTime.parse(descriptor.expiresAt.value).isAfter(_clock())) {
      _clearDescriptor();
      if (!_disposed) {
        _emit(
          _copyState(
            media: _state.canonicalState is LiveHuddleState
                ? const ChatHuddleMediaRejoinRequiredState(
                    reason: ChatHuddleRejoinReason.descriptorExpired,
                  )
                : const ChatHuddleMediaIdleState(),
          ),
        );
      }
      return null;
    }
    return descriptor;
  }

  void _clearDescriptor() {
    final cancel = _cancelDescriptorTimer;
    _cancelDescriptorTimer = null;
    _descriptor = null;
    _descriptorSessionId = null;
    try {
      cancel?.call();
    } catch (_) {
      // Timer failures cannot keep opaque media material reachable.
    }
  }

  ChatHuddleState _copyState({
    HuddleSessionState? canonicalState,
    ChatHuddleHydrationStatus? hydrationStatus,
    ChatHuddleMediaState? media,
    ChatHuddleActionOperation? pendingOperation,
    bool clearPending = false,
    ChatHuddleRecoveryStatus? recoveryStatus,
    ChatHuddleActionOperation? recoveryOperation,
    bool clearRecovery = false,
  }) =>
      ChatHuddleState(
        conversationId: conversationId,
        canonicalState: canonicalState ?? _state.canonicalState,
        hydrationStatus: hydrationStatus ?? _state.hydrationStatus,
        media: media ?? _state.media,
        pendingOperation:
            clearPending ? null : pendingOperation ?? _state.pendingOperation,
        recoveryStatus:
            clearRecovery ? null : recoveryStatus ?? _state.recoveryStatus,
        recoveryOperation: clearRecovery
            ? null
            : recoveryOperation ?? _state.recoveryOperation,
      );

  void _emit(ChatHuddleState next) {
    if (_disposed || _stateChanges.isClosed) return;
    _state = next;
    _stateChanges.add(next);
  }

  Stream<ChatHuddleState> _createStateStream() => Stream<ChatHuddleState>.multi(
        (events) {
          _observe();
          events.add(_state);
          final subscription = _stateChanges.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          var active = true;
          events.onCancel = () async {
            if (!active) return;
            active = false;
            await subscription.cancel();
            _unobserve();
          };
        },
        isBroadcast: true,
      );

  void _observe() {
    if (_disposed) return;
    _observerCount += 1;
    if (_observerCount != 1) return;
    try {
      _releaseRealtime = _subscribeConversation?.call(conversationId);
    } catch (_) {
      _releaseRealtime = null;
    }
  }

  void _unobserve() {
    if (_observerCount == 0) return;
    _observerCount -= 1;
    if (_observerCount != 0) return;
    final release = _releaseRealtime;
    _releaseRealtime = null;
    release?.call();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _watermark += 1;
    for (final cancellation in _activeCancellations.toList(growable: false)) {
      cancellation.cancel();
    }
    _clearDescriptor();
    _observerCount = 0;
    final release = _releaseRealtime;
    _releaseRealtime = null;
    release?.call();
    final hydration = _hydration;
    if (hydration != null) await hydration;
    if (_commandDrains.isNotEmpty) {
      await Future.wait(_commandDrains.toList(growable: false));
    }
    await _stateChanges.close();
  }

  ChatHuddleActionFailure _validation(ChatHuddleActionOperation operation) =>
      _failure(
        operation,
        ChatHuddleErrorCode.validation,
        retryable: false,
      );

  ChatHuddleActionFailure _aborted(ChatHuddleActionOperation operation) =>
      _failure(
        operation,
        ChatHuddleErrorCode.aborted,
        retryable: true,
      );

  ChatHuddleActionFailure _closed(ChatHuddleActionOperation operation) =>
      _failure(
        operation,
        ChatHuddleErrorCode.closed,
        retryable: false,
      );

  ChatHuddleActionFailure _failure(
    ChatHuddleActionOperation operation,
    ChatHuddleErrorCode code, {
    required bool retryable,
    int? httpStatus,
  }) =>
      ChatHuddleActionFailure(
        operation: operation,
        code: code,
        message: operation == ChatHuddleActionOperation.hydrate
            ? 'Huddle state could not be loaded.'
            : 'The huddle action could not be completed.',
        retryable: retryable,
        httpStatus: httpStatus,
      );

  ChatHuddleMediaErrorState _mediaError(ChatHuddleActionFailure failure) =>
      ChatHuddleMediaErrorState(
        code: failure.code,
        message: failure.message,
        retryable: failure.retryable,
        httpStatus: failure.httpStatus,
      );

  @override
  String toString() => 'ChatHuddleController('
      'conversationId: ${conversationId.value}, '
      'canonicalStatus: ${_state.canonicalState.status.name}, '
      'disposed: $_disposed)';
}

ChatCommandDescriptor<HuddleCommandInput, HuddleCommandInput,
    HuddleCommandResult> _huddleCommandDescriptor(
  HuddleCommandInput expectedInput,
  ChatHuddleClock clock,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'huddle.${expectedInput.operation}',
      method: expectedInput is SetHuddleScreenShareInput
          ? ChatCommandMethod.patch
          : ChatCommandMethod.post,
      pathBuilder: (input) {
        if (input is StartHuddleInput) {
          return '/conversations/'
              '${Uri.encodeComponent(input.conversationId.value)}/huddles';
        }
        final session = input as SessionHuddleInput;
        final suffix = switch (input) {
          JoinHuddleInput() => 'join',
          LeaveHuddleInput() => 'leave',
          SetHuddleScreenShareInput() => 'screen-share',
          EndHuddleInput() => 'end',
        };
        return '/huddles/${Uri.encodeComponent(session.huddleSessionId.value)}/$suffix';
      },
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => HuddleCommandInput.fromJson(input.toJson()),
      parseResult: (value) => parseHuddleCommandResult(
        value,
        expectedInput,
        now: clock(),
      ),
    );

ChatHuddleActionFailure _mapCommandFailure(
  ChatHuddleActionOperation operation,
  ChatCommandResult<HuddleCommandResult> result,
) {
  final code = switch (result.category) {
    ChatCommandResultCategory.validation => ChatHuddleErrorCode.validation,
    ChatCommandResultCategory.queued => ChatHuddleErrorCode.transport,
    ChatCommandResultCategory.authentication =>
      ChatHuddleErrorCode.authentication,
    ChatCommandResultCategory.conflict => ChatHuddleErrorCode.conflict,
    ChatCommandResultCategory.featureDisabled =>
      ChatHuddleErrorCode.featureDisabled,
    ChatCommandResultCategory.unsupported => ChatHuddleErrorCode.unsupported,
    ChatCommandResultCategory.rejected => ChatHuddleErrorCode.rejected,
    ChatCommandResultCategory.malformedResponse =>
      ChatHuddleErrorCode.malformedResponse,
    ChatCommandResultCategory.transport => ChatHuddleErrorCode.transport,
    ChatCommandResultCategory.aborted => ChatHuddleErrorCode.aborted,
    ChatCommandResultCategory.closed => ChatHuddleErrorCode.closed,
    ChatCommandResultCategory.success => ChatHuddleErrorCode.transport,
  };
  final httpStatus = result is ChatCommandFailure<HuddleCommandResult>
      ? result.httpStatus
      : null;
  return ChatHuddleActionFailure(
    operation: operation,
    code: code,
    message: 'The huddle action could not be completed.',
    retryable: code == ChatHuddleErrorCode.transport ||
        code == ChatHuddleErrorCode.authentication ||
        code == ChatHuddleErrorCode.conflict ||
        code == ChatHuddleErrorCode.malformedResponse ||
        code == ChatHuddleErrorCode.aborted ||
        httpStatus == 408 ||
        httpStatus == 425 ||
        httpStatus == 429,
    httpStatus: httpStatus,
  );
}

StreamSubscription<void>? _forwardCancellation(
  ChatCommandCancellationSignal? caller,
  ChatCommandCancellationController target,
) {
  if (caller == null) return null;
  final subscription = caller.onCancelled.listen((_) => target.cancel());
  if (caller.isCancelled) target.cancel();
  return subscription;
}

Future<Value> _raceHuddleOperation<Value>(
  Future<Value> operation,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<Value>.error(const _HuddleOperationInterrupted());
  }
  final completer = Completer<Value>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _HuddleOperationInterrupted());
    }
  });
  operation.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  ).whenComplete(subscription.cancel);
  return completer.future;
}

bool _sameHuddleState(HuddleSessionState left, HuddleSessionState right) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());

ChatHuddleActionOperation _operationForHuddleInput(HuddleCommandInput input) =>
    _operationForWireValue(input.operation);

ChatHuddleActionOperation _operationForWireValue(String operation) =>
    switch (operation) {
      'start_huddle' => ChatHuddleActionOperation.start,
      'join_huddle' => ChatHuddleActionOperation.join,
      'leave_huddle' => ChatHuddleActionOperation.leave,
      'set_huddle_screen_share' => ChatHuddleActionOperation.setScreenShare,
      'end_huddle' => ChatHuddleActionOperation.end,
      _ => throw ArgumentError.value(operation, 'operation'),
    };

_HuddleAuthorityDecision _authorityDecision(
  HuddleCommandInput input,
  HuddleSessionState state,
  UserId actorUserId,
) {
  if (input is StartHuddleInput) {
    if (state is InactiveHuddleState) return _HuddleAuthorityDecision.replay;
    return state is LiveHuddleState
        ? _HuddleAuthorityDecision.equal
        : _HuddleAuthorityDecision.conflict;
  }
  if (state is InactiveHuddleState) {
    return input is LeaveHuddleInput || input is EndHuddleInput
        ? _HuddleAuthorityDecision.equal
        : _HuddleAuthorityDecision.conflict;
  }
  final sessionId = (input as SessionHuddleInput).huddleSessionId;
  final authoritativeSessionId = switch (state) {
    LiveHuddleState(:final huddleSessionId) => huddleSessionId,
    EndedHuddleState(:final huddleSessionId) => huddleSessionId,
    _ => null,
  };
  if (authoritativeSessionId != sessionId) {
    return _HuddleAuthorityDecision.conflict;
  }
  if (state is EndedHuddleState) {
    return input is LeaveHuddleInput || input is EndHuddleInput
        ? _HuddleAuthorityDecision.equal
        : _HuddleAuthorityDecision.conflict;
  }
  final live = state as LiveHuddleState;
  HuddleParticipant? participant;
  for (final candidate in live.participants) {
    if (candidate.userId == actorUserId) {
      participant = candidate;
      break;
    }
  }
  if (input is JoinHuddleInput) {
    if (participant?.status == HuddleParticipantStatus.joined) {
      return _HuddleAuthorityDecision.equal;
    }
    return participant?.status == HuddleParticipantStatus.left
        ? _HuddleAuthorityDecision.conflict
        : _HuddleAuthorityDecision.replay;
  }
  if (input is LeaveHuddleInput) {
    return participant?.status == HuddleParticipantStatus.joined
        ? _HuddleAuthorityDecision.replay
        : _HuddleAuthorityDecision.equal;
  }
  if (input is EndHuddleInput) return _HuddleAuthorityDecision.replay;
  final share = input as SetHuddleScreenShareInput;
  if (share.intent == HuddleScreenShareIntent.set) {
    if (live.screenShareOwnerUserId == actorUserId) {
      return _HuddleAuthorityDecision.equal;
    }
    return live.screenShareOwnerUserId == null
        ? _HuddleAuthorityDecision.replay
        : _HuddleAuthorityDecision.conflict;
  }
  if (live.screenShareOwnerUserId == null) {
    return _HuddleAuthorityDecision.equal;
  }
  return live.screenShareOwnerUserId == actorUserId
      ? _HuddleAuthorityDecision.replay
      : _HuddleAuthorityDecision.conflict;
}

Duration _defaultHuddleRetryBackoff(int retryNumber) {
  final exponent = min(max(retryNumber - 1, 0), 7);
  return Duration(milliseconds: min(30000, 250 * pow(2, exponent).toInt()));
}

Future<void> _defaultHuddleRetryWait(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
) =>
    _raceHuddleOperation(
      Future<void>.delayed(delay),
      cancellationSignal,
    );

DateTime _currentHuddleTime() => DateTime.now();

void Function() _scheduleHuddleTimer(
  Duration delay,
  void Function() callback,
) {
  final timer = Timer(delay, callback);
  var active = true;
  return () {
    if (!active) return;
    active = false;
    timer.cancel();
  };
}
