part of '../handrail_chat_client.dart';

/// Canonical outcomes produced by an unregister-then-register token rotation.
final class ChatPushTokenRotationResult {
  const ChatPushTokenRotationResult({
    required this.unregistered,
    required this.registered,
  });

  final DevicePushTokenResult unregistered;
  final DevicePushTokenResult registered;
}

final class _PushTokenTarget {
  const _PushTokenTarget({
    required this.platform,
    required this.provider,
    required this.environment,
  });

  factory _PushTokenTarget.fromInput(
    TokenBearingDevicePushTokenInput input,
  ) =>
      _PushTokenTarget(
        platform: input.platform,
        provider: input.provider,
        environment: input.environment,
      );

  factory _PushTokenTarget.fromState(CanonicalDevicePushTokenState state) =>
      _PushTokenTarget(
        platform: state.platform,
        provider: state.provider,
        environment: state.environment,
      );

  final DevicePlatform platform;
  final DevicePushProvider provider;
  final DevicePushProviderEnvironment environment;

  String get storageOrder =>
      '${platform.wireValue}\u0000${provider.wireValue}\u0000'
      '${environment.wireValue}';

  @override
  bool operator ==(Object other) =>
      other is _PushTokenTarget &&
      other.platform == platform &&
      other.provider == provider &&
      other.environment == environment;

  @override
  int get hashCode => Object.hash(platform, provider, environment);
}

final class _PushTokenLaneIntent {
  _PushTokenLaneIntent({
    required this.run,
    required this.abort,
    required this.close,
    required this.cancellationSignal,
  });

  final Future<void> Function() run;
  final void Function() abort;
  final void Function() close;
  final ChatCommandCancellationSignal? cancellationSignal;
  StreamSubscription<void>? cancellationSubscription;
}

final class _PushTokenLane {
  final List<_PushTokenLaneIntent> intents = <_PushTokenLaneIntent>[];
  _PushTokenLaneIntent? active;
  bool draining = false;
}

final class _PushTokenRuntime {
  _PushTokenRuntime({
    required this.storage,
    required ApplicationChatStorageIdentity? initialIdentity,
    required this.dispatcher,
  }) : _identity = initialIdentity;

  final ApplicationChatStorage storage;
  final ChatCommandDispatcher dispatcher;
  final Map<_PushTokenTarget, CanonicalDevicePushTokenState> _states = {};
  final Map<_PushTokenTarget, _PushTokenLane> _lanes = {};
  final Set<Future<void>> _drains = <Future<void>>{};
  ApplicationChatStorageIdentity? _identity;
  Future<void> _storageTail = Future<void>.value();
  Future<void>? _loading;
  bool _loaded = false;
  bool _closed = false;

  Future<void> activate(ApplicationChatStorageIdentity identity) async {
    if (_closed) throw StateError('The push token runtime is closed.');
    if (_identity == identity && _loaded) return;
    if (_drains.isNotEmpty) {
      await Future.wait(_drains.toList(growable: false));
    }
    _identity = identity;
    _states.clear();
    _loaded = false;
    await _ensureLoaded(identity);
  }

