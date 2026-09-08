part of 'normalized_snapshot_state.dart';

const int messageReminderSnapshotMaximumLimit = 100;

/// Opaque, versioned cursor for the trusted actor's active reminder list.
final class MessageReminderSnapshotCursor {
  MessageReminderSnapshotCursor(String value) : value = _validateCursor(value);

  factory MessageReminderSnapshotCursor.fromJson(Object? json) {
    if (json is! String) {
      throw const FormatException('Reminder cursor must be a string.');
    }
    return MessageReminderSnapshotCursor(json);
  }

  final String value;

  String toJson() => value;

  @override
  bool operator ==(Object other) =>
      other is MessageReminderSnapshotCursor && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Strict list request for the trusted actor's active reminders.
final class MessageReminderListSnapshotInput {
  MessageReminderListSnapshotInput({required this.limit, this.cursor}) {
    if (limit < 1 || limit > messageReminderSnapshotMaximumLimit) {
      throw RangeError.range(
        limit,
        1,
        messageReminderSnapshotMaximumLimit,
        'limit',
      );
    }
  }

  factory MessageReminderListSnapshotInput.fromJson(Object? json) {
    final object = _reminderObject(json, 'input');
    _reminderExactFields(object, const {'limit', 'cursor'}, 'input',
        optional: const {'cursor'});
    final limit = object['limit'];
    if (limit is! int) {
      throw const FormatException('Reminder list limit must be an integer.');
    }
    return MessageReminderListSnapshotInput(
      limit: limit,
      cursor: object['cursor'] == null
          ? null
          : MessageReminderSnapshotCursor.fromJson(object['cursor']),
    );
  }

  final int limit;
  final MessageReminderSnapshotCursor? cursor;

  Map<String, Object?> toJson() => {
        'limit': limit,
        if (cursor case final cursor?) 'cursor': cursor.toJson(),
      };
}

/// One canonical active reminder recovered for the trusted actor.
final class MessageReminderSnapshotEntry {
  const MessageReminderSnapshotEntry({
    required this.conversationId,
    required this.messageId,
    required this.reminderRevision,
    required this.reminder,
  });

  final ConversationId conversationId;
  final MessageId messageId;
  final int reminderRevision;
  final CanonicalScheduledMessageReminder reminder;

  Map<String, Object?> toJson() => {
        'conversationId': conversationId.toJson(),
        'messageId': messageId.toJson(),
        'reminderRevision': reminderRevision,
        'reminder': reminder.toJson(),
      };
}

/// One strictly ordered actor-private reminder snapshot page.
final class MessageReminderListSnapshot {
  MessageReminderListSnapshot._({
    required List<MessageReminderSnapshotEntry> items,
    required this.nextCursor,
  }) : items = List.unmodifiable(items);

  factory MessageReminderListSnapshot.fromJson(
    Object? json, {
    required MessageReminderListSnapshotInput expectedInput,
  }) {
    final request = MessageReminderListSnapshotInput.fromJson(
      expectedInput.toJson(),
    );
    final object = _reminderObject(json, 'snapshot');
    _reminderExactFields(
      object,
      const {'kind', 'privacy', 'items', 'page'},
      'snapshot',
    );
    if (object['kind'] != 'message_reminder_list' ||
        object['privacy'] != 'actor_private') {
      throw const FormatException(
        'Reminder snapshot must be an actor-private reminder list.',
      );
    }
    final rawItems = object['items'];
    if (rawItems is! List || rawItems.length > request.limit) {
      throw const FormatException('Reminder snapshot items are invalid.');
    }

    final items = <MessageReminderSnapshotEntry>[];
    final seen = <MessageId>{};
    var previous = request.cursor == null
        ? null
        : _decodeReminderCursor(request.cursor!.value);
    for (var index = 0; index < rawItems.length; index += 1) {
      final path = 'snapshot.items[$index]';
      final entry = _reminderObject(rawItems[index], path);
      _reminderExactFields(
        entry,
        const {
          'conversationId',
          'messageId',
          'reminderRevision',
          'reminder',
        },
        path,
      );
      final conversationId = ConversationId.fromJson(entry['conversationId']);
      final messageId = MessageId.fromJson(entry['messageId']);
      final revision = entry['reminderRevision'];
      if (revision is! int || revision < 1 || revision > 9007199254740991) {
        throw FormatException('$path.reminderRevision is invalid.');
      }
      final reminder = CanonicalMessageReminder.fromJson(entry['reminder']);
      if (reminder is! CanonicalScheduledMessageReminder ||
          !seen.add(messageId)) {
        throw FormatException('$path must contain one active reminder.');
      }
      final position = (dueAt: reminder.dueAt, messageId: messageId);
      if (previous != null &&
          _compareReminderPositions(position, previous) <= 0) {
        throw const FormatException(
          'Reminder snapshot items are not strictly ordered.',
        );
      }
      previous = position;
      items.add(MessageReminderSnapshotEntry(
        conversationId: conversationId,
        messageId: messageId,
        reminderRevision: revision,
        reminder: reminder,
      ));
    }

    final page = _reminderObject(object['page'], 'snapshot.page');
    _reminderExactFields(page, const {'nextCursor'}, 'snapshot.page');
    final rawNext = page['nextCursor'];
    final nextCursor = rawNext == null
        ? null
        : MessageReminderSnapshotCursor.fromJson(rawNext);
    if (nextCursor != null) {
      if (items.isEmpty) {
        throw const FormatException(
          'A reminder continuation cursor requires a final item.',
        );
      }
      final decoded = _decodeReminderCursor(nextCursor.value);
      final last = items.last;
      if (decoded.dueAt != last.reminder.dueAt ||
          decoded.messageId != last.messageId) {
        throw const FormatException(
          'Reminder continuation cursor does not match the final item.',
        );
      }
    }
    return MessageReminderListSnapshot._(
      items: items,
      nextCursor: nextCursor,
    );
  }

