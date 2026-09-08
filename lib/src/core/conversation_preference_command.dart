part of '../handrail_chat_client.dart';

typedef ChatConversationPreferenceClock = IsoTimestamp Function();

IsoTimestamp _currentConversationPreferenceTime() =>
    IsoTimestamp(DateTime.now().toUtc().toIso8601String());

/// Authored replacement fields accepted by preference updates.
final class ChatUpdateConversationPreferenceInput {
  const ChatUpdateConversationPreferenceInput({
    required this.conversationId,
    required this.notificationPreference,
    required this.isStarred,
    required this.mute,
    this.idempotencyKey,
  });

  final ConversationId conversationId;
  final ConversationNotificationPreference notificationPreference;
  final bool isStarred;
  final ConversationPreferenceMuteState mute;
  final String? idempotencyKey;

  ConversationPreferenceDesiredState get preference =>
      ConversationPreferenceDesiredState(
        notificationPreference: notificationPreference,
        isStarred: isStarred,
        mute: mute,
      );
}

final class _ConversationPreferenceCommandIntent {
  _ConversationPreferenceCommandIntent({
    required this.initialRequest,
    required this.cancellationSignal,
  });

  final UpdateConversationPreferenceInput initialRequest;
  final ChatCommandCancellationSignal? cancellationSignal;
  StreamSubscription<void>? cancellationSubscription;
  final Completer<ChatCommandResult<UpdateConversationPreferenceResult>>
      completer = Completer();
}

final class _ConversationPreferenceCommandLane {
  final List<_ConversationPreferenceCommandIntent> intents = [];
  _ConversationPreferenceCommandIntent? active;
  bool draining = false;
}

ChatCommandDescriptor<
    UpdateConversationPreferenceInput,
    UpdateConversationPreferenceInput,
    UpdateConversationPreferenceResult> _conversationPreferenceDescriptor(
  UpdateConversationPreferenceInput request,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'conversation.preference.update',
      method: ChatCommandMethod.patch,
      pathBuilder: (input) =>
          '/conversations/${Uri.encodeComponent(input.conversationId.value)}'
          '/preference',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) =>
          UpdateConversationPreferenceInput.fromJson(input.toJson()),
      parseResult: (json) => UpdateConversationPreferenceResult.fromJson(
        json,
        expectedInput: request,
      ),
      parseErrorResult: (json, httpStatus) {
        if (httpStatus != 409) return null;
        final result = UpdateConversationPreferenceResult.fromJson(
          json,
          expectedInput: request,
        );
        return result.reconciliationStatus ==
                ConversationPreferenceReconciliationStatus
                    .preferenceRevisionConflict
            ? result
            : null;
      },
    );

extension HandrailChatConversationPreferenceCommands on HandrailChatClient {
  /// Replaces starred, notification, and mute state per conversation.
  Future<ChatCommandResult<UpdateConversationPreferenceResult>>
      updateConversationPreference(
    ChatUpdateConversationPreferenceInput authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(
        const ChatCommandClosed<UpdateConversationPreferenceResult>(),
      );
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(
        const ChatCommandAborted<UpdateConversationPreferenceResult>(),
      );
    }

