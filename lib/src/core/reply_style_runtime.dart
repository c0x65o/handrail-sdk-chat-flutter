part of '../handrail_chat_client.dart';

/// Host policy accepts wire strings as well as [ReplyStyle]. Unknown present
/// values deliberately stop precedence and resolve to Current.
final class ChatReplyStyleConfiguration {
  const ChatReplyStyleConfiguration({this.override, this.defaultStyle});
  final Object? override;
  final Object? defaultStyle;
}

/// Supply only identity established by the host's authenticated session.
/// Device identity is deliberately excluded from this preference's scope.
final class ChatReplyStyleIdentity {
  const ChatReplyStyleIdentity({required this.tenantId, required this.userId});
  final TenantId tenantId;
  final UserId userId;
}

enum ChatReplyStyleOrigin { hostOverride, saved, hostDefault, fallback }

enum ChatReplyStyleCapability { unknown, available, unsupported }

enum ChatReplyStyleError { read, save, conflict, unavailable, validation }

final class ChatReplyStyleState {
  const ChatReplyStyleState({
    required this.identity,
    required this.confirmed,
    required this.effectiveStyle,
    required this.origin,
    required this.unsupportedValue,
    required this.isLoading,
    required this.isSaving,
    required this.isAvailable,
    required this.capability,
    required this.canEdit,
    required this.canRetry,
    required this.requestedStyle,
    required this.error,
    required this.unavailableReason,
    required this.editingUnavailableReason,
    required this.isDisposed,
  });
  final ChatReplyStyleIdentity? identity;

  /// Null is unresolved, not confirmed absence. Unknown saved strings survive.
  final ReplyStylePreferenceState? confirmed;

  /// Advertised preference API support, independent of identity, online state,
  /// selected style and server authorization. It does not cover inline replies.
  final ChatReplyStyleCapability capability;
  final ReplyStyle effectiveStyle;
  final ChatReplyStyleOrigin origin;
  final bool unsupportedValue;
  final bool isLoading, isSaving, isAvailable, canEdit, canRetry, isDisposed;
  final ReplyStyle? requestedStyle;
  final ChatReplyStyleError? error;

  /// Preference API availability only; never inline-reply support or permission.
  final String? unavailableReason;
  final String? editingUnavailableReason;
  bool get isResolved => confirmed != null;
  String? get errorMessage => switch (error) {
        null => null,
        ChatReplyStyleError.read =>
          'The saved reply style could not be loaded. Retry loading.',
        ChatReplyStyleError.save =>
          'The requested reply style is not confirmed. Retry to reconcile and save.',
        ChatReplyStyleError.conflict =>
          'Your saved reply style changed elsewhere. Retry to save your requested choice.',
        ChatReplyStyleError.unavailable => unavailableReason,
        ChatReplyStyleError.validation =>
          'The reply style request could not be created.',
      };
}

/// Headless, server-confirmed preference state. Changes never touch composition,
/// navigation, thread context, local storage or message command queues.
final class ChatReplyStyleRuntime {
  ChatReplyStyleRuntime._(this._client, this._configuration, this._identity);
  final HandrailChatClient _client;
  ChatReplyStyleConfiguration _configuration;
  ChatReplyStyleIdentity? _identity;
  ReplyStylePreferenceState? _confirmed;
  ReplyStyle? _requested;
  UpdateReplyStylePreferenceInput? _request;
  ChatReplyStyleError? _error;
  ChatReplyStyleCapability _capability = ChatReplyStyleCapability.unknown;
  bool get _supported => _capability == ChatReplyStyleCapability.available;
  bool _online = true,
      _loading = false,
      _saving = false,
      _disposed = false,
      _conflicted = false;
  bool _readReady = false;
  int _epoch = 0, _readGeneration = 0;
  ChatCommandCancellationController? _readCancellation, _writeCancellation;
  final _recentEvents = <String>[];
  final _issuedKeys = <String>{};
  final _changes = StreamController<ChatReplyStyleState>.broadcast(sync: true);