  Future<ChatCommandResult<DevicePushTokenResult>> execute(
    DevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<DevicePushTokenResult>();
    final identity = _trustedIdentityFor(input.deviceId);
    if (identity == null) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<DevicePushTokenResult>();
    }
    try {
      await _ensureLoaded(identity);
    } catch (_) {
      return const ChatCommandTransportFailure<DevicePushTokenResult>();
    }
    if (_closed) return const ChatCommandClosed<DevicePushTokenResult>();
    if (_identity != identity) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }

    final target = _targetFor(input);
    if (target == null) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    return _enqueue<ChatCommandResult<DevicePushTokenResult>>(
      target,
      cancellationSignal: cancellationSignal,
      aborted: () => const ChatCommandAborted<DevicePushTokenResult>(),
      closed: () => const ChatCommandClosed<DevicePushTokenResult>(),
      action: (signal) => _executeNow(
        input,
        target,
        identity,
        cancellationSignal: signal,
      ),
    );
  }

  Future<ChatCommandResult<ChatPushTokenRotationResult>> rotate({
    required UnregisterDevicePushTokenInput unregister,
    required RegisterDevicePushTokenInput replacement,
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) {
      return const ChatCommandClosed<ChatPushTokenRotationResult>();
    }
    final identity = _trustedIdentityFor(unregister.deviceId);
    if (identity == null || replacement.deviceId != unregister.deviceId) {
      return const ChatCommandValidationFailure<ChatPushTokenRotationResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<ChatPushTokenRotationResult>();
    }
    try {
      await _ensureLoaded(identity);
    } catch (_) {
      return const ChatCommandTransportFailure<ChatPushTokenRotationResult>();
    }
    final target = _PushTokenTarget.fromInput(replacement);
    final current = _states[target];
    if (current == null || current.status != DevicePushTokenStatus.active) {
      return const ChatCommandValidationFailure<ChatPushTokenRotationResult>();
    }

    return _enqueue<ChatCommandResult<ChatPushTokenRotationResult>>(
      target,
      cancellationSignal: cancellationSignal,
      aborted: () => const ChatCommandAborted<ChatPushTokenRotationResult>(),
      closed: () => const ChatCommandClosed<ChatPushTokenRotationResult>(),
      action: (signal) async {
        final removed = await _executeNow(
          unregister,
          target,
          identity,
          cancellationSignal: signal,
        );
        final removedValue = switch (removed) {
          ChatCommandSuccess<DevicePushTokenResult>(:final value) => value,
          _ => null,
        };
        if (removedValue == null) {
          return _failureAs<ChatPushTokenRotationResult>(removed);
        }
        final registered = await _executeNow(
          replacement,
          target,
          identity,
          cancellationSignal: signal,
        );
        final registeredValue = switch (registered) {
          ChatCommandSuccess<DevicePushTokenResult>(:final value) => value,
          _ => null,
        };
        if (registeredValue == null) {
          return _failureAs<ChatPushTokenRotationResult>(registered);
        }
        return ChatCommandSuccess<ChatPushTokenRotationResult>(
          ChatPushTokenRotationResult(
            unregistered: removedValue,
            registered: registeredValue,
          ),
        );
      },
    );
  }

  Future<ChatCommandResult<DevicePushTokenResult>> logout(
    UnregisterDevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_closed) return const ChatCommandClosed<DevicePushTokenResult>();
    final identity = _trustedIdentityFor(input.deviceId);
    if (identity == null) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<DevicePushTokenResult>();
    }
    try {
      await _ensureLoaded(identity);
    } catch (_) {
      return const ChatCommandTransportFailure<DevicePushTokenResult>();
    }
    final target = _targetFor(input);
    if (target == null) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    return _enqueue<ChatCommandResult<DevicePushTokenResult>>(
      target,
      cancellationSignal: cancellationSignal,
      aborted: () => const ChatCommandAborted<DevicePushTokenResult>(),
      closed: () => const ChatCommandClosed<DevicePushTokenResult>(),
      action: (signal) async {
        final result = await _executeNow(
          input,
          target,
          identity,
          cancellationSignal: signal,
          persistCanonical: false,
        );
        if (result is ChatCommandSuccess<DevicePushTokenResult>) {
          try {
            await _removeCanonical(
              target,
              result.value.devicePushToken.tokenRevision,
              identity,
            );
          } catch (_) {
            return const ChatCommandTransportFailure<DevicePushTokenResult>();
          }
        }
        return result;
      },
    );
  }

  Future<void> beginClose() async {
    if (_closed) return;
    _closed = true;
    for (final lane in _lanes.values) {
      final queued = lane.intents
          .where((intent) => !identical(intent, lane.active))
          .toList(growable: false);
      for (final intent in queued) {
        lane.intents.remove(intent);
        await intent.cancellationSubscription?.cancel();
        intent.close();
      }
    }
    if (_drains.isNotEmpty) {
      await Future.wait(_drains.toList(growable: false));
    }
    await _storageTail;
  }

  ApplicationChatStorageIdentity? _trustedIdentityFor(DeviceId deviceId) {
    final identity = _identity;
    if (identity == null || identity.deviceId != deviceId) return null;
    return identity;
  }

  _PushTokenTarget? _targetFor(DevicePushTokenInput input) {
    if (input is TokenBearingDevicePushTokenInput) {
      return _PushTokenTarget.fromInput(input);
    }
    final active = _states.entries
        .where((entry) => entry.value.status == DevicePushTokenStatus.active)
        .toList(growable: false);
    return active.length == 1 ? active.single.key : null;
  }

  Future<ChatCommandResult<DevicePushTokenResult>> _executeNow(
    DevicePushTokenInput input,
    _PushTokenTarget target,
    ApplicationChatStorageIdentity identity, {
    ChatCommandCancellationSignal? cancellationSignal,
    bool persistCanonical = true,
  }) async {
    if (_closed) return const ChatCommandClosed<DevicePushTokenResult>();
    if (_identity != identity || identity.deviceId != input.deviceId) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    final current = _states[target];
    if ((input.operation == DevicePushTokenOperation.refresh ||
            input.operation == DevicePushTokenOperation.unregister) &&
        (current == null || current.status != DevicePushTokenStatus.active)) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }
    if (input.operation == DevicePushTokenOperation.register &&
        current?.status == DevicePushTokenStatus.active) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }

    late final DevicePushTokenInput validated;
    try {
      validated = DevicePushTokenInput.fromJson(
        input.toJson(),
        currentTokenRevision: current?.tokenRevision ?? 0,
      );
    } catch (_) {
      return const ChatCommandValidationFailure<DevicePushTokenResult>();
    }

    final descriptor = ChatCommandDescriptor<DevicePushTokenInput,
        DevicePushTokenInput, DevicePushTokenResult>.withPathBuilder(
      name: 'device.push_token.${validated.operation.wireValue}',
      method: ChatCommandMethod.put,
      pathBuilder: (request) =>
          '/devices/${Uri.encodeComponent(request.deviceId.value)}/push-token',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (request) => request,
      parseResult: (json) => DevicePushTokenResult.fromJson(
        json,
        expectedInput: validated,
      ),
    );
    final result = await dispatcher.dispatch(
      descriptor,
      validated,
      options: ChatCommandDispatchOptions(
        idempotencyKey: validated.idempotencyKey,
        cancellationSignal: cancellationSignal,
      ),
    );
    if (result case ChatCommandSuccess<DevicePushTokenResult>(:final value)) {
      final canonical = value.devicePushToken;
      if (_PushTokenTarget.fromState(canonical) != target) {
        return const ChatCommandMalformedResponse<DevicePushTokenResult>();
      }
      if (persistCanonical) {
        try {
          await _replaceCanonical(target, canonical, identity);
        } catch (_) {
          return const ChatCommandTransportFailure<DevicePushTokenResult>();
        }
      }
    }
    return result;
  }

  Future<Result> _enqueue<Result>(
    _PushTokenTarget target, {
    required ChatCommandCancellationSignal? cancellationSignal,
    required Result Function() aborted,
    required Result Function() closed,
    required Future<Result> Function(
      ChatCommandCancellationSignal? cancellationSignal,
    ) action,
  }) {
    if (_closed) return Future<Result>.value(closed());
    if (cancellationSignal?.isCancelled == true) {
      return Future<Result>.value(aborted());
    }
    final completer = Completer<Result>();
    late final _PushTokenLaneIntent intent;
    intent = _PushTokenLaneIntent(
      cancellationSignal: cancellationSignal,
      run: () async {
        if (completer.isCompleted) return;
        try {
          completer.complete(await action(cancellationSignal));
        } catch (_) {
          if (!completer.isCompleted) completer.complete(closed());
        }
      },
      abort: () {
        if (!completer.isCompleted) completer.complete(aborted());
      },
      close: () {
        if (!completer.isCompleted) completer.complete(closed());
      },
    );
    final lane = _lanes.putIfAbsent(target, _PushTokenLane.new);
    lane.intents.add(intent);
    if (cancellationSignal != null) {
      intent.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, intent) || completer.isCompleted) return;
        if (!lane.intents.remove(intent)) return;
        intent.abort();
        unawaited(intent.cancellationSubscription?.cancel());
      });
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drain(target, lane).whenComplete(() => _drains.remove(drain));
      _drains.add(drain);
    }
    return completer.future;
  }

  Future<void> _drain(_PushTokenTarget target, _PushTokenLane lane) async {
    while (lane.intents.isNotEmpty) {
      final intent = lane.intents.first;
      lane.active = intent;
      await intent.run();
      await intent.cancellationSubscription?.cancel();
      if (lane.intents.isNotEmpty && identical(lane.intents.first, intent)) {
        lane.intents.removeAt(0);
      } else {
        lane.intents.remove(intent);
      }
      lane.active = null;
    }
    lane.draining = false;
    if (identical(_lanes[target], lane)) {
      _lanes.remove(target);
    }
  }

  Future<void> _ensureLoaded(ApplicationChatStorageIdentity identity) {
    if (_loaded && _identity == identity) return Future<void>.value();
    // Share the initial load so concurrent commands enter their lanes in order.
    return _loading ??= _serializedStorage(() async {
      final committed = await ApplicationChatStorageMutator(storage)
          .mutate<ApplicationChatPushTokenRevisionsRecord>(
        identity,
        ApplicationChatStorageRecordKind.pushTokenRevisions,
        (current) => current,
      );
      // The helper quarantines only the exact malformed encoded value.
      // A failed load remains retryable and never publishes proposed state.
      if (_identity != identity) {
        throw StateError('Storage identity changed.');
      }
      _publishCommitted(committed, identity);
      _loaded = true;
    }).whenComplete(() => _loading = null);
  }

  void _publishCommitted(
    ApplicationChatPushTokenRevisionsRecord? record,
    ApplicationChatStorageIdentity identity,
  ) {
    _states.clear();
    for (final revision
        in record?.revisions ?? const <ApplicationChatPushTokenRevision>[]) {
      final canonical = revision.toCanonical(identity.deviceId);
      _states[_PushTokenTarget.fromState(canonical)] = canonical;
    }
  }

  Future<void> _replaceCanonical(
    _PushTokenTarget target,
    CanonicalDevicePushTokenState canonical,
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateCanonical(identity, (states) {
        final previous = states[target];
        if (previous == null ||
            previous.tokenRevision < canonical.tokenRevision) {
          states[target] = canonical;
        }
      });

  Future<void> _removeCanonical(
    _PushTokenTarget target,
    int removedRevision,
    ApplicationChatStorageIdentity identity,
  ) =>
      _mutateCanonical(identity, (states) {
        final previous = states[target];
        // A delayed logout must not erase a newer registration or refresh.
        if (previous != null && previous.tokenRevision <= removedRevision) {
          states.remove(target);
        }
      });

  Future<void> _mutateCanonical(
    ApplicationChatStorageIdentity identity,
    void Function(Map<_PushTokenTarget, CanonicalDevicePushTokenState>) update,
  ) =>
      _serializedStorage(() async {
        if (_identity != identity) {
          throw StateError('Storage identity changed.');
        }
        final committed = await ApplicationChatStorageMutator(storage)
            .mutate<ApplicationChatPushTokenRevisionsRecord>(
          identity,
          ApplicationChatStorageRecordKind.pushTokenRevisions,
          (current) {
            // Rebuild from storage on every retry, never from this runtime's
            // cache, so independent runtimes retain each other's targets.
            final states = <_PushTokenTarget, CanonicalDevicePushTokenState>{};
            for (final revision in current?.revisions ??
                const <ApplicationChatPushTokenRevision>[]) {
              final canonical = revision.toCanonical(identity.deviceId);
              states[_PushTokenTarget.fromState(canonical)] = canonical;
            }
            update(states);
            if (states.isEmpty) return null;
            final entries = states.entries.toList(growable: false)
              ..sort((left, right) =>
                  left.key.storageOrder.compareTo(right.key.storageOrder));
            return ApplicationChatPushTokenRevisionsRecord(
              identity: identity,
              revisions: entries
                  .map((entry) =>
                      ApplicationChatPushTokenRevision.fromCanonical(
                          entry.value))
                  .toList(growable: false),
            );
          },
        );
        _publishCommitted(committed, identity);
      });

  Future<void> _serializedStorage(Future<void> Function() operation) {
    final result = _storageTail.then(
      (_) => operation(),
      onError: (_, __) => operation(),
    );
    _storageTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
}

ChatCommandResult<Result> _failureAs<Result>(
  ChatCommandResult<DevicePushTokenResult> result,
) =>
    switch (result) {
      ChatCommandValidationFailure<DevicePushTokenResult>() =>
        ChatCommandValidationFailure<Result>(),
      ChatCommandAuthenticationFailure<DevicePushTokenResult>(
        :final httpStatus,
      ) =>
        ChatCommandAuthenticationFailure<Result>(httpStatus: httpStatus),
      ChatCommandConflict<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandConflict<Result>(httpStatus: httpStatus!),
      ChatCommandFeatureDisabled<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandFeatureDisabled<Result>(httpStatus: httpStatus!),
      ChatCommandUnsupported<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandUnsupported<Result>(httpStatus: httpStatus!),
      ChatCommandRejected<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandRejected<Result>(httpStatus: httpStatus!),
      ChatCommandMalformedResponse<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandMalformedResponse<Result>(httpStatus: httpStatus),
      ChatCommandTransportFailure<DevicePushTokenResult>(:final httpStatus) =>
        ChatCommandTransportFailure<Result>(httpStatus: httpStatus),
      ChatCommandAborted<DevicePushTokenResult>() =>
        ChatCommandAborted<Result>(),
      ChatCommandClosed<DevicePushTokenResult>() => ChatCommandClosed<Result>(),
      _ => ChatCommandMalformedResponse<Result>(),
    };