  String get kind => 'message_reminder_list';
  String get privacy => 'actor_private';
  final List<MessageReminderSnapshotEntry> items;
  final MessageReminderSnapshotCursor? nextCursor;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'privacy': privacy,
        'items': [for (final item in items) item.toJson()],
        'page': {'nextCursor': nextCursor?.toJson()},
      };
}

/// One local reminder replacement waiting for command settlement.
final class PendingMessageReminderIntent {
  const PendingMessageReminderIntent({required this.request});

  final MessageReminderRequest request;
}

/// Renderer-neutral latest-local and authoritative reminder state.
final class NormalizedMessageReminderState {
  NormalizedMessageReminderState({
    required this.messageId,
    required this.authoritativeRevision,
    required List<PendingMessageReminderIntent> pendingIntents,
    this.conversationId,
    this.reminder,
    this.authoritativeReminder,
  }) : pendingIntents = List.unmodifiable(pendingIntents);

  final ConversationId? conversationId;
  final MessageId messageId;
  final CanonicalMessageReminder? reminder;
  final CanonicalMessageReminder? authoritativeReminder;
  final int authoritativeRevision;
  final List<PendingMessageReminderIntent> pendingIntents;

  bool get isPending => pendingIntents.isNotEmpty;
  bool get isScheduled => reminder is CanonicalScheduledMessageReminder;
  IsoTimestamp? get dueAt => switch (reminder) {
        CanonicalScheduledMessageReminder(:final dueAt) => dueAt,
        _ => null,
      };
}

extension NormalizedMessageReminderRuntime on NormalizedSnapshotStore {
  NormalizedMessageReminderState messageReminder(MessageId messageId) {
    final state = _state;
    return NormalizedMessageReminderState(
      conversationId: state.messageReminderConversationIds[messageId],
      messageId: messageId,
      reminder: state.currentUserMessageReminders[messageId],
      authoritativeReminder:
          state.authoritativeCurrentUserMessageReminders[messageId],
      authoritativeRevision: state.messageReminderRevisions[messageId] ?? 0,
      pendingIntents:
          state.pendingMessageReminderIntents[messageId] ?? const [],
    );
  }

  Stream<NormalizedMessageReminderState> messageReminderStates(
    MessageId messageId,
  ) {
    _ensureOpen();
    return Stream.multi((events) {
      final subscription = _messageReminderChanges.stream
          .where((id) => id == messageId)
          .listen((_) => events.add(messageReminder(messageId)));
      events.add(messageReminder(messageId));
      events.onCancel = subscription.cancel;
    });
  }