    late final Map<String, Object?> authoredJson;
    try {
      authoredJson = <String, Object?>{
        'operation': 'update_conversation_preference',
        'conversationId': authored.conversationId.toJson(),
        'expectedPreferenceRevision': 0,
        'notificationPreference': authored.notificationPreference.toJson(),
        'isStarred': authored.isStarred,
        'mute': authored.mute.toJson(),
      };
      UpdateConversationPreferenceInput.fromJson({
        ...authoredJson,
        'idempotencyKey': authored.idempotencyKey ?? 'preference-validation',
      });
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<
            UpdateConversationPreferenceResult>(),
      );
    }

    final durableRuntime = _conversationPreferenceRuntime;
    if (durableRuntime != null) {
      return _executeDurableConversationPreference(
        durableRuntime,
        authoredJson,
        authored.idempotencyKey,
        cancellationSignal: cancellationSignal,
      );
    }

    late final UpdateConversationPreferenceInput request;
    try {
      final revision = normalizedState
          .conversationPreference(authored.conversationId)
          .authoritativeRevision;
      request = UpdateConversationPreferenceInput.fromJson({
        ...authoredJson,
        'expectedPreferenceRevision': revision,
        'idempotencyKey':
            authored.idempotencyKey ?? _generateCommandIdempotencyKey(),
      });
      normalizedState.beginOptimisticConversationPreference(
        request,
        _conversationPreferenceClock(),
      );
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<
            UpdateConversationPreferenceResult>(),
      );
    }

    final command = _ConversationPreferenceCommandIntent(
      initialRequest: request,
      cancellationSignal: cancellationSignal,
    );
    final lane = _conversationPreferenceCommandLanes.putIfAbsent(
      request.conversationId,
      _ConversationPreferenceCommandLane.new,
    );
    lane.intents.add(command);
    if (cancellationSignal != null) {
      command.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, command) || command.completer.isCompleted) {
          return;
        }
        if (!lane.intents.remove(command)) return;
        _rollbackConversationPreferenceIntent(command.initialRequest);
        command.completer.complete(
          const ChatCommandAborted<UpdateConversationPreferenceResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      });
      if (cancellationSignal.isCancelled &&
          lane.intents.remove(command) &&
          !command.completer.isCompleted) {
        _rollbackConversationPreferenceIntent(command.initialRequest);
        command.completer.complete(
          const ChatCommandAborted<UpdateConversationPreferenceResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      }
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drainConversationPreferenceLane(
        request.conversationId,
        lane,
      ).whenComplete(() {
        _conversationPreferenceCommandDrains.remove(drain);
      });
      _conversationPreferenceCommandDrains.add(drain);
    }
    return command.completer.future;
  }

  Future<ChatCommandResult<UpdateConversationPreferenceResult>>
      _executeDurableConversationPreference(
    _ConversationPreferenceRecoveryRuntime runtime,
    Map<String, Object?> authoredJson,
    String? authoredIdempotencyKey, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    final identity = _storageActivationIdentity;
    final generation = _storageIdentityGeneration;
    if (identity == null) {
      return const ChatCommandValidationFailure<
          UpdateConversationPreferenceResult>();
    }
    try {
      await _awaitCurrentStorageActivation();
    } catch (_) {
      return const ChatCommandValidationFailure<
          UpdateConversationPreferenceResult>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return const ChatCommandClosed<UpdateConversationPreferenceResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      return const ChatCommandAborted<UpdateConversationPreferenceResult>();
    }
    late final UpdateConversationPreferenceInput request;
    try {
      final conversationId = ConversationId.fromJson(
        authoredJson['conversationId'],
      );
      final revision = normalizedState
          .conversationPreference(conversationId)
          .authoritativeRevision;
      request = UpdateConversationPreferenceInput.fromJson({
        ...authoredJson,
        'expectedPreferenceRevision': revision,
        'idempotencyKey':
            authoredIdempotencyKey ?? _generateCommandIdempotencyKey(),
      });
    } catch (_) {
      return const ChatCommandValidationFailure<
          UpdateConversationPreferenceResult>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return const ChatCommandClosed<UpdateConversationPreferenceResult>();
    }
    return runtime.execute(
      request,
      cancellationSignal: cancellationSignal,
    );
  }

  /// Reusable entry point for a validated private realtime settlement.
  bool reconcileConversationPreference(
    UpdateConversationPreferenceInput input,
    UpdateConversationPreferenceResult result,
  ) =>
      normalizedState.reconcileConversationPreferenceMutation(input, result);

  Future<void> _drainConversationPreferenceLane(
    ConversationId conversationId,
    _ConversationPreferenceCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      final command = lane.intents.first;
      if (command.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = command;
      final initial = command.initialRequest;
      late final UpdateConversationPreferenceInput request;
      ChatCommandResult<UpdateConversationPreferenceResult> result;
      try {
        final revision = normalizedState
            .conversationPreference(conversationId)
            .authoritativeRevision;
        request = UpdateConversationPreferenceInput.fromJson({
          ...initial.toJson(),
          'expectedPreferenceRevision': revision,
        });
        result = await _commandDispatcher.dispatch(
          _conversationPreferenceDescriptor(request),
          request,
          options: ChatCommandDispatchOptions(
            idempotencyKey: request.idempotencyKey,
            cancellationSignal: command.cancellationSignal,
          ),
        );
      } catch (_) {
        result = const ChatCommandValidationFailure<
            UpdateConversationPreferenceResult>();
      }

      if (result
          case ChatCommandSuccess<UpdateConversationPreferenceResult>(
            :final value,
          )) {
        try {
          normalizedState.reconcileConversationPreferenceMutation(
            request,
            value,
          );
        } catch (_) {
          result = const ChatCommandMalformedResponse<
              UpdateConversationPreferenceResult>();
          _rollbackConversationPreferenceIntent(initial);
        }
      } else {
        _rollbackConversationPreferenceIntent(initial);
      }
      await command.cancellationSubscription?.cancel();
      if (!command.completer.isCompleted) command.completer.complete(result);
      if (lane.intents.isNotEmpty && identical(lane.intents.first, command)) {
        lane.intents.removeAt(0);
      } else {
        lane.intents.remove(command);
      }
      lane.active = null;
    }
    lane.draining = false;
    if (identical(_conversationPreferenceCommandLanes[conversationId], lane)) {
      _conversationPreferenceCommandLanes.remove(conversationId);
    }
  }

  void _rollbackConversationPreferenceIntent(
    UpdateConversationPreferenceInput request,
  ) {
    try {
      normalizedState.rollbackOptimisticConversationPreference(
        request.conversationId,
        request.idempotencyKey,
      );
    } on StateError {
      // An externally owned store may close before the client settles.
    }
  }

  void _closeConversationPreferenceCommands() {
    for (final lane in _conversationPreferenceCommandLanes.values) {
      final queued = lane.active == null
          ? lane.intents.toList(growable: false)
          : lane.intents.skip(1).toList(growable: false);
      for (final command in queued) {
        lane.intents.remove(command);
        if (command.completer.isCompleted) continue;
        _rollbackConversationPreferenceIntent(command.initialRequest);
        unawaited(command.cancellationSubscription?.cancel());
        command.completer.complete(
          const ChatCommandClosed<UpdateConversationPreferenceResult>(),
        );
      }
    }
  }
}
