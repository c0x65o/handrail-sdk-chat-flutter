part of '../handrail_chat_client.dart';

/// Authored fields accepted by [HandrailChatClient.joinConversation].
final class ChatJoinConversationInput {
  const ChatJoinConversationInput({
    required this.conversationId,
    required this.expectedMemberListRevision,
  });

  final ConversationId conversationId;
  final int expectedMemberListRevision;
}

/// Authored fields accepted by [HandrailChatClient.leaveConversation].
final class ChatLeaveConversationInput {
  const ChatLeaveConversationInput({
    required this.conversationId,
    required this.expectedMemberListRevision,
  });

  final ConversationId conversationId;
  final int expectedMemberListRevision;
}

/// Authored fields accepted by [HandrailChatClient.addConversationMember].
final class ChatAddConversationMemberInput {
  const ChatAddConversationMemberInput({
    required this.conversationId,
    required this.targetUserId,
    required this.requestedRole,
    required this.expectedMemberListRevision,
  });

  final ConversationId conversationId;
  final UserId targetUserId;
  final ConversationMembershipMemberRole requestedRole;
  final int expectedMemberListRevision;
}

/// Authored fields accepted by [HandrailChatClient.removeConversationMember].
final class ChatRemoveConversationMemberInput {
  const ChatRemoveConversationMemberInput({
    required this.conversationId,
    required this.targetUserId,
    required this.expectedMemberListRevision,
  });

  final ConversationId conversationId;
  final UserId targetUserId;
  final int expectedMemberListRevision;
}

/// Authored fields accepted by
/// [HandrailChatClient.changeConversationMemberRole].
final class ChatChangeConversationMemberRoleInput {
  const ChatChangeConversationMemberRoleInput({
    required this.conversationId,
    required this.targetUserId,
    required this.requestedRole,
    required this.expectedMemberListRevision,
  });

  final ConversationId conversationId;
  final UserId targetUserId;
  final ConversationMembershipMemberRole requestedRole;
  final int expectedMemberListRevision;
}

final class _ConversationMembershipCommandIntent {
  _ConversationMembershipCommandIntent({
    required this.request,
    required this.cancellationSignal,
  });

  final ConversationMembershipMutationInput request;
  final ChatCommandCancellationSignal? cancellationSignal;
  final Completer<ChatCommandResult<ConversationMembershipMutationResult>>
      completer = Completer();
  StreamSubscription<void>? cancellationSubscription;
}

final class _ConversationMembershipCommandLane {
  final List<_ConversationMembershipCommandIntent> intents = [];
  _ConversationMembershipCommandIntent? active;
  bool draining = false;
}

Map<String, Object?> _membershipAuthoredJson(
  ConversationMembershipMutationIntent intent,
  Object input,
) =>
    switch (input) {
      ChatJoinConversationInput(
        :final conversationId,
        :final expectedMemberListRevision
      ) ||
      ChatLeaveConversationInput(
        :final conversationId,
        :final expectedMemberListRevision
      ) =>
        <String, Object?>{
          'operation': 'mutate_conversation_membership',
          'intent': intent.toJson(),
          'conversationId': conversationId.toJson(),
          'expectedMemberListRevision': expectedMemberListRevision,
        },
      ChatAddConversationMemberInput(
        :final conversationId,
        :final targetUserId,
        :final requestedRole,
        :final expectedMemberListRevision,
      ) ||
      ChatChangeConversationMemberRoleInput(
        :final conversationId,
        :final targetUserId,
        :final requestedRole,
        :final expectedMemberListRevision,
      ) =>
        <String, Object?>{
          'operation': 'mutate_conversation_membership',
          'intent': intent.toJson(),
          'conversationId': conversationId.toJson(),
          'targetUserId': targetUserId.toJson(),
          'requestedRole': requestedRole.toJson(),
          'expectedMemberListRevision': expectedMemberListRevision,
        },
      ChatRemoveConversationMemberInput(
        :final conversationId,
        :final targetUserId,
        :final expectedMemberListRevision,
      ) =>
        <String, Object?>{
          'operation': 'mutate_conversation_membership',
          'intent': intent.toJson(),
          'conversationId': conversationId.toJson(),
          'targetUserId': targetUserId.toJson(),
          'expectedMemberListRevision': expectedMemberListRevision,
        },
      _ => throw const FormatException('Unsupported membership input.'),
    };

ChatCommandDescriptor<
    ConversationMembershipMutationInput,
    ConversationMembershipMutationInput,
    ConversationMembershipMutationResult> _membershipDescriptor(
  ConversationMembershipMutationInput request,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'conversation.membership.${request.intent.toJson()}',
      method: ChatCommandMethod.patch,
      pathBuilder: (input) =>
          '/conversations/${Uri.encodeComponent(input.conversationId.value)}/membership',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) =>
          ConversationMembershipMutationInput.fromJson(input.toJson()),
      parseResult: (json) => ConversationMembershipMutationResult.fromJson(
        json,
        expectedInput: request,
      ),
      parseErrorResult: (json, httpStatus) {
        if (httpStatus != 409) return null;
        final result = ConversationMembershipMutationResult.fromJson(
          json,
          expectedInput: request,
        );
        return result.reconciliationStatus ==
                    ConversationMembershipReconciliationStatus
                        .memberListConflict ||
                result.reconciliationStatus ==
                    ConversationMembershipReconciliationStatus.safetyRejected
            ? result
            : null;
      },
    );

