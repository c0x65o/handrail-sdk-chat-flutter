part of '../handrail_chat_client.dart';

/// Generates the request-correlation identity for one conversation creation.
typedef ChatConversationClientRequestIdGenerator = String Function();

/// Authored fields accepted by [HandrailChatClient.createChannel].
final class ChatCreateChannelInput {
  const ChatCreateChannelInput({
    required this.name,
    required this.visibility,
    this.entity,
  });

  final String name;
  final ConversationVisibility visibility;
  final HostEntityReference? entity;

  @override
  String toString() => 'ChatCreateChannelInput(hasEntity: ${entity != null})';
}

/// Authored fields accepted by [HandrailChatClient.createDirect].
final class ChatCreateDirectInput {
  ChatCreateDirectInput({required List<UserId> intendedMemberUserIds})
      : intendedMemberUserIds = List<UserId>.unmodifiable(
          intendedMemberUserIds,
        );

  final List<UserId> intendedMemberUserIds;

  @override
  String toString() =>
      'ChatCreateDirectInput(memberCount: ${intendedMemberUserIds.length})';
}

/// Authored fields accepted by [HandrailChatClient.createGroupDirect].
final class ChatCreateGroupDirectInput {
  ChatCreateGroupDirectInput({required List<UserId> intendedMemberUserIds})
      : intendedMemberUserIds = List<UserId>.unmodifiable(
          intendedMemberUserIds,
        );

  final List<UserId> intendedMemberUserIds;

  @override
  String toString() => 'ChatCreateGroupDirectInput(memberCount: '
      '${intendedMemberUserIds.length})';
}

typedef _ConversationCreationInputParser<
        Input extends ConversationCreationInput>
    = Input Function(Object? json);
typedef _ConversationCreationResultParser<
        Input extends ConversationCreationInput,
        Result extends ConversationCreationResult>
    = Result Function(Object? json, Input expectedInput);

const _conversationCreationValidationIdentity =
    'conversation-creation-validation';

Map<String, Object?> _channelCreationAuthoredJson(
  ChatCreateChannelInput input,
) =>
    <String, Object?>{
      'operation': 'create_conversation',
      'type': 'channel',
      'name': input.name,
      'visibility': input.visibility.toJson(),
      if (input.entity case final entity?) 'entity': entity.toJson(),
    };

Map<String, Object?> _participantCreationAuthoredJson(
  ConversationCreationType type,
  List<UserId> intendedMemberUserIds,
) {
  final canonicalIds = List<UserId>.of(intendedMemberUserIds)
    ..sort((left, right) => left.value.compareTo(right.value));
  return <String, Object?>{
    'operation': 'create_conversation',
    'type': type.toJson(),
    'visibility': ConversationVisibility.private.toJson(),
    'intendedMemberUserIds': canonicalIds.map((id) => id.toJson()).toList(),
  };
}

String _conversationCreationLogicalKey(ConversationCreationInput input) {
  if (input is CreateChannelConversationInput) {
    return jsonEncode(<Object?>[
      'create',
      input.type.toJson(),
      input.name,
      input.visibility.toJson(),
      input.entity?.type,
      input.entity?.id,
    ]);
  }
  final participantInput = input as ParticipantConversationCreationInput;
  return jsonEncode(<Object?>[
    'create',
    input.type.toJson(),
    participantInput.intendedMemberUserIds
        .map((id) => id.toJson())
        .toList(growable: false),
  ]);
}