  NormalizedSnapshotState beginOptimisticMessageReminder(
    MessageReminderRequest input,
  ) {
    _ensureOpen();
    final request = MessageReminderRequest.fromJson(input.toJson());
    final previous = _state;
    final knownRevision =
        previous.messageReminderRevisions[request.messageId] ?? 0;
    final knownConversation =
        previous.messageReminderConversationIds[request.messageId];
    if (request.expectedReminderRevision != knownRevision ||
        (knownConversation != null &&
            knownConversation != request.conversationId)) {
      throw const NormalizedSnapshotConflict(
        'Reminder intent did not use authoritative message state.',
      );
    }
    final intents = <PendingMessageReminderIntent>[
      ...?previous.pendingMessageReminderIntents[request.messageId],
      PendingMessageReminderIntent(request: request),
    ];
    final authoritative =
        previous.authoritativeCurrentUserMessageReminders[request.messageId] ??
            (previous.pendingMessageReminderIntents[request.messageId] == null
                ? previous.currentUserMessageReminders[request.messageId]
                : null);
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserMessageReminders: Map.unmodifiable({
          ...previous.currentUserMessageReminders,
          request.messageId: _projectMessageReminder(request),
        }),
        authoritativeCurrentUserMessageReminders: authoritative == null
            ? previous.authoritativeCurrentUserMessageReminders
            : Map.unmodifiable({
                ...previous.authoritativeCurrentUserMessageReminders,
                request.messageId: authoritative,
              }),
        messageReminderConversationIds: Map.unmodifiable({
          ...previous.messageReminderConversationIds,
          request.messageId: request.conversationId,
        }),
        pendingMessageReminderIntents: Map.unmodifiable({
          ...previous.pendingMessageReminderIntents,
          request.messageId:
              List<PendingMessageReminderIntent>.unmodifiable(intents),
        }),
      ),
    );
  }

  void rebaseOptimisticMessageReminder(
    MessageId messageId,
    String idempotencyKey,
    int expectedRevision,
  ) {
    _ensureOpen();
    final previous = _state;
    final existing = previous.pendingMessageReminderIntents[messageId];
    if (existing == null) return;
    final index = existing.indexWhere(
      (intent) => intent.request.idempotencyKey == idempotencyKey,
    );
    if (index < 0 ||
        existing[index].request.expectedReminderRevision == expectedRevision) {
      return;
    }
    final intents = existing.toList(growable: false);
    final old = intents[index].request;
    intents[index] = PendingMessageReminderIntent(
      request: MessageReminderRequest.fromJson({
        ...old.toJson(),
        'expectedReminderRevision': expectedRevision,
      }),
    );
    _commit(
      previous,
      _copyState(
        previous,
        pendingMessageReminderIntents: Map.unmodifiable({
          ...previous.pendingMessageReminderIntents,
          messageId: List<PendingMessageReminderIntent>.unmodifiable(intents),
        }),
      ),
    );
  }

  bool reconcileMessageReminderMutation(
    MessageReminderRequest input,
    MessageReminderResult result,
  ) {
    _ensureOpen();
    final request = MessageReminderRequest.fromJson(input.toJson());
    final parsed = MessageReminderResult.fromJson(
      result.toJson(),
      expectedInput: request,
    );
    if (parsed.reminder == null || parsed.reminderRevision == null) {
      return _settleMessageReminderIntent(
        request.messageId,
        request.idempotencyKey,
      );
    }
    final next = _reconcileMessageReminderCanonicalState(
      _state,
      conversationId: parsed.conversationId,
      messageId: parsed.messageId,
      reminderRevision: parsed.reminderRevision!,
      reminder: parsed.reminder!,
      settlingIdempotencyKey: parsed.idempotencyKey,
    );
    if (identical(next, _state)) return false;
    _commit(_state, next);
    return true;
  }

  bool reconcileMessageReminderCanonical({
    required ConversationId conversationId,
    required MessageId messageId,
    required int reminderRevision,
    required CanonicalMessageReminder reminder,
  }) {
    _ensureOpen();
    final next = _reconcileMessageReminderCanonicalState(
      _state,
      conversationId: conversationId,
      messageId: messageId,
      reminderRevision: reminderRevision,
      reminder: reminder,
    );
    if (identical(next, _state)) return false;
    _commit(_state, next);
    return true;
  }

  NormalizedSnapshotState hydrateMessageReminderList(
    MessageReminderListSnapshot snapshot,
  ) {
    _ensureOpen();
    var next = _state;
    for (final item in snapshot.items) {
      next = _reconcileMessageReminderCanonicalState(
        next,
        conversationId: item.conversationId,
        messageId: item.messageId,
        reminderRevision: item.reminderRevision,
        reminder: item.reminder,
      );
    }
    return _commit(_state, next);
  }

  /// Atomically replaces actor-private reminder authority from a complete list.
  ///
  /// The active-reminder endpoint omits cancelled reminders, so absence in a
  /// completed pagination run is authoritative. Process-local projections are
  /// deliberately discarded and may be restored only after recovery decides
  /// that their expected revision is still safe.
  NormalizedSnapshotState replaceMessageReminderList(
    List<MessageReminderListSnapshot> snapshots,
  ) {
    _ensureOpen();
    var next = _copyState(
      _state,
      currentUserMessageReminders: const {},
      authoritativeCurrentUserMessageReminders: const {},
      messageReminderConversationIds: const {},
      messageReminderRevisions: const {},
      pendingMessageReminderIntents: const {},
    );
    final seen = <MessageId>{};
    for (final snapshot in snapshots) {
      for (final item in snapshot.items) {
        if (!seen.add(item.messageId)) {
          throw const NormalizedSnapshotConflict(
            'Reminder list repeated a message across pages.',
          );
        }
        next = _reconcileMessageReminderCanonicalState(
          next,
          conversationId: item.conversationId,
          messageId: item.messageId,
          reminderRevision: item.reminderRevision,
          reminder: item.reminder,
        );
      }
    }
    return _commit(_state, next);
  }

  NormalizedSnapshotState rollbackOptimisticMessageReminder(
    MessageId messageId,
    String idempotencyKey,
  ) {
    _ensureOpen();
    final previous = _state;
    if (!_settleMessageReminderIntent(messageId, idempotencyKey)) {
      return previous;
    }
    return _state;
  }

  NormalizedSnapshotState clearActorPrivateMessageReminders() {
    _ensureOpen();
    final previous = _state;
    if (previous.currentUserMessageReminders.isEmpty &&
        previous.authoritativeCurrentUserMessageReminders.isEmpty &&
        previous.messageReminderConversationIds.isEmpty &&
        previous.messageReminderRevisions.isEmpty &&
        previous.pendingMessageReminderIntents.isEmpty) {
      return previous;
    }
    return _commit(
      previous,
      _copyState(
        previous,
        currentUserMessageReminders: const {},
        authoritativeCurrentUserMessageReminders: const {},
        messageReminderConversationIds: const {},
        messageReminderRevisions: const {},
        pendingMessageReminderIntents: const {},
      ),
    );
  }

  bool _settleMessageReminderIntent(
    MessageId messageId,
    String idempotencyKey,
  ) {
    final previous = _state;
    final existing = previous.pendingMessageReminderIntents[messageId];
    if (existing == null ||
        !existing.any(
          (intent) => intent.request.idempotencyKey == idempotencyKey,
        )) {
      return false;
    }
    final intents = existing
        .where((intent) => intent.request.idempotencyKey != idempotencyKey)
        .toList(growable: false);
    _commit(previous, _reprojectMessageReminder(previous, messageId, intents));
    return true;
  }
}