/// Pure-Dart conversation membership commands on [HandrailChatClient].
extension HandrailChatConversationMembershipCommands on HandrailChatClient {
  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      joinConversation(
    ChatJoinConversationInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationMembership(
            ConversationMembershipMutationIntent.join,
            input,
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      leaveConversation(
    ChatLeaveConversationInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationMembership(
            ConversationMembershipMutationIntent.leave,
            input,
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      addConversationMember(
    ChatAddConversationMemberInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationMembership(
            ConversationMembershipMutationIntent.addMember,
            input,
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      removeConversationMember(
    ChatRemoveConversationMemberInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationMembership(
            ConversationMembershipMutationIntent.removeMember,
            input,
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      changeConversationMemberRole(
    ChatChangeConversationMemberRoleInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationMembership(
            ConversationMembershipMutationIntent.changeMemberRole,
            input,
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      _beginConversationMembership(
    ConversationMembershipMutationIntent intent,
    Object authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(
        const ChatCommandClosed<ConversationMembershipMutationResult>(),
      );
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future.value(
        const ChatCommandAborted<ConversationMembershipMutationResult>(),
      );
    }

    late final Map<String, Object?> authoredJson;
    late final ConversationMembershipMutationInput request;
    try {
      authoredJson = _membershipAuthoredJson(intent, authored);
      ConversationMembershipMutationInput.fromJson({
        ...authoredJson,
        'idempotencyKey': 'membership-validation',
      });
      request = ConversationMembershipMutationInput.fromJson({
        ...authoredJson,
        'idempotencyKey': _generateCommandIdempotencyKey(),
      });
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<
            ConversationMembershipMutationResult>(),
      );
    }

    final durableRuntime = _conversationMembershipRuntime;
    if (durableRuntime != null) {
      return _executeDurableConversationMembership(
        durableRuntime,
        request,
        cancellationSignal: cancellationSignal,
      );
    }

    final command = _ConversationMembershipCommandIntent(
      request: request,
      cancellationSignal: cancellationSignal,
    );
    final lane = _conversationMembershipCommandLanes.putIfAbsent(
      request.conversationId,
      _ConversationMembershipCommandLane.new,
    );
    lane.intents.add(command);
    if (cancellationSignal != null) {
      command.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, command) || command.completer.isCompleted) {
          return;
        }
        if (!lane.intents.remove(command)) return;
        command.completer.complete(
          const ChatCommandAborted<ConversationMembershipMutationResult>(),
        );
        unawaited(command.cancellationSubscription?.cancel());
      });
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drainConversationMembershipLane(
        request.conversationId,
        lane,
      ).whenComplete(() {
        _conversationMembershipCommandDrains.remove(drain);
      });
      _conversationMembershipCommandDrains.add(drain);
    }
    return command.completer.future;
  }

  Future<ChatCommandResult<ConversationMembershipMutationResult>>
      _executeDurableConversationMembership(
    _ConversationMembershipRecoveryRuntime runtime,
    ConversationMembershipMutationInput request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    final identity = _storageActivationIdentity;
    final generation = _storageIdentityGeneration;
    if (identity == null) {
      return const ChatCommandValidationFailure<
          ConversationMembershipMutationResult>();
    }
    try {
      await _awaitCurrentStorageActivation();
    } catch (_) {
      return const ChatCommandValidationFailure<
          ConversationMembershipMutationResult>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return const ChatCommandClosed<ConversationMembershipMutationResult>();
    }
    return runtime.execute(
      request,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<void> _drainConversationMembershipLane(
    ConversationId conversationId,
    _ConversationMembershipCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      final command = lane.intents.first;
      if (command.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = command;
      final request = command.request;
      var result = await _commandDispatcher.dispatch(
        _membershipDescriptor(request),
        request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal: command.cancellationSignal,
        ),
      );
      if (result
          case ChatCommandSuccess<ConversationMembershipMutationResult>(
            :final value,
          )) {
        try {
          final accessRevoked =
              normalizedState.reconcileConversationMembership(value);
          if (accessRevoked) {
            realtimeSession?.clearConversationSubscription(conversationId);
          }
        } catch (_) {
          result = const ChatCommandMalformedResponse<
              ConversationMembershipMutationResult>();
        }
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
    if (identical(_conversationMembershipCommandLanes[conversationId], lane)) {
      _conversationMembershipCommandLanes.remove(conversationId);
    }
  }

  void _closeConversationMembershipCommands() {
    for (final lane in _conversationMembershipCommandLanes.values) {
      final queued = lane.active == null
          ? lane.intents.toList(growable: false)
          : lane.intents.skip(1).toList(growable: false);
      for (final command in queued) {
        lane.intents.remove(command);
        if (command.completer.isCompleted) continue;
        unawaited(command.cancellationSubscription?.cancel());
        command.completer.complete(
          const ChatCommandClosed<ConversationMembershipMutationResult>(),
        );
      }
    }
  }
}