/// Pure-Dart conversation creation commands on [HandrailChatClient].
extension HandrailChatConversationCreationCommands on HandrailChatClient {
  /// Creates a named channel through retry-safe `POST /conversations`.
  Future<ChatCommandResult<ChannelConversationCreationResult>> createChannel(
    ChatCreateChannelInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _beginConversationCreation(
        authored: _channelCreationAuthoredJson(input),
        parseInput: CreateChannelConversationInput.fromJson,
        parseResult: (json, expected) =>
            ChannelConversationCreationResult.fromJson(
          json,
          expectedInput: expected,
        ),
        cancellationSignal: cancellationSignal,
      );

  /// Resolves or creates the canonical private one-to-one conversation.
  Future<ChatCommandResult<DirectConversationCreationResult>> createDirect(
    ChatCreateDirectInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _beginConversationCreation(
        authored: _participantCreationAuthoredJson(
          ConversationCreationType.direct,
          input.intendedMemberUserIds,
        ),
        parseInput: CreateDirectConversationInput.fromJson,
        parseResult: (json, expected) =>
            DirectConversationCreationResult.fromJson(
          json,
          expectedInput: expected,
        ),
        cancellationSignal: cancellationSignal,
      );

  /// Resolves or creates one canonical private group-direct conversation.
  Future<ChatCommandResult<GroupDirectConversationCreationResult>>
      createGroupDirect(
    ChatCreateGroupDirectInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
          _beginConversationCreation(
            authored: _participantCreationAuthoredJson(
              ConversationCreationType.groupDirect,
              input.intendedMemberUserIds,
            ),
            parseInput: CreateGroupDirectConversationInput.fromJson,
            parseResult: (json, expected) =>
                GroupDirectConversationCreationResult.fromJson(
              json,
              expectedInput: expected,
            ),
            cancellationSignal: cancellationSignal,
          );

  Future<ChatCommandResult<Result>> _beginConversationCreation<
      Input extends ConversationCreationInput,
      Result extends ConversationCreationResult>({
    required Map<String, Object?> authored,
    required _ConversationCreationInputParser<Input> parseInput,
    required _ConversationCreationResultParser<Input, Result> parseResult,
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future<ChatCommandResult<Result>>.value(
        ChatCommandClosed<Result>(),
      );
    }
    if (cancellationSignal?.isCancelled == true) {
      return Future<ChatCommandResult<Result>>.value(
        ChatCommandAborted<Result>(),
      );
    }

    late final Input validatedAuthored;
    try {
      validatedAuthored = parseInput(<String, Object?>{
        ...authored,
        'idempotencyKey': _conversationCreationValidationIdentity,
        'clientRequestId': _conversationCreationValidationIdentity,
      });
    } catch (_) {
      return Future<ChatCommandResult<Result>>.value(
        ChatCommandValidationFailure<Result>(),
      );
    }

    final durableRuntime = _conversationCreationRuntime;
    if (durableRuntime != null) {
      return _executeDurableConversationCreation<Result>(
        durableRuntime,
        authored,
        cancellationSignal: cancellationSignal,
      );
    }

    final logicalKey = _conversationCreationLogicalKey(validatedAuthored);
    final active = _conversationCreationOperations[logicalKey];
    if (active != null) {
      return active as Future<ChatCommandResult<Result>>;
    }

    late final Input request;
    try {
      request = parseInput(<String, Object?>{
        ...authored,
        'idempotencyKey': _generateCommandIdempotencyKey(),
        'clientRequestId': _generateConversationClientRequestId(),
      });
    } catch (_) {
      return Future<ChatCommandResult<Result>>.value(
        ChatCommandValidationFailure<Result>(),
      );
    }

    final descriptor = ChatCommandDescriptor<Input, Input, Result>(
      name: 'conversation.create',
      method: ChatCommandMethod.post,
      path: '/conversations',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (input) => parseInput(input.toJson()),
      parseResult: (json) => parseResult(json, request),
    );
    final dispatch = _commandDispatcher.dispatch(
      descriptor,
      request,
      options: ChatCommandDispatchOptions(
        idempotencyKey: request.idempotencyKey,
        cancellationSignal: cancellationSignal,
      ),
    );
    final reconciled = dispatch.then<ChatCommandResult<Result>>((result) {
      if (result case ChatCommandSuccess<Result>(:final value)) {
        try {
          normalizedState.reconcileConversationCreation(value);
        } catch (_) {
          return ChatCommandMalformedResponse<Result>();
        }
      }
      return result;
    });

    late final Future<ChatCommandResult<Result>> tracked;
    tracked = reconciled.whenComplete(() {
      if (identical(_conversationCreationOperations[logicalKey], tracked)) {
        _conversationCreationOperations.remove(logicalKey);
      }
    });
    _conversationCreationOperations[logicalKey] = tracked;
    return tracked;
  }

  Future<ChatCommandResult<Result>> _executeDurableConversationCreation<
      Result extends ConversationCreationResult>(
    _ConversationCreationRecoveryRuntime runtime,
    Map<String, Object?> authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    final identity = _storageActivationIdentity;
    final generation = _storageIdentityGeneration;
    if (identity == null) return ChatCommandValidationFailure<Result>();
    try {
      await _awaitCurrentStorageActivation();
    } catch (_) {
      return ChatCommandValidationFailure<Result>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return ChatCommandClosed<Result>();
    }
    final result = await runtime.execute(
      authored,
      cancellationSignal: cancellationSignal,
    );
    return switch (result) {
      ChatCommandSuccess<ConversationCreationResult>(:final value)
          when value is Result =>
        ChatCommandSuccess<Result>(value),
      ChatCommandValidationFailure<ConversationCreationResult>() =>
        ChatCommandValidationFailure<Result>(),
      ChatCommandAuthenticationFailure<ConversationCreationResult>(
        :final httpStatus,
      ) =>
        ChatCommandAuthenticationFailure<Result>(httpStatus: httpStatus),
      ChatCommandConflict<ConversationCreationResult>(:final httpStatus) =>
        ChatCommandConflict<Result>(httpStatus: httpStatus!),
      ChatCommandFeatureDisabled<ConversationCreationResult>(
        :final httpStatus,
      ) =>
        ChatCommandFeatureDisabled<Result>(httpStatus: httpStatus!),
      ChatCommandUnsupported<ConversationCreationResult>(:final httpStatus) =>
        ChatCommandUnsupported<Result>(httpStatus: httpStatus!),
      ChatCommandRejected<ConversationCreationResult>(:final httpStatus) =>
        ChatCommandRejected<Result>(httpStatus: httpStatus!),
      ChatCommandMalformedResponse<ConversationCreationResult>(
        :final httpStatus,
      ) =>
        ChatCommandMalformedResponse<Result>(httpStatus: httpStatus),
      ChatCommandTransportFailure<ConversationCreationResult>(
        :final httpStatus,
      ) =>
        ChatCommandTransportFailure<Result>(httpStatus: httpStatus),
      ChatCommandAborted<ConversationCreationResult>() =>
        ChatCommandAborted<Result>(),
      ChatCommandClosed<ConversationCreationResult>() =>
        ChatCommandClosed<Result>(),
      _ => ChatCommandMalformedResponse<Result>(),
    };
  }
}