  ChatReplyStyleState get state {
    final saved = _confirmed;
    final Object? value;
    final ChatReplyStyleOrigin origin;
    if (_configuration.override != null) {
      value = _configuration.override;
      origin = ChatReplyStyleOrigin.hostOverride;
    } else if (saved is SavedReplyStylePreference) {
      value = saved.style;
      origin = ChatReplyStyleOrigin.saved;
    } else if (_configuration.defaultStyle != null) {
      value = _configuration.defaultStyle;
      origin = ChatReplyStyleOrigin.hostDefault;
    } else {
      value = ReplyStyle.current;
      origin = ChatReplyStyleOrigin.fallback;
    }
    final raw = value is ReplyStyle ? value.wireValue : value;
    final reason = _disposed
        ? 'Reply style settings are disposed.'
        : _identity == null
            ? 'Sign in to load your reply style.'
            : !_online
                ? 'Reply style settings are unavailable while disconnected.'
                : !_supported
                    ? 'Reply style preferences are unavailable on this server.'
                    : null;
    final editable = reason == null &&
        _confirmed != null &&
        _readReady &&
        !_loading &&
        !_saving &&
        _configuration.override == null;
    return ChatReplyStyleState(
      identity: _identity,
      confirmed: _confirmed,
      effectiveStyle:
          raw == 'discord' ? ReplyStyle.discord : ReplyStyle.current,
      origin: origin,
      unsupportedValue: raw != 'current' && raw != 'discord',
      isLoading: _loading,
      isSaving: _saving,
      isAvailable: reason == null,
      capability: _capability,
      canEdit: editable,
      canRetry: reason == null &&
          !_loading &&
          !_saving &&
          _configuration.override == null &&
          _requested != null,
      requestedStyle: _requested,
      error: _error,
      unavailableReason: reason,
      editingUnavailableReason: reason ??
          (_configuration.override != null
              ? 'Reply style is enforced by this app.'
              : _loading
                  ? 'The saved reply style is loading.'
                  : !_readReady || _confirmed == null
                      ? 'Load your saved reply style before editing.'
                      : _saving
                          ? 'Your reply style selection is being saved.'
                          : null),
      isDisposed: _disposed,
    );
  }