NormalizedSnapshotState _reconcileMessageReminderCanonicalState(
  NormalizedSnapshotState state, {
  required ConversationId conversationId,
  required MessageId messageId,
  required int reminderRevision,
  required CanonicalMessageReminder reminder,
  String? settlingIdempotencyKey,
}) {
  if (reminderRevision < 0 || reminderRevision > 9007199254740991) {
    throw const NormalizedSnapshotConflict('Reminder revision is invalid.');
  }
  final knownConversation = state.messageReminderConversationIds[messageId];
  if (knownConversation != null && knownConversation != conversationId) {
    throw const NormalizedSnapshotConflict(
      'Reminder message changed conversation identity.',
    );
  }
  final knownRevision = state.messageReminderRevisions[messageId] ?? 0;
  final authoritative =
      state.authoritativeCurrentUserMessageReminders[messageId];
  if (reminderRevision == knownRevision &&
      authoritative != null &&
      !_sameValue(authoritative.toJson(), reminder.toJson())) {
    throw NormalizedSnapshotConflict(
      'Reminder $messageId changed at revision $knownRevision.',
    );
  }
  final acceptsCanonical = reminderRevision > knownRevision ||
      (reminderRevision == knownRevision && authoritative == null);
  final intents = <PendingMessageReminderIntent>[
    ...?state.pendingMessageReminderIntents[messageId],
  ];
  final before = intents.length;
  if (settlingIdempotencyKey != null) {
    intents.removeWhere(
      (intent) => intent.request.idempotencyKey == settlingIdempotencyKey,
    );
  }
  if (!acceptsCanonical && before == intents.length) return state;

  var next = state;
  if (acceptsCanonical) {
    next = _copyState(
      next,
      authoritativeCurrentUserMessageReminders: Map.unmodifiable({
        ...next.authoritativeCurrentUserMessageReminders,
        messageId: reminder,
      }),
      messageReminderConversationIds: Map.unmodifiable({
        ...next.messageReminderConversationIds,
        messageId: conversationId,
      }),
      messageReminderRevisions: Map.unmodifiable({
        ...next.messageReminderRevisions,
        messageId: reminderRevision,
      }),
    );
  }
  return _reprojectMessageReminder(next, messageId, intents);
}