  /// Broadcast, with a current snapshot for each new listener.
  Stream<ChatReplyStyleState> get states => Stream.multi((events) {
        events.add(state);
        if (_disposed) {
          events.close();
          return;
        }
        final subscription =
            _changes.stream.listen(events.add, onDone: events.close);
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);

  void configure(ChatReplyStyleConfiguration configuration) {
    if (_disposed) return;
    _configuration = configuration;
    _publish();
  }

  /// HTTP-only hosts call this on login, account/tenant switch and logout.
  /// Realtime clients use accepted session identity automatically. Null detaches
  /// pending work; an explicit retry can never cross this identity boundary.
  Future<ChatReplyStyleState> activateIdentity(
      ChatReplyStyleIdentity? identity) {
    if (_client.realtimeSession != null) {
      throw StateError(
          'Reply style identity is managed by the realtime session.');
    }
    _setIdentity(identity);
    return refresh();
  }

  void _setIdentity(ChatReplyStyleIdentity? identity) {
    if (_disposed ||
        (_identity?.tenantId == identity?.tenantId &&
            _identity?.userId == identity?.userId)) {
      return;
    }
    _interrupt();
    _identity = identity;
    _confirmed = null;
    _requested = null;
    _request = null;
    _conflicted = false;
    _error = null;
    _recentEvents.clear();
    _issuedKeys.clear();
    _publish();
  }

  Future<void> _initialize(ChatClientLifecycleState metadata) async {
    if (_disposed || _client.realtimeSession != null) return;
    _capability = metadata is ChatClientReadyState
        ? _replyStyleCapability(metadata.metadata)
        : ChatReplyStyleCapability.unknown;
    await refresh();
  }

  void _realtime(ChatRealtimeLifecycleState lifecycle) {
    if (_disposed) return;
    _interrupt();
    if (lifecycle is ChatRealtimeConnectedState) {
      _setIdentity(ChatReplyStyleIdentity(
          tenantId: lifecycle.identity.tenantId,
          userId: lifecycle.identity.userId));
      _online = true;
      _capability = _replyStyleCapability(lifecycle.metadata);
      unawaited(refresh());
    } else {
      _online = false;
      _capability = ChatReplyStyleCapability.unknown;
      _publish();
    }
  }

  /// Rehydrate without ever treating read failure as absence or acknowledging
  /// a mutation just because another writer chose the same style.
  Future<ChatReplyStyleState> refresh() async {
    if (_disposed) return state;
    if (!_online || !_supported || _identity == null) {
      _publish();
      return state;
    }
    _readCancellation?.cancel();
    final cancellation =
        _readCancellation = ChatCommandCancellationController();
    final epoch = _epoch, generation = ++_readGeneration;
    _loading = true;
    _readReady = false;
    if (_error == ChatReplyStyleError.read) _error = null;
    _publish();
    final result =
        await _client._snapshotQueries._run<ReplyStylePreferenceState>(
      query: ChatSnapshotQueryName.replyStylePreference,
      uri: _replyStyleUri(_client.apiBaseUri),
      options:
          ChatSnapshotQueryOptions(cancellationSignal: cancellation.signal),
      parse: ReplyStylePreferenceState.fromJson,
    );
    if (!_current(epoch) || generation != _readGeneration) return state;
    _loading = false;
    _readCancellation = null;
    if (result is ChatSnapshotQuerySuccess<ReplyStylePreferenceState>) {
      _confirm(result.value);
      _readReady = true;
    } else {
      _error = ChatReplyStyleError.read;
      if (result is ChatSnapshotQueryFailure<ReplyStylePreferenceState> &&
          result.httpStatus == 501) {
        _capability = ChatReplyStyleCapability.unsupported;
      }
    }
    _publish();
    return state;
  }

  Future<ChatReplyStyleState> select(ReplyStyle style) async {
    if (_disposed ||
        _saving ||
        _loading ||
        _identity == null ||
        _confirmed == null ||
        (_online && _supported && !_readReady) ||
        _configuration.override != null) {
      return state;
    }
    final epoch = _epoch;
    // An unchanged failed request retains its exact correlation through retry.
    if (_requested == style) return retry();
    final uncertain = _request != null;
    _requested = style;
    _request = null;
    _conflicted = false;
    if (uncertain && state.isAvailable) {
      await refresh();
      if (!_current(epoch) || _error == ChatReplyStyleError.read) return state;
    }
    return _save();
  }

  /// Explicit retry first reads authority. Uncertain requests replay exactly;
  /// known revision conflicts are rebased with a fresh key after that read.
  Future<ChatReplyStyleState> retry() async {
    if (_disposed ||
        _saving ||
        _loading ||
        _requested == null ||
        _configuration.override != null ||
        !state.isAvailable) {
      return state;
    }
    final epoch = _epoch, requested = _requested;
    await refresh();
    if (!_current(epoch) ||
        _requested != requested ||
        _error == ChatReplyStyleError.read ||
        !state.canEdit) {
      return state;
    }
    if (_conflicted) _request = null;
    return _save();
  }

  Future<ChatReplyStyleState> _save() async {
    if (_disposed || _requested == null || _configuration.override != null) {
      return state;
    }
    if (!state.isAvailable) {
      _error = ChatReplyStyleError.unavailable;
      _publish();
      return state;
    }
    try {
      if (_request == null) {
        final key = _client._generateCommandIdempotencyKey();
        if (!_issuedKeys.add(key)) {
          throw const FormatException("A mutation key must not be reused.");
        }
        _request = UpdateReplyStylePreferenceInput(
            style: _requested!,
            baseRevision: _confirmed!.revision,
            idempotencyKey: key);
      }
    } catch (_) {
      _error = ChatReplyStyleError.validation;
      _publish();
      return state;
    }
    final request = _request!;
    final epoch = _epoch;
    final cancellation =
        _writeCancellation = ChatCommandCancellationController();
    _saving = true;
    _error = null;
    _conflicted = false;
    _publish();
    final result = await _client._commandDispatcher.dispatch(
      _replyStyleDescriptor(request),
      request,
      options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal: cancellation.signal),
    );
    if (!_current(epoch) || !identical(_request, request)) return state;
    _saving = false;
    _writeCancellation = null;
    if (result is ChatCommandSuccess<UpdateReplyStylePreferenceResult>) {
      _confirm(result.value.preference);
      _conflicted = result.value.reconciliationStatus ==
          ReplyStylePreferenceReconciliationStatus.preferenceRevisionConflict;
      if (_conflicted) {
        _error = ChatReplyStyleError.conflict;
      } else {
        _acknowledge();
      }
    } else {
      _error = ChatReplyStyleError.save;
      if (result is ChatCommandUnsupported ||
          result is ChatCommandFeatureDisabled) {
        _capability = ChatReplyStyleCapability.unsupported;
      }
    }
    _publish();
    return state;
  }

  void _confirm(ReplyStylePreferenceState preference) {
    if (_confirmed == null || preference.revision > _confirmed!.revision) {
      _confirmed = preference;
    }
  }

  DurableEventReduction _event(ReplyStyleUpdatedDurableEvent event) {
    final identity = _identity;
    if (_disposed ||
        identity == null ||
        event.tenantId != identity.tenantId ||
        event.streamId != 'user:${identity.userId.value}' ||
        event.payload.data['actorUserId'] != identity.userId.value ||
        event.protocolVersion != handrailChatDurableEventProtocolVersion) {
      throw DurableEventReductionError(DurableEventDiagnostic(
        code: DurableEventDiagnosticCode.privateStreamMismatch,
        reason: DurableEventRecoveryReason.eventInvalid,
        eventId: event.eventId,
        streamId: event.streamId,
        eventType: event.type,
        message:
            'The reply style event does not match the active trusted session.',
      ));
    }
    final preference =
        ReplyStylePreferenceState.fromJson(event.payload.data['preference']);
    final status = _recentEvents.contains(event.eventId)
        ? DurableEventReductionStatus.duplicate
        : preference.revision <= (_confirmed?.revision ?? -1)
            ? DurableEventReductionStatus.stale
            : DurableEventReductionStatus.applied;
    _confirm(preference);
    if (status == DurableEventReductionStatus.applied) _readReady = true;
    final mutation = event.payload.data['mutation'];
    if (mutation != null && _request != null) {
      final input = UpdateReplyStylePreferenceInput.fromJson(mutation);
      if (input.style == _request!.style &&
          input.baseRevision == _request!.baseRevision &&
          input.idempotencyKey == _request!.idempotencyKey) {
        _acknowledge();
      }
    }
    if (!_recentEvents.contains(event.eventId)) {
      _recentEvents.add(event.eventId);
      if (_recentEvents.length > durableEventRecentIdLimit) {
        _recentEvents.removeAt(0);
      }
    }
    _publish();
    return DurableEventReduction(
        status: status, state: _client.normalizedState.state);
  }

  void _acknowledge() {
    _request = null;
    _requested = null;
    _saving = false;
    _conflicted = false;
    _error = null;
    _writeCancellation?.cancel();
    _writeCancellation = null;
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _publish() {
    if (!_disposed) _changes.add(state);
  }

  void _interrupt() {
    ++_epoch;
    ++_readGeneration;
    _readCancellation?.cancel();
    _writeCancellation?.cancel();
    _readCancellation = null;
    _writeCancellation = null;
    _loading = false;
    _readReady = false;
    if (_saving) _error = ChatReplyStyleError.save;
    _saving = false;
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    _interrupt();
    _identity = null;
    _confirmed = null;
    _requested = null;
    _request = null;
    _disposed = true;
    _changes.add(state);
    await _changes.close();
  }
}

ChatReplyStyleCapability _replyStyleCapability(
        ServerHandshakeMetadata metadata) =>
    supportsReplyStylePreference(metadata.enabledFeatures.values)
        ? ChatReplyStyleCapability.available
        : ChatReplyStyleCapability.unsupported;

Uri _replyStyleUri(Uri base) {
  final metadata = _metadataUri(base);
  return metadata.replace(
      path: metadata.path
          .replaceFirst(RegExp(r'/_meta$'), '/preferences/reply-style'));
}

ChatCommandDescriptor<UpdateReplyStylePreferenceInput, Map<String, Object?>,
    UpdateReplyStylePreferenceResult> _replyStyleDescriptor(
        UpdateReplyStylePreferenceInput request) =>
    ChatCommandDescriptor(
      name: 'reply.style.update', method: ChatCommandMethod.patch,
      path: '/preferences/reply-style',
      // Automatic transport retries would skip the required authority read.
      retrySafety: ChatCommandRetrySafety.never,
      validateInput: (input) =>
          UpdateReplyStylePreferenceInput.fromJson(input.toJson()).toJson(),
      parseResult: (json) {
        final result = UpdateReplyStylePreferenceResult.fromJson(json,
            expectedInput: request);
        if (result.reconciliationStatus ==
            ReplyStylePreferenceReconciliationStatus
                .preferenceRevisionConflict) {
          throw const FormatException('Conflict requires HTTP 409.');
        }
        return result;
      },
      parseErrorResult: (json, status) {
        if (status != 409 || json is! Map || !json.containsKey('operation')) {
          return null;
        }
        final result = UpdateReplyStylePreferenceResult.fromJson(json,
            expectedInput: request);
        if (result.reconciliationStatus !=
            ReplyStylePreferenceReconciliationStatus
                .preferenceRevisionConflict) {
          throw const FormatException('HTTP 409 requires conflict.');
        }
        return result;
      },
    );