NormalizedSnapshotState _reprojectMessageReminder(
  NormalizedSnapshotState state,
  MessageId messageId,
  List<PendingMessageReminderIntent> intents,
) {
  final pending = <MessageId, List<PendingMessageReminderIntent>>{
    ...state.pendingMessageReminderIntents,
  };
  if (intents.isEmpty) {
    pending.remove(messageId);
  } else {
    pending[messageId] = List.unmodifiable(intents);
  }
  final visible = <MessageId, CanonicalMessageReminder>{
    ...state.currentUserMessageReminders,
  };
  if (intents.isNotEmpty) {
    visible[messageId] = _projectMessageReminder(intents.last.request);
  } else if (state.authoritativeCurrentUserMessageReminders[messageId]
      case final authoritative?) {
    visible[messageId] = authoritative;
  } else {
    visible.remove(messageId);
  }
  return _copyState(
    state,
    currentUserMessageReminders: Map.unmodifiable(visible),
    pendingMessageReminderIntents: Map.unmodifiable(pending),
  );
}

CanonicalMessageReminder _projectMessageReminder(
        MessageReminderRequest input) =>
    switch (input) {
      SetMessageReminderRequest(:final dueAt) =>
        CanonicalScheduledMessageReminder(dueAt),
      CancelMessageReminderRequest() =>
        const CanonicalCancelledMessageReminder(),
    };

Object? _messageReminderStateValue(
  NormalizedSnapshotState state,
  MessageId messageId,
) =>
    {
      'conversationId':
          state.messageReminderConversationIds[messageId]?.toJson(),
      'reminder': state.currentUserMessageReminders[messageId]?.toJson(),
      'authoritative':
          state.authoritativeCurrentUserMessageReminders[messageId]?.toJson(),
      'revision': state.messageReminderRevisions[messageId] ?? 0,
      'pending': [
        for (final intent in state.pendingMessageReminderIntents[messageId] ??
            const <PendingMessageReminderIntent>[])
          intent.request.toJson(),
      ],
    };

String _validateCursor(String value) {
  _decodeReminderCursor(value);
  return value;
}

({IsoTimestamp dueAt, MessageId messageId}) _decodeReminderCursor(
  String cursor,
) {
  final match =
      RegExp(r'^handrail-message-reminders\.v(\d+)\.(.+)$').firstMatch(cursor);
  if (match == null || match.group(1) != '1') {
    throw const FormatException('Reminder cursor envelope is invalid.');
  }
  try {
    final payload = jsonDecode(Uri.decodeComponent(match.group(2)!));
    if (payload is! List || payload.length != 2) {
      throw const FormatException();
    }
    return (
      dueAt: IsoTimestamp.fromJson(payload[0]),
      messageId: MessageId.fromJson(payload[1]),
    );
  } catch (_) {
    throw const FormatException('Reminder cursor payload is invalid.');
  }
}

int _compareReminderPositions(
  ({IsoTimestamp dueAt, MessageId messageId}) left,
  ({IsoTimestamp dueAt, MessageId messageId}) right,
) {
  final time = DateTime.parse(left.dueAt.value)
      .compareTo(DateTime.parse(right.dueAt.value));
  return time != 0
      ? time
      : left.messageId.value.compareTo(right.messageId.value);
}

Map<String, Object?> _reminderObject(Object? value, String path) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$path must be an object.');
  }
  return value.cast<String, Object?>();
}

void _reminderExactFields(
  Map<String, Object?> value,
  Set<String> fields,
  String path, {
  Set<String> optional = const {},
}) {
  final required = fields.difference(optional);
  if (value.keys.any((key) => !fields.contains(key)) ||
      !value.keys.toSet().containsAll(required)) {
    throw FormatException('$path has invalid fields.');
  }
}
