import 'dart:convert';

import '../generated/conversation_archive.dart';
import '../generated/conversation_creation.dart';
import '../generated/conversation_preference.dart';
import '../generated/delete_message.dart';
import '../generated/conversation_membership.dart';
import '../generated/device_push_token.dart';
import '../generated/draft_mutation.dart';
import '../generated/edit_message.dart';
import '../generated/forward_message.dart';
import '../generated/huddle_session.dart';
import '../generated/identifiers.dart';
import '../generated/message_reminder.dart';
import '../generated/read_cursor_mutation.dart';
import '../generated/reaction_mutations.dart';
import '../generated/realtime_session.dart' show EventCursor;
import '../generated/send_message.dart';
import '../generated/thread_follow_mutation.dart';
import 'normalized_snapshot_state.dart';

/// Envelope schema version for non-snapshot records and legacy snapshots.
const int applicationChatStorageSchemaVersion = 1;

/// Envelope schema version emitted for normalized snapshots.
const int applicationChatNormalizedSnapshotStorageSchemaVersion = 2;

/// Generated `send-message.json` contract version supported by this runtime.
const int applicationChatSendMessageContractVersion = 1;

/// Read-cursor mutation contract version supported by persisted intents.
const int applicationChatReadCursorContractVersion = 1;

/// Message-mutation contract version supported by persisted intents.
const int applicationChatMessageMutationContractVersion = 1;

/// Conversation-membership contract version supported by persisted intents.
const int applicationChatConversationMembershipContractVersion = 1;

/// Conversation-creation contract version supported by persisted intents.
const int applicationChatConversationCreationContractVersion = 1;

/// Conversation-preference contract version supported by persisted intents.
const int applicationChatConversationPreferenceContractVersion = 1;

/// Thread-follow mutation contract version supported by persisted intents.
const int applicationChatThreadFollowContractVersion = 1;

/// Message-reminder contract version supported by persisted intents.
const int applicationChatMessageReminderContractVersion = 1;

/// Conversation-archive contract version supported by persisted intents.
const int applicationChatConversationArchiveContractVersion = 1;

/// Huddle-command contract version supported by persisted intents.
const int applicationChatHuddleCommandContractVersion = 1;

/// Generated `draft.json` mutation contract version supported by storage.
const int applicationChatDraftMutationContractVersion = 1;

/// Maximum UTF-8 size of one encoded application chat storage record.
const int maxApplicationChatStorageRecordBytes = 5 * 1024 * 1024;

/// Maximum compare/exchange attempts for one application storage mutation.
const int maxApplicationChatStorageMutationAttempts = 8;

/// Stable code for an exhausted application storage mutation.
const String applicationChatStorageContentionErrorCode =
    'application_chat_storage_contention';

/// Sanitized message for an exhausted application storage mutation.
const String applicationChatStorageContentionErrorMessage =
    'Application chat storage mutation is unavailable due to contention';

/// Maximum durable send intents retained for one storage identity.
const int maxApplicationChatQueuedSendIntents = 1000;

/// Maximum UTF-8 size of one encoded queued send intent.
const int maxApplicationChatQueuedSendIntentBytes = 256 * 1024;

/// Maximum durable read-cursor intents retained for one storage identity.
const int maxApplicationChatQueuedReadCursorIntents = 1000;

/// Maximum UTF-8 size of one encoded queued read-cursor intent.
const int maxApplicationChatQueuedReadCursorIntentBytes = 16 * 1024;

/// Maximum durable message-mutation intents retained for one identity.
const int maxApplicationChatQueuedMessageMutationIntents = 1000;

/// Maximum UTF-8 size of one encoded queued message-mutation intent.
const int maxApplicationChatQueuedMessageMutationIntentBytes = 256 * 1024;

/// Maximum durable membership intents retained for one storage identity.
const int maxApplicationChatQueuedConversationMembershipIntents = 1000;

/// Maximum UTF-8 size of one encoded queued membership intent.
const int maxApplicationChatQueuedConversationMembershipIntentBytes = 16 * 1024;

/// Maximum durable conversation-creation intents for one storage identity.
const int maxApplicationChatQueuedConversationCreationIntents = 1000;

/// Maximum intended members retained by one conversation-creation intent.
const int maxApplicationChatConversationCreationMembers = 100;

/// Maximum UTF-8 size of one encoded queued conversation-creation intent.
const int maxApplicationChatQueuedConversationCreationIntentBytes = 64 * 1024;

/// Maximum durable conversation-preference intents for one storage identity.
const int maxApplicationChatQueuedConversationPreferenceIntents = 1000;

/// Maximum UTF-8 size of one encoded queued conversation-preference intent.
const int maxApplicationChatQueuedConversationPreferenceIntentBytes = 16 * 1024;

/// Maximum durable thread-follow intents retained for one storage identity.
const int maxApplicationChatQueuedThreadFollowIntents = 1000;

/// Maximum UTF-8 size of one encoded queued thread-follow intent.
const int maxApplicationChatQueuedThreadFollowIntentBytes = 16 * 1024;

/// Maximum durable message-reminder intents retained for one storage identity.
const int maxApplicationChatQueuedMessageReminderIntents = 1000;

/// Maximum UTF-8 size of one encoded queued message-reminder intent.
const int maxApplicationChatQueuedMessageReminderIntentBytes = 16 * 1024;

/// Maximum durable archive intents retained for one storage identity.
const int maxApplicationChatQueuedConversationArchiveIntents = 1000;

/// Maximum UTF-8 size of one encoded queued conversation-archive intent.
const int maxApplicationChatQueuedConversationArchiveIntentBytes = 16 * 1024;

/// Maximum durable huddle-command intents retained for one storage identity.
const int maxApplicationChatQueuedHuddleCommandIntents = 1000;

/// Maximum UTF-8 size of one encoded queued huddle-command intent.
const int maxApplicationChatQueuedHuddleCommandIntentBytes = 1024;

/// Maximum UTF-8 size of the complete queued huddle-command record.
const int maxApplicationChatQueuedHuddleCommandIntentsRecordBytes = 256 * 1024;

/// Maximum retained draft intent, one per conversation, for one identity.
const int maxApplicationChatQueuedDraftConversations = 500;

/// Maximum UTF-8 size of one encoded queued draft intent.
const int maxApplicationChatQueuedDraftIntentBytes = 128 * 1024;

const int _maxApplicationChatIdentityComponentUtf8Bytes = 512;
const int _maxApplicationChatIntentIdentifierUtf8Bytes = 512;
const int _maxApplicationChatConversationCreationAuthoredUtf8Bytes = 4096;
const int _maxApplicationChatIntentTimestampCharacters = 64;
const int _maxApplicationChatMessageTextCharacters = 100000;
const int _maxApplicationChatMessageCollectionEntries = 1000;
const int _maxSafeJsonInteger = 9007199254740991;

/// The identity boundary for all application-owned chat records.
final class ApplicationChatStorageIdentity {
  ApplicationChatStorageIdentity({
    required this.tenantId,
    required this.userId,
    required this.deviceId,
  }) {
    _requireBoundedNonBlank(
      tenantId.value,
      'tenantId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
    _requireBoundedNonBlank(
      userId.value,
      'userId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
    _requireBoundedNonBlank(
      deviceId.value,
      'deviceId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
  }

  factory ApplicationChatStorageIdentity.fromJson(Object? json) {
    final object = _readObject(json, 'ApplicationChatStorageIdentity');
    _expectFields(
      object,
      const {'tenantId', 'userId', 'deviceId'},
      'ApplicationChatStorageIdentity',
    );
    final tenantId = TenantId.fromJson(
      _required(object, 'tenantId', 'ApplicationChatStorageIdentity'),
    );
    final userId = UserId.fromJson(
      _required(object, 'userId', 'ApplicationChatStorageIdentity'),
    );
    final deviceId = DeviceId.fromJson(
      _required(object, 'deviceId', 'ApplicationChatStorageIdentity'),
    );
    _requireBoundedNonBlankFormat(
      tenantId.value,
      'ApplicationChatStorageIdentity.tenantId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
    _requireBoundedNonBlankFormat(
      userId.value,
      'ApplicationChatStorageIdentity.userId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
    _requireBoundedNonBlankFormat(
      deviceId.value,
      'ApplicationChatStorageIdentity.deviceId',
      _maxApplicationChatIdentityComponentUtf8Bytes,
    );
    return ApplicationChatStorageIdentity(
      tenantId: tenantId,
      userId: userId,
      deviceId: deviceId,
    );
  }

  final TenantId tenantId;
  final UserId userId;
  final DeviceId deviceId;

  Map<String, Object?> toJson() => {
        'tenantId': tenantId.toJson(),
        'userId': userId.toJson(),
        'deviceId': deviceId.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is ApplicationChatStorageIdentity &&
      other.tenantId == tenantId &&
      other.userId == userId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(tenantId, userId, deviceId);
}

/// Closed set of records owned by [ApplicationChatStorage].
enum ApplicationChatStorageRecordKind {
  realtimeCursor('realtime_cursor'),
  normalizedSnapshot('normalized_snapshot'),
  queuedCommandMetadata('queued_command_metadata'),
  queuedSendMessageIntents('queued_send_message_intents'),
  queuedReadCursorIntents('queued_read_cursor_intents'),
  queuedMessageMutationIntents('queued_message_mutation_intents'),
  queuedConversationMembershipIntents(
    'queued_conversation_membership_intents',
  ),
  queuedConversationCreationIntents(
    'queued_conversation_creation_intents',
  ),
  queuedConversationPreferenceIntents(
    'queued_conversation_preference_intents',
  ),
  queuedThreadFollowIntents('queued_thread_follow_intents'),
  queuedMessageReminderIntents('queued_message_reminder_intents'),
  queuedConversationArchiveIntents('queued_conversation_archive_intents'),
  queuedHuddleCommandIntents('queued_huddle_command_intents'),
  queuedDraftIntents('queued_draft_intents'),
  pushTokenRevisions('push_token_revisions');

  const ApplicationChatStorageRecordKind(this.wireValue);

  static ApplicationChatStorageRecordKind fromJson(Object? json) =>
      switch (json) {
        'realtime_cursor' => ApplicationChatStorageRecordKind.realtimeCursor,
        'normalized_snapshot' =>
          ApplicationChatStorageRecordKind.normalizedSnapshot,
        'queued_command_metadata' =>
          ApplicationChatStorageRecordKind.queuedCommandMetadata,
        'queued_send_message_intents' =>
          ApplicationChatStorageRecordKind.queuedSendMessageIntents,
        'queued_read_cursor_intents' =>
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        'queued_message_mutation_intents' =>
          ApplicationChatStorageRecordKind.queuedMessageMutationIntents,
        'queued_conversation_membership_intents' =>
          ApplicationChatStorageRecordKind.queuedConversationMembershipIntents,
        'queued_conversation_creation_intents' =>
          ApplicationChatStorageRecordKind.queuedConversationCreationIntents,
        'queued_conversation_preference_intents' =>
          ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents,
        'queued_thread_follow_intents' =>
          ApplicationChatStorageRecordKind.queuedThreadFollowIntents,
        'queued_message_reminder_intents' =>
          ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
        'queued_conversation_archive_intents' =>
          ApplicationChatStorageRecordKind.queuedConversationArchiveIntents,
        'queued_huddle_command_intents' =>
          ApplicationChatStorageRecordKind.queuedHuddleCommandIntents,
        'queued_draft_intents' =>
          ApplicationChatStorageRecordKind.queuedDraftIntents,
        'push_token_revisions' =>
          ApplicationChatStorageRecordKind.pushTokenRevisions,
        _ => throw FormatException(
            'Unsupported application chat storage record kind: $json.',
          ),
      };

  final String wireValue;
}

/// A versioned, identity-scoped record accepted by application chat storage.
sealed class ApplicationChatStorageRecord {
  const ApplicationChatStorageRecord._({required this.identity});

  factory ApplicationChatStorageRecord.fromJson(Object? json) {
    final object = _readObject(json, 'ApplicationChatStorageRecord');
    _expectFields(
      object,
      const {'schemaVersion', 'kind', 'identity', 'payload'},
      'ApplicationChatStorageRecord',
    );
    final kind = ApplicationChatStorageRecordKind.fromJson(
      _required(object, 'kind', 'ApplicationChatStorageRecord'),
    );
    final version = _readInt(
      _required(object, 'schemaVersion', 'ApplicationChatStorageRecord'),
      'ApplicationChatStorageRecord.schemaVersion',
    );
    final supportedVersion = version == applicationChatStorageSchemaVersion ||
        (kind == ApplicationChatStorageRecordKind.normalizedSnapshot &&
            version == applicationChatNormalizedSnapshotStorageSchemaVersion);
    if (!supportedVersion) {
      throw FormatException(
        'Unsupported application chat storage schema version: $version.',
      );
    }
    final identity = ApplicationChatStorageIdentity.fromJson(
      _required(object, 'identity', 'ApplicationChatStorageRecord'),
    );
    final payload = _required(
      object,
      'payload',
      'ApplicationChatStorageRecord',
    );
    final record = switch (kind) {
      ApplicationChatStorageRecordKind.realtimeCursor =>
        ApplicationChatRealtimeCursorRecord._fromPayload(identity, payload),
      ApplicationChatStorageRecordKind.normalizedSnapshot =>
        ApplicationChatNormalizedSnapshotRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedCommandMetadata =>
        ApplicationChatQueuedCommandMetadataRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedSendMessageIntents =>
        ApplicationChatQueuedSendMessageIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedReadCursorIntents =>
        ApplicationChatQueuedReadCursorIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents =>
        ApplicationChatQueuedMessageMutationIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedConversationMembershipIntents =>
        ApplicationChatQueuedConversationMembershipIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedConversationCreationIntents =>
        ApplicationChatQueuedConversationCreationIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents =>
        ApplicationChatQueuedConversationPreferenceIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedThreadFollowIntents =>
        ApplicationChatQueuedThreadFollowIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedMessageReminderIntents =>
        ApplicationChatQueuedMessageReminderIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedConversationArchiveIntents =>
        ApplicationChatQueuedConversationArchiveIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedHuddleCommandIntents =>
        ApplicationChatQueuedHuddleCommandIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.queuedDraftIntents =>
        ApplicationChatQueuedDraftIntentsRecord._fromPayload(
          identity,
          payload,
        ),
      ApplicationChatStorageRecordKind.pushTokenRevisions =>
        ApplicationChatPushTokenRevisionsRecord._fromPayload(
          identity,
          payload,
        ),
    };
    _validateSecretFreeJson(record.toJson());
    return record;
  }

  final ApplicationChatStorageIdentity identity;
  ApplicationChatStorageRecordKind get kind;

  Map<String, Object?> payloadToJson();

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'schemaVersion': kind == ApplicationChatStorageRecordKind.normalizedSnapshot
          ? applicationChatNormalizedSnapshotStorageSchemaVersion
          : applicationChatStorageSchemaVersion,
      'kind': kind.wireValue,
      'identity': identity.toJson(),
      'payload': payloadToJson(),
    };
    _validateSecretFreeJson(json);
    return json;
  }

  /// Returns a detached JSON string suitable for an application adapter.
  String encode() {
    final encoded = jsonEncode(toJson());
    if (_exceedsUtf8ByteLimit(
      encoded,
      maxApplicationChatStorageRecordBytes,
    )) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    return encoded;
  }

  static ApplicationChatStorageRecord decode(String encoded) {
    if (_exceedsUtf8ByteLimit(
      encoded,
      maxApplicationChatStorageRecordBytes,
    )) {
      throw const FormatException(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    Object? json;
    try {
      json = jsonDecode(encoded);
    } on FormatException {
      throw const FormatException('Application chat storage JSON is invalid.');
    }
    return ApplicationChatStorageRecord.fromJson(json);
  }
}

/// The last accepted durable realtime cursor for one identity.
final class ApplicationChatRealtimeCursorRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatRealtimeCursorRecord({
    required super.identity,
    required this.cursor,
  }) : super._();

  factory ApplicationChatRealtimeCursorRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'RealtimeCursorPayload');
    _expectFields(object, const {'cursor'}, 'RealtimeCursorPayload');
    return ApplicationChatRealtimeCursorRecord(
      identity: identity,
      cursor: EventCursor.fromJson(
        _required(object, 'cursor', 'RealtimeCursorPayload'),
      ),
    );
  }

  final EventCursor cursor;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.realtimeCursor;

  @override
  Map<String, Object?> payloadToJson() => {'cursor': cursor.toJson()};
}

/// A canonical immutable normalized snapshot for one identity.
final class ApplicationChatNormalizedSnapshotRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatNormalizedSnapshotRecord({
    required super.identity,
    required this.snapshot,
  }) : super._() {
    _validateSnapshotTenant(snapshot, identity.tenantId);
    _validateSecretFreeJson(
      NormalizedSnapshotStateStorageCodec.encode(snapshot),
    );
  }

  factory ApplicationChatNormalizedSnapshotRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'NormalizedSnapshotPayload');
    _expectFields(object, const {'snapshot'}, 'NormalizedSnapshotPayload');
    final snapshot = NormalizedSnapshotStateStorageCodec.decode(
      _required(object, 'snapshot', 'NormalizedSnapshotPayload'),
    );
    try {
      return ApplicationChatNormalizedSnapshotRecord(
        identity: identity,
        snapshot: snapshot,
      );
    } on ArgumentError {
      throw const FormatException(
        'Stored normalized snapshot does not match its tenant identity.',
      );
    }
  }

  final NormalizedSnapshotState snapshot;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.normalizedSnapshot;

  @override
  Map<String, Object?> payloadToJson() => {
        'snapshot': NormalizedSnapshotStateStorageCodec.encode(snapshot),
      };
}

/// Closed command kinds whose queue lifecycle may be described by metadata.
enum ApplicationChatQueuedCommandKind {
  sendMessage('send_message');

  const ApplicationChatQueuedCommandKind(this.wireValue);

  static ApplicationChatQueuedCommandKind fromJson(Object? json) =>
      switch (json) {
        'send_message' => ApplicationChatQueuedCommandKind.sendMessage,
        _ => throw FormatException('Unsupported queued command kind: $json.'),
      };

  final String wireValue;
}

/// Secret-free queue bookkeeping. It intentionally cannot hold a request.
final class ApplicationChatQueuedCommandMetadata {
  ApplicationChatQueuedCommandMetadata({
    required this.commandId,
    required this.commandKind,
    required this.enqueuedAt,
    required this.attemptCount,
  }) {
    _requireNonBlank(commandId, 'commandId');
    _requireNonBlank(enqueuedAt.value, 'enqueuedAt');
    if (DateTime.tryParse(enqueuedAt.value) == null) {
      throw ArgumentError.value(
        enqueuedAt.value,
        'enqueuedAt',
        'must be an ISO-8601 timestamp',
      );
    }
    if (attemptCount < 0) {
      throw ArgumentError.value(
        attemptCount,
        'attemptCount',
        'must not be negative',
      );
    }
  }

  factory ApplicationChatQueuedCommandMetadata.fromJson(Object? json) {
    final object = _readObject(json, 'QueuedCommandMetadata');
    _expectFields(
      object,
      const {'commandId', 'commandKind', 'enqueuedAt', 'attemptCount'},
      'QueuedCommandMetadata',
    );
    final commandId = _readString(
      _required(object, 'commandId', 'QueuedCommandMetadata'),
      'QueuedCommandMetadata.commandId',
    );
    final attemptCount = _readInt(
      _required(object, 'attemptCount', 'QueuedCommandMetadata'),
      'QueuedCommandMetadata.attemptCount',
    );
    if (attemptCount < 0) {
      throw const FormatException(
        'QueuedCommandMetadata.attemptCount must not be negative.',
      );
    }
    _requireNonBlankFormat(commandId, 'QueuedCommandMetadata.commandId');
    final enqueuedAt = IsoTimestamp.fromJson(
      _required(object, 'enqueuedAt', 'QueuedCommandMetadata'),
    );
    _requireNonBlankFormat(
      enqueuedAt.value,
      'QueuedCommandMetadata.enqueuedAt',
    );
    return ApplicationChatQueuedCommandMetadata(
      commandId: commandId,
      commandKind: ApplicationChatQueuedCommandKind.fromJson(
        _required(object, 'commandKind', 'QueuedCommandMetadata'),
      ),
      enqueuedAt: enqueuedAt,
      attemptCount: attemptCount,
    );
  }

  final String commandId;
  final ApplicationChatQueuedCommandKind commandKind;
  final IsoTimestamp enqueuedAt;
  final int attemptCount;

  Map<String, Object?> toJson() => {
        'commandId': commandId,
        'commandKind': commandKind.wireValue,
        'enqueuedAt': enqueuedAt.toJson(),
        'attemptCount': attemptCount,
      };
}

/// The complete ordered queue bookkeeping record for one identity.
final class ApplicationChatQueuedCommandMetadataRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedCommandMetadataRecord({
    required super.identity,
    required List<ApplicationChatQueuedCommandMetadata> commands,
  })  : commands = List.unmodifiable(commands),
        super._() {
    final ids = <String>{};
    for (final command in this.commands) {
      if (!ids.add(command.commandId)) {
        throw ArgumentError.value(
          command.commandId,
          'commands',
          'command IDs must be unique',
        );
      }
    }
  }

  factory ApplicationChatQueuedCommandMetadataRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedCommandMetadataPayload');
    _expectFields(
      object,
      const {'commands'},
      'QueuedCommandMetadataPayload',
    );
    final commands = _readList(
      _required(object, 'commands', 'QueuedCommandMetadataPayload'),
      'QueuedCommandMetadataPayload.commands',
    ).map(ApplicationChatQueuedCommandMetadata.fromJson).toList();
    final ids = <String>{};
    for (final command in commands) {
      if (!ids.add(command.commandId)) {
        throw const FormatException(
          'Queued command metadata IDs must be unique.',
        );
      }
    }
    return ApplicationChatQueuedCommandMetadataRecord(
      identity: identity,
      commands: commands,
    );
  }

  final List<ApplicationChatQueuedCommandMetadata> commands;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedCommandMetadata;

  @override
  Map<String, Object?> payloadToJson() => {
        'commands': commands.map((command) => command.toJson()).toList(),
      };
}

/// A validated, retry-stable send intent safe for application persistence.
///
/// Only generated send-contract fields are retained. In particular, this type
/// has no token, authorization header, byte source, or upload-provider field.
final class ApplicationChatQueuedSendMessageIntent {
  ApplicationChatQueuedSendMessageIntent({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    this.contractVersion = applicationChatSendMessageContractVersion,
  }) {
    if (contractVersion != applicationChatSendMessageContractVersion) {
      throw ArgumentError.value(
        contractVersion,
        'contractVersion',
        'is not supported',
      );
    }
    if (enqueueOrder < 1) {
      throw ArgumentError.value(
        enqueueOrder,
        'enqueueOrder',
        'must be positive',
      );
    }
    _requireNonBlank(enqueuedAt.value, 'enqueuedAt');
    final json = toJson();
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedSendIntentBytes,
    )) {
      throw ArgumentError(
        'Queued send intent exceeds 262144 encoded bytes.',
      );
    }
  }

  factory ApplicationChatQueuedSendMessageIntent.fromJson(Object? json) {
    final object = _readObject(json, 'QueuedSendMessageIntent');
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        'conversationId',
        'content',
        if (object.containsKey('replyTo')) 'replyTo',
        'clientMessageId',
        'idempotencyKey',
      },
      'QueuedSendMessageIntent',
    );
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedSendMessageIntent'),
      'QueuedSendMessageIntent.contractVersion',
    );
    if (contractVersion != applicationChatSendMessageContractVersion) {
      throw FormatException(
        'Unsupported send-message contract version: $contractVersion.',
      );
    }
    final enqueueOrder = _readInt(
      _required(object, 'enqueueOrder', 'QueuedSendMessageIntent'),
      'QueuedSendMessageIntent.enqueueOrder',
    );
    if (enqueueOrder < 1) {
      throw const FormatException(
        'QueuedSendMessageIntent.enqueueOrder must be positive.',
      );
    }
    final enqueuedAt = IsoTimestamp.fromJson(
      _required(object, 'enqueuedAt', 'QueuedSendMessageIntent'),
    );
    _requireNonBlankFormat(
      enqueuedAt.value,
      'QueuedSendMessageIntent.enqueuedAt',
    );
    if (DateTime.tryParse(enqueuedAt.value) == null) {
      throw const FormatException(
        'QueuedSendMessageIntent.enqueuedAt must be an ISO-8601 timestamp.',
      );
    }
    final request = SendMessageRequest.fromJson(<String, Object?>{
      'operation': 'send',
      'conversationId':
          _required(object, 'conversationId', 'QueuedSendMessageIntent'),
      'content': _required(object, 'content', 'QueuedSendMessageIntent'),
      if (object.containsKey('replyTo')) 'replyTo': object['replyTo'],
      'clientMessageId':
          _required(object, 'clientMessageId', 'QueuedSendMessageIntent'),
      'idempotencyKey':
          _required(object, 'idempotencyKey', 'QueuedSendMessageIntent'),
    });
    final normalizedJson = <String, Object?>{
      'contractVersion': contractVersion,
      'enqueueOrder': enqueueOrder,
      'enqueuedAt': enqueuedAt.toJson(),
      'conversationId': request.conversationId.toJson(),
      'content': request.content.toJson(),
      if (request.replyTo case final replyTo?) 'replyTo': replyTo.toJson(),
      'clientMessageId': request.clientMessageId,
      'idempotencyKey': request.idempotencyKey,
    };
    if (_exceedsUtf8ByteLimit(
      jsonEncode(normalizedJson),
      maxApplicationChatQueuedSendIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued send intent exceeds 262144 encoded bytes.',
      );
    }
    try {
      return ApplicationChatQueuedSendMessageIntent(
        request: request,
        enqueueOrder: enqueueOrder,
        enqueuedAt: enqueuedAt,
        contractVersion: contractVersion,
      );
    } on ArgumentError catch (error) {
      throw FormatException(
          error.message?.toString() ?? 'Invalid send intent.');
    }
  }

  final int contractVersion;
  final SendMessageRequest request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        'conversationId': request.conversationId.toJson(),
        'content': request.content.toJson(),
        if (request.replyTo case final replyTo?) 'replyTo': replyTo.toJson(),
        'clientMessageId': request.clientMessageId,
        'idempotencyKey': request.idempotencyKey,
      };
}

/// The complete FIFO send-intent queue for one trusted identity.
final class ApplicationChatQueuedSendMessageIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedSendMessageIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedSendMessageIntent> intents,
  })  : intents = List.unmodifiable(intents),
        super._() {
    _validateIntents(this.intents, argumentError: true);
  }

  factory ApplicationChatQueuedSendMessageIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedSendMessageIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedSendMessageIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedSendMessageIntentsPayload'),
      'QueuedSendMessageIntentsPayload.intents',
    );
    if (encodedIntents.length > maxApplicationChatQueuedSendIntents) {
      throw const FormatException(
        'Stored send intents must contain at most 1000 entries.',
      );
    }
    final intents = encodedIntents
        .map(ApplicationChatQueuedSendMessageIntent.fromJson)
        .toList();
    _validateIntents(intents, argumentError: false);
    return ApplicationChatQueuedSendMessageIntentsRecord(
      identity: identity,
      intents: intents,
    );
  }

  final List<ApplicationChatQueuedSendMessageIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedSendMessageIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  static void _validateIntents(
    List<ApplicationChatQueuedSendMessageIntent> intents, {
    required bool argumentError,
  }) {
    if (intents.length > maxApplicationChatQueuedSendIntents) {
      if (argumentError) {
        throw ArgumentError.value(
          intents.length,
          'intents',
          'must contain at most 1000 entries',
        );
      }
      throw const FormatException(
        'Stored send intents must contain at most 1000 entries.',
      );
    }
    final clientMessageIds = <String>{};
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in intents) {
      final valid = intent.enqueueOrder > previousOrder &&
          clientMessageIds.add(intent.request.clientMessageId) &&
          idempotencyKeys.add(intent.request.idempotencyKey);
      if (!valid) {
        if (argumentError) {
          throw ArgumentError(
            'Send intents must have unique identities and increasing FIFO order.',
          );
        }
        throw const FormatException(
          'Stored send intents do not have unique identities and FIFO order.',
        );
      }
      previousOrder = intent.enqueueOrder;
    }
  }
}

/// A validated read-cursor mutation with retry-stable queue metadata.
///
/// [acknowledgedReadState] is the authoritative state observed before this
/// mutation was projected optimistically. It deliberately excludes request,
/// provider, transport, error, and message-content metadata.
final class ApplicationChatQueuedReadCursorIntent {
  ApplicationChatQueuedReadCursorIntent({
    required this.request,
    required this.acknowledgedReadState,
    required this.enqueueOrder,
    required this.enqueuedAt,
    this.contractVersion = applicationChatReadCursorContractVersion,
  }) {
    _validate(argumentError: true);
  }

  factory ApplicationChatQueuedReadCursorIntent.fromJson(Object? json) {
    _validateSecretFreeJson(json);
    final encoded = jsonEncode(json);
    if (_exceedsUtf8ByteLimit(
      encoded,
      maxApplicationChatQueuedReadCursorIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued read-cursor intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedReadCursorIntent');
    final operation = ReadCursorMutationOperation.fromJson(
      _required(object, 'operation', 'QueuedReadCursorIntent'),
      'QueuedReadCursorIntent.operation',
    );
    _expectFields(
      object,
      operation == ReadCursorMutationOperation.markRead
          ? const {
              'contractVersion',
              'enqueueOrder',
              'enqueuedAt',
              'operation',
              'conversationId',
              'throughSequence',
              'idempotencyKey',
              'acknowledgedReadState',
            }
          : const {
              'contractVersion',
              'enqueueOrder',
              'enqueuedAt',
              'operation',
              'conversationId',
              'fromSequence',
              'idempotencyKey',
              'acknowledgedReadState',
            },
      'QueuedReadCursorIntent',
    );
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedReadCursorIntent'),
      'QueuedReadCursorIntent.contractVersion',
    );
    if (contractVersion != applicationChatReadCursorContractVersion) {
      throw FormatException(
        'Unsupported read-cursor contract version: $contractVersion.',
      );
    }
    final enqueueOrder = _readInt(
      _required(object, 'enqueueOrder', 'QueuedReadCursorIntent'),
      'QueuedReadCursorIntent.enqueueOrder',
    );
    final inputJson = <String, Object?>{
      'operation': operation.toJson(),
      'conversationId':
          _required(object, 'conversationId', 'QueuedReadCursorIntent'),
      if (operation == ReadCursorMutationOperation.markRead)
        'throughSequence':
            _required(object, 'throughSequence', 'QueuedReadCursorIntent')
      else
        'fromSequence':
            _required(object, 'fromSequence', 'QueuedReadCursorIntent'),
      'idempotencyKey':
          _required(object, 'idempotencyKey', 'QueuedReadCursorIntent'),
    };
    final intent = ApplicationChatQueuedReadCursorIntent._validated(
      request: ReadCursorMutationInput.fromJson(inputJson),
      acknowledgedReadState: ConversationReadState.fromJson(
        _required(
          object,
          'acknowledgedReadState',
          'QueuedReadCursorIntent',
        ),
        path: 'QueuedReadCursorIntent.acknowledgedReadState',
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedReadCursorIntent'),
      ),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: false);
    return intent;
  }

  ApplicationChatQueuedReadCursorIntent._validated({
    required this.request,
    required this.acknowledgedReadState,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final ReadCursorMutationInput request;
  final ConversationReadState acknowledgedReadState;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
        'acknowledgedReadState': acknowledgedReadState.toJson(),
      };

  void _validate({required bool argumentError}) {
    void fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatReadCursorContractVersion) {
      fail('Read-cursor intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail('Read-cursor intent enqueueOrder must be a positive safe integer.');
    }
    if (enqueuedAt.value.length >
            _maxApplicationChatIntentTimestampCharacters ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(enqueuedAt.value) ||
        DateTime.tryParse(enqueuedAt.value) == null) {
      fail('Read-cursor intent enqueuedAt must be a bounded ISO timestamp.');
    }
    if (!_isBoundedNonBlankUtf8(
      request.conversationId.value,
      _maxApplicationChatIntentIdentifierUtf8Bytes,
    )) {
      fail('Read-cursor intent conversationId must be nonblank and bounded.');
    }
    if (!_isBoundedNonBlankUtf8(
      request.idempotencyKey,
      maxReadCursorIdempotencyKeyUtf8Bytes,
    )) {
      fail('Read-cursor intent idempotencyKey must be nonblank and bounded.');
    }
    if (!_isBoundedNonBlankUtf8(
          acknowledgedReadState.conversationId.value,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          acknowledgedReadState.userId.value,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        )) {
      fail('Read-cursor acknowledged state identifiers must be bounded.');
    }
    if (request.conversationId != acknowledgedReadState.conversationId) {
      fail('Read-cursor intent must match its acknowledged conversation.');
    }
    switch (request) {
      case MarkReadInput(:final throughSequence):
        if (throughSequence.value <
            acknowledgedReadState.lastReadSequence.value) {
          fail('Queued mark-read cursor cannot move backward.');
        }
      case MarkUnreadInput(:final fromSequence):
        if (fromSequence.value > acknowledgedReadState.lastReadSequence.value) {
          fail('Queued mark-unread cursor must be in the already-read range.');
        }
    }
    final json = toJson();
    _validateSecretFreeJson(json);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedReadCursorIntentBytes,
    )) {
      fail('Queued read-cursor intent exceeds 16384 encoded bytes.');
    }
  }
}

/// The normalized read-cursor intent queue for one trusted identity.
final class ApplicationChatQueuedReadCursorIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedReadCursorIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedReadCursorIntent> intents,
  })  : intents = List.unmodifiable(
          _prepare(identity, intents, argumentError: true),
        ),
        super._();

  ApplicationChatQueuedReadCursorIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedReadCursorIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedReadCursorIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedReadCursorIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedReadCursorIntentsPayload'),
      'QueuedReadCursorIntentsPayload.intents',
    );
    if (encodedIntents.length > maxApplicationChatQueuedReadCursorIntents) {
      throw const FormatException(
        'Stored read-cursor intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedReadCursorIntent.fromJson)
        .toList(growable: false);
    return ApplicationChatQueuedReadCursorIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(
        _prepare(identity, parsed, argumentError: false),
      ),
    );
  }

  final List<ApplicationChatQueuedReadCursorIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedReadCursorIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  static List<ApplicationChatQueuedReadCursorIntent> _prepare(
    ApplicationChatStorageIdentity identity,
    List<ApplicationChatQueuedReadCursorIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedReadCursorIntents) {
      fail('Read-cursor intents must contain at most 1000 entries.');
    }
    final idempotencyKeys = <String>{};
    final enqueueOrders = <int>{};
    var previousOrder = 0;
    for (final intent in intents) {
      intent._validate(argumentError: argumentError);
      if (intent.acknowledgedReadState.userId != identity.userId) {
        fail(
            'Read-cursor intent acknowledged user must match storage identity.');
      }
      if (intent.enqueueOrder <= previousOrder ||
          !enqueueOrders.add(intent.enqueueOrder)) {
        fail('Read-cursor intents must have strictly increasing queue order.');
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail('Read-cursor intent idempotency keys must be unique.');
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedReadCursorIntent>[];
    for (final intent in intents) {
      final previous = normalized.isEmpty ? null : normalized.last;
      if (previous?.request case final MarkReadInput previousRequest
          when intent.request is MarkReadInput &&
              previousRequest.conversationId == intent.request.conversationId) {
        final nextRequest = intent.request as MarkReadInput;
        final highest = previousRequest.throughSequence.value >=
                nextRequest.throughSequence.value
            ? previousRequest.throughSequence
            : nextRequest.throughSequence;
        normalized[normalized.length - 1] =
            ApplicationChatQueuedReadCursorIntent(
          request: MarkReadInput(
            conversationId: previousRequest.conversationId,
            throughSequence: highest,
            idempotencyKey: previousRequest.idempotencyKey,
          ),
          acknowledgedReadState: previous!.acknowledgedReadState,
          enqueueOrder: previous.enqueueOrder,
          enqueuedAt: previous.enqueuedAt,
          contractVersion: previous.contractVersion,
        );
      } else {
        normalized.add(intent);
      }
    }
    return normalized;
  }
}

/// A retry-stable command from the closed set of message mutations.
///
/// [request] is always one of [ForwardMessageRequest], [EditMessageRequest],
/// [SoftDeleteMessageRequest], [AddReactionInput], or [RemoveReactionInput].
/// Construction reparses the generated request so the retained value is
/// validated, detached, and contains no transport or server-owned material.
final class ApplicationChatQueuedMessageMutationIntent {
  factory ApplicationChatQueuedMessageMutationIntent({
    required Object request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatMessageMutationContractVersion,
  }) {
    final intent = ApplicationChatQueuedMessageMutationIntent._validated(
      request: _parseMessageMutationRequest(
        request,
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedMessageMutationIntent.fromJson(Object? json) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedMessageMutationIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued message-mutation intent exceeds 262144 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedMessageMutationIntent');
    final operation = _readString(
      _required(object, 'operation', 'QueuedMessageMutationIntent'),
      'QueuedMessageMutationIntent.operation',
    );
    final requestFields = _messageMutationRequestFields(
      operation,
      argumentError: false,
    );
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedMessageMutationIntent',
    );
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedMessageMutationIntent'),
      'QueuedMessageMutationIntent.contractVersion',
    );
    if (contractVersion != applicationChatMessageMutationContractVersion) {
      throw FormatException(
        'Unsupported message-mutation contract version: $contractVersion.',
      );
    }
    final requestJson = <String, Object?>{
      for (final field in requestFields) field: object[field],
    };
    final intent = ApplicationChatQueuedMessageMutationIntent._validated(
      request: _parseMessageMutationRequest(
        requestJson,
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedMessageMutationIntent'),
        'QueuedMessageMutationIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedMessageMutationIntent'),
      ),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: false);
    return intent;
  }

  ApplicationChatQueuedMessageMutationIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final Object request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  String get operation => _messageMutationOperation(request);
  String get idempotencyKey => _messageMutationIdempotencyKey(request);

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ..._messageMutationRequestJson(request),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatMessageMutationContractVersion) {
      fail('Message-mutation intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Message-mutation intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (enqueuedAt.value.length >
            _maxApplicationChatIntentTimestampCharacters ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(enqueuedAt.value) ||
        DateTime.tryParse(enqueuedAt.value) == null) {
      fail(
          'Message-mutation intent enqueuedAt must be a bounded ISO timestamp.');
    }
    _validateMessageMutationRequestBounds(request, fail);
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedMessageMutationIntentBytes,
    )) {
      fail('Queued message-mutation intent exceeds 262144 encoded bytes.');
    }
  }
}

/// The normalized FIFO message-mutation queue for one trusted identity.
final class ApplicationChatQueuedMessageMutationIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedMessageMutationIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedMessageMutationIntent> intents,
  })  : intents = List.unmodifiable(
          _prepare(intents, argumentError: true),
        ),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedMessageMutationIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedMessageMutationIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedMessageMutationIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedMessageMutationIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedMessageMutationIntentsPayload'),
      'QueuedMessageMutationIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedMessageMutationIntents) {
      throw const FormatException(
        'Stored message-mutation intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedMessageMutationIntent.fromJson)
        .toList(growable: false);
    final record = ApplicationChatQueuedMessageMutationIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(
        _prepare(parsed, argumentError: false),
      ),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedMessageMutationIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedMessageMutationIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedMessageMutationIntent> _prepare(
    List<ApplicationChatQueuedMessageMutationIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedMessageMutationIntents) {
      fail('Message-mutation intents must contain at most 1000 entries.');
    }
    final detached = intents
        .map(
          (intent) => ApplicationChatQueuedMessageMutationIntent._validated(
            request: _parseMessageMutationRequest(
              intent.request,
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final clientCorrelationIds = <String>{};
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Message-mutation intents must have strictly increasing FIFO order.',
        );
      }
      if (intent.request case final ForwardMessageRequest request) {
        if (!clientCorrelationIds.add(request.clientCorrelationId)) {
          fail(
            'Forward-message intent clientCorrelationId values must be unique.',
          );
        }
      }
      if (!idempotencyKeys.add(intent.idempotencyKey)) {
        fail('Message-mutation intent idempotencyKey values must be unique.');
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedMessageMutationIntent>[];
    final laneIndexes = <String, int>{};
    String? previousInputLane;
    for (final intent in detached) {
      final lane = _messageMutationConflictLane(intent.request);
      if (_isReactionMutation(intent.request)) {
        final previousIndex = normalized.length - 1;
        final previous = previousIndex < 0 ? null : normalized[previousIndex];
        if (previousInputLane == lane &&
            previous != null &&
            _isReactionMutation(previous.request) &&
            _messageMutationConflictLane(previous.request) == lane) {
          normalized[previousIndex] =
              ApplicationChatQueuedMessageMutationIntent._validated(
            request: intent.request,
            enqueueOrder: previous.enqueueOrder,
            enqueuedAt: previous.enqueuedAt,
            contractVersion: previous.contractVersion,
          );
        } else {
          normalized.add(intent);
        }
        previousInputLane = lane;
        continue;
      }

      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
      } else {
        final existing = normalized[existingIndex];
        normalized[existingIndex] =
            ApplicationChatQueuedMessageMutationIntent._validated(
          request: intent.request,
          enqueueOrder: existing.enqueueOrder,
          enqueuedAt: existing.enqueuedAt,
          contractVersion: existing.contractVersion,
        );
      }
      previousInputLane = lane;
    }
    return normalized;
  }
}

/// A validated, retry-stable conversation-membership command.
///
/// Construction reparses the generated request so storage never retains a
/// caller-owned value or any transport/server-derived fields.
final class ApplicationChatQueuedConversationMembershipIntent {
  factory ApplicationChatQueuedConversationMembershipIntent({
    required ConversationMembershipMutationInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatConversationMembershipContractVersion,
  }) {
    final intent = ApplicationChatQueuedConversationMembershipIntent._validated(
      request: _parseConversationMembershipRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedConversationMembershipIntent.fromJson(
    Object? json,
  ) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationMembershipIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued conversation-membership intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(
      json,
      'QueuedConversationMembershipIntent',
    );
    final intentValue = _required(
      object,
      'intent',
      'QueuedConversationMembershipIntent',
    );
    final requestFields = _conversationMembershipRequestFields(
      intentValue,
      argumentError: false,
    );
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedConversationMembershipIntent',
    );
    final contractVersion = _readInt(
      _required(
        object,
        'contractVersion',
        'QueuedConversationMembershipIntent',
      ),
      'QueuedConversationMembershipIntent.contractVersion',
    );
    if (contractVersion !=
        applicationChatConversationMembershipContractVersion) {
      throw FormatException(
        'Unsupported conversation-membership contract version: '
        '$contractVersion.',
      );
    }
    final parsed = ApplicationChatQueuedConversationMembershipIntent._validated(
      request: _parseConversationMembershipRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(
          object,
          'enqueueOrder',
          'QueuedConversationMembershipIntent',
        ),
        'QueuedConversationMembershipIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(
          object,
          'enqueuedAt',
          'QueuedConversationMembershipIntent',
        ),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedConversationMembershipIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final ConversationMembershipMutationInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion !=
        applicationChatConversationMembershipContractVersion) {
      fail('Conversation-membership intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Conversation-membership intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (enqueuedAt.value.length >
            _maxApplicationChatIntentTimestampCharacters ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(enqueuedAt.value) ||
        DateTime.tryParse(enqueuedAt.value) == null) {
      fail(
        'Conversation-membership intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
      request.conversationId.value,
      _maxApplicationChatIntentIdentifierUtf8Bytes,
    )) {
      fail(
        'Conversation-membership intent conversationId must be nonblank and bounded.',
      );
    }
    final target = request.targetUserId;
    if (target != null &&
        !_isBoundedNonBlankUtf8(
          target.value,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        )) {
      fail(
        'Conversation-membership intent targetUserId must be nonblank and bounded.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
      request.idempotencyKey,
      maxConversationMembershipIdempotencyKeyUtf8Bytes,
    )) {
      fail(
        'Conversation-membership intent idempotencyKey must be nonblank and bounded.',
      );
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationMembershipIntentBytes,
    )) {
      fail(
          'Queued conversation-membership intent exceeds 16384 encoded bytes.');
    }
  }
}

/// The normalized FIFO membership-intent queue for one trusted identity.
final class ApplicationChatQueuedConversationMembershipIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedConversationMembershipIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedConversationMembershipIntent> intents,
  })  : intents = List.unmodifiable(
          _prepare(intents, argumentError: true),
        ),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedConversationMembershipIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedConversationMembershipIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(
      json,
      'QueuedConversationMembershipIntentsPayload',
    );
    _expectFields(
      object,
      const {'intents'},
      'QueuedConversationMembershipIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(
        object,
        'intents',
        'QueuedConversationMembershipIntentsPayload',
      ),
      'QueuedConversationMembershipIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedConversationMembershipIntents) {
      throw const FormatException(
        'Stored conversation-membership intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedConversationMembershipIntent.fromJson)
        .toList(growable: false);
    final record =
        ApplicationChatQueuedConversationMembershipIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(
        _prepare(parsed, argumentError: false),
      ),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedConversationMembershipIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedConversationMembershipIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedConversationMembershipIntent> _prepare(
    List<ApplicationChatQueuedConversationMembershipIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length >
        maxApplicationChatQueuedConversationMembershipIntents) {
      fail(
        'Conversation-membership intents must contain at most 1000 entries.',
      );
    }
    final detached = intents
        .map(
          (intent) =>
              ApplicationChatQueuedConversationMembershipIntent._validated(
            request: _parseConversationMembershipRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Conversation-membership intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail(
          'Conversation-membership intent idempotencyKey values must be unique.',
        );
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedConversationMembershipIntent>[];
    for (final intent in detached) {
      final previous = normalized.isEmpty ? null : normalized.last;
      if (previous != null &&
          _sameConversationMembershipSemantics(
            previous.request,
            intent.request,
          )) {
        continue;
      }
      normalized.add(intent);
    }
    return normalized;
  }
}

ConversationMembershipMutationInput _parseConversationMembershipRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    return ConversationMembershipMutationInput.fromJson(value);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Conversation-membership request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Conversation-membership request is invalid: ${error.message}',
    );
  }
}

Set<String> _conversationMembershipRequestFields(
  Object? intent, {
  required bool argumentError,
}) {
  Never fail() {
    const message = 'Conversation-membership request intent is unsupported.';
    if (argumentError) throw ArgumentError(message);
    throw const FormatException(message);
  }

  return switch (intent) {
    'join' || 'leave' => const {
        'operation',
        'intent',
        'conversationId',
        'expectedMemberListRevision',
        'idempotencyKey',
      },
    'remove_member' => const {
        'operation',
        'intent',
        'conversationId',
        'targetUserId',
        'expectedMemberListRevision',
        'idempotencyKey',
      },
    'add_member' || 'change_member_role' => const {
        'operation',
        'intent',
        'conversationId',
        'targetUserId',
        'requestedRole',
        'expectedMemberListRevision',
        'idempotencyKey',
      },
    _ => fail(),
  };
}

bool _sameConversationMembershipSemantics(
  ConversationMembershipMutationInput left,
  ConversationMembershipMutationInput right,
) =>
    left.intent == right.intent &&
    left.conversationId == right.conversationId &&
    left.targetUserId == right.targetUserId &&
    left.requestedRole == right.requestedRole &&
    left.expectedMemberListRevision == right.expectedMemberListRevision;

/// A validated, retry-stable conversation-creation request.
///
/// Construction reparses the generated request and canonicalizes participant
/// order so logical equality is stable across callers and process restarts.
final class ApplicationChatQueuedConversationCreationIntent {
  factory ApplicationChatQueuedConversationCreationIntent({
    required ConversationCreationInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatConversationCreationContractVersion,
  }) {
    final intent = ApplicationChatQueuedConversationCreationIntent._validated(
      request: _canonicalConversationCreationRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedConversationCreationIntent.fromJson(
    Object? json,
  ) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationCreationIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued conversation-creation intent exceeds 65536 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedConversationCreationIntent');
    final requestFields = _conversationCreationRequestFields(
      object,
      argumentError: false,
    );
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedConversationCreationIntent',
    );
    final contractVersion = _readInt(
      _required(
        object,
        'contractVersion',
        'QueuedConversationCreationIntent',
      ),
      'QueuedConversationCreationIntent.contractVersion',
    );
    if (contractVersion != applicationChatConversationCreationContractVersion) {
      throw FormatException(
        'Unsupported conversation-creation contract version: '
        '$contractVersion.',
      );
    }
    final intent = ApplicationChatQueuedConversationCreationIntent._validated(
      request: _canonicalConversationCreationRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(
          object,
          'enqueueOrder',
          'QueuedConversationCreationIntent',
        ),
        'QueuedConversationCreationIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(
          object,
          'enqueuedAt',
          'QueuedConversationCreationIntent',
        ),
      ),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: false);
    return intent;
  }

  ApplicationChatQueuedConversationCreationIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final ConversationCreationInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatConversationCreationContractVersion) {
      fail('Conversation-creation intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Conversation-creation intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail(
        'Conversation-creation intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.clientRequestId,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        )) {
      fail(
        'Conversation-creation correlations must be nonblank and bounded.',
      );
    }
    switch (request) {
      case final CreateChannelConversationInput channel:
        if (!_isBoundedNonBlankUtf8(
          channel.name,
          _maxApplicationChatConversationCreationAuthoredUtf8Bytes,
        )) {
          fail(
              'Conversation-creation channel name must be nonblank and bounded.');
        }
        final entity = channel.entity;
        if (entity != null &&
            (!_isBoundedNonBlankUtf8(
                  entity.type,
                  _maxApplicationChatIntentIdentifierUtf8Bytes,
                ) ||
                !_isBoundedNonBlankUtf8(
                  entity.id,
                  _maxApplicationChatIntentIdentifierUtf8Bytes,
                ))) {
          fail(
            'Conversation-creation entity fields must be nonblank and bounded.',
          );
        }
      case final ParticipantConversationCreationInput participant:
        if (participant.intendedMemberUserIds.length >
            maxApplicationChatConversationCreationMembers) {
          fail(
            'Conversation-creation intents must contain at most 100 intended members.',
          );
        }
        for (final member in participant.intendedMemberUserIds) {
          if (!_isBoundedNonBlankUtf8(
            member.value,
            _maxApplicationChatIntentIdentifierUtf8Bytes,
          )) {
            fail(
              'Conversation-creation intended member IDs must be nonblank and bounded.',
            );
          }
        }
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationCreationIntentBytes,
    )) {
      fail('Queued conversation-creation intent exceeds 65536 encoded bytes.');
    }
  }
}

/// The normalized FIFO creation-intent queue for one trusted identity.
final class ApplicationChatQueuedConversationCreationIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedConversationCreationIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedConversationCreationIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedConversationCreationIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedConversationCreationIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(
      json,
      'QueuedConversationCreationIntentsPayload',
    );
    _expectFields(
      object,
      const {'intents'},
      'QueuedConversationCreationIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(
        object,
        'intents',
        'QueuedConversationCreationIntentsPayload',
      ),
      'QueuedConversationCreationIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedConversationCreationIntents) {
      throw const FormatException(
        'Stored conversation-creation intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedConversationCreationIntent.fromJson)
        .toList(growable: false);
    final record =
        ApplicationChatQueuedConversationCreationIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedConversationCreationIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedConversationCreationIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedConversationCreationIntent> _prepare(
    List<ApplicationChatQueuedConversationCreationIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedConversationCreationIntents) {
      fail(
        'Conversation-creation intents must contain at most 1000 entries.',
      );
    }
    final detached = intents
        .map(
          (intent) =>
              ApplicationChatQueuedConversationCreationIntent._validated(
            request: _canonicalConversationCreationRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    final clientRequestIds = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Conversation-creation intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail(
          'Conversation-creation intent idempotencyKey values must be unique.',
        );
      }
      if (!clientRequestIds.add(intent.request.clientRequestId)) {
        fail(
          'Conversation-creation intent clientRequestId values must be unique.',
        );
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedConversationCreationIntent>[];
    for (final intent in detached) {
      if (normalized.any(
        (retained) => _sameConversationCreationSemantics(
          retained.request,
          intent.request,
        ),
      )) {
        continue;
      }
      normalized.add(intent);
    }
    return normalized;
  }
}

ConversationCreationInput _canonicalConversationCreationRequest(
  Object? value, {
  required bool argumentError,
}) {
  final parsed = _parseConversationCreationRequest(
    value,
    argumentError: argumentError,
  );
  if (parsed is! ParticipantConversationCreationInput) return parsed;
  final json = parsed.toJson();
  final members = parsed.intendedMemberUserIds
      .map((member) => member.value)
      .toList(growable: false)
    ..sort();
  json['intendedMemberUserIds'] = members;
  return _parseConversationCreationRequest(
    json,
    argumentError: argumentError,
  );
}

ConversationCreationInput _parseConversationCreationRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    return ConversationCreationInput.fromJson(value);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Conversation-creation request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Conversation-creation request is invalid: ${error.message}',
    );
  }
}

Set<String> _conversationCreationRequestFields(
  Map<String, Object?> object, {
  required bool argumentError,
}) {
  Never fail() {
    const message = 'Conversation-creation request type is unsupported.';
    if (argumentError) throw ArgumentError(message);
    throw const FormatException(message);
  }

  return switch (object['type']) {
    'channel' => {
        'operation',
        'type',
        'name',
        'visibility',
        if (object.containsKey('entity')) 'entity',
        'idempotencyKey',
        'clientRequestId',
      },
    'direct' || 'group_direct' => const {
        'operation',
        'type',
        'visibility',
        'intendedMemberUserIds',
        'idempotencyKey',
        'clientRequestId',
      },
    _ => fail(),
  };
}

bool _sameConversationCreationSemantics(
  ConversationCreationInput left,
  ConversationCreationInput right,
) {
  if (left.type != right.type) return false;
  return switch ((left, right)) {
    (
      final CreateChannelConversationInput leftChannel,
      final CreateChannelConversationInput rightChannel,
    ) =>
      leftChannel.name == rightChannel.name &&
          leftChannel.visibility == rightChannel.visibility &&
          leftChannel.entity?.type == rightChannel.entity?.type &&
          leftChannel.entity?.id == rightChannel.entity?.id,
    (
      final ParticipantConversationCreationInput leftParticipants,
      final ParticipantConversationCreationInput rightParticipants,
    ) =>
      _sameOrderedUserIds(
        leftParticipants.intendedMemberUserIds,
        rightParticipants.intendedMemberUserIds,
      ),
    _ => false,
  };
}

bool _sameOrderedUserIds(List<UserId> left, List<UserId> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => entry.$2 == right[entry.$1]);

bool _isBoundedIsoTimestamp(String value) {
  if (value.length > _maxApplicationChatIntentTimestampCharacters) {
    return false;
  }
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (match == null || DateTime.tryParse(value) == null) return false;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final offsetHour = int.tryParse(match[7] ?? '0')!;
  final offsetMinute = int.tryParse(match[8] ?? '0')!;
  if (month < 1 ||
      month > 12 ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      offsetHour > 23 ||
      offsetMinute > 59) {
    return false;
  }
  final firstOfNextMonth =
      month == 12 ? DateTime.utc(year + 1) : DateTime.utc(year, month + 1);
  final lastDay = firstOfNextMonth.subtract(const Duration(days: 1)).day;
  return day >= 1 && day <= lastDay;
}

Object _parseMessageMutationRequest(
  Object value, {
  required bool argumentError,
}) {
  Never fail(String message) {
    if (argumentError) throw ArgumentError(message);
    throw FormatException(message);
  }

  final Object json = switch (value) {
    ForwardMessageRequest() => value.toJson(),
    EditMessageRequest() => value.toJson(),
    SoftDeleteMessageRequest() => value.toJson(),
    AddReactionInput() => value.toJson(),
    RemoveReactionInput() => value.toJson(),
    Map<Object?, Object?>() => value,
    _ => fail('Message-mutation request has an unsupported command type.'),
  };
  try {
    final object = _readObject(json, 'MessageMutationRequest');
    return switch (object['operation']) {
      'forward_message.v1' => ForwardMessageRequest.fromJson(object),
      'edit' => EditMessageRequest.fromJson(object),
      'soft_delete' => SoftDeleteMessageRequest.fromJson(object),
      'add_reaction' ||
      'remove_reaction' =>
        ReactionMutationInput.fromJson(object),
      final operation => fail(
          'Message-mutation request operation is unsupported: $operation.',
        ),
    };
  } on FormatException catch (error) {
    fail('Message-mutation request is invalid: ${error.message}');
  }
}

Set<String> _messageMutationRequestFields(
  String operation, {
  required bool argumentError,
}) {
  Never fail() {
    const message = 'Message-mutation request operation is unsupported.';
    if (argumentError) throw ArgumentError(message);
    throw const FormatException(message);
  }

  return switch (operation) {
    'forward_message.v1' => const {
        'operation',
        'sourceMessageId',
        'destinationConversationId',
        'clientCorrelationId',
        'idempotencyKey',
      },
    'edit' => const {
        'operation',
        'messageId',
        'expectedRevision',
        'content',
        'idempotencyKey',
      },
    'soft_delete' => const {
        'operation',
        'messageId',
        'expectedRevision',
        'idempotencyKey',
      },
    'add_reaction' || 'remove_reaction' => const {
        'operation',
        'messageId',
        'reactionKey',
        'idempotencyKey',
      },
    _ => fail(),
  };
}

Map<String, Object?> _messageMutationRequestJson(Object request) =>
    switch (request) {
      ForwardMessageRequest() => request.toJson(),
      EditMessageRequest() => request.toJson(),
      SoftDeleteMessageRequest() => request.toJson(),
      AddReactionInput() => request.toJson(),
      RemoveReactionInput() => request.toJson(),
      _ => throw StateError('Unsupported validated message-mutation request.'),
    };

String _messageMutationOperation(Object request) => switch (request) {
      ForwardMessageRequest(:final operation) => operation,
      EditMessageRequest(:final operation) => operation,
      SoftDeleteMessageRequest(:final operation) => operation,
      AddReactionInput() => request.operation.toJson(),
      RemoveReactionInput() => request.operation.toJson(),
      _ => throw StateError('Unsupported validated message-mutation request.'),
    };

String _messageMutationIdempotencyKey(Object request) => switch (request) {
      ForwardMessageRequest(:final idempotencyKey) => idempotencyKey,
      EditMessageRequest(:final idempotencyKey) => idempotencyKey,
      SoftDeleteMessageRequest(:final idempotencyKey) => idempotencyKey,
      AddReactionInput(:final idempotencyKey) => idempotencyKey,
      RemoveReactionInput(:final idempotencyKey) => idempotencyKey,
      _ => throw StateError('Unsupported validated message-mutation request.'),
    };

void _validateMessageMutationRequestBounds(
  Object request,
  Never Function(String message) fail,
) {
  bool bounded(String value) => _isBoundedNonBlankUtf8(
        value,
        _maxApplicationChatIntentIdentifierUtf8Bytes,
      );

  if (!bounded(_messageMutationIdempotencyKey(request))) {
    fail(
        'Message-mutation intent idempotencyKey must be nonblank and bounded.');
  }
  switch (request) {
    case ForwardMessageRequest(
        :final sourceMessageId,
        :final destinationConversationId,
        :final clientCorrelationId,
      ):
      if (!bounded(sourceMessageId.value) ||
          !bounded(destinationConversationId.value) ||
          !bounded(clientCorrelationId)) {
        fail(
            'Forward-message intent identifiers must be nonblank and bounded.');
      }
    case EditMessageRequest(:final messageId, :final content):
      if (!bounded(messageId.value)) {
        fail('Edit-message intent messageId must be nonblank and bounded.');
      }
      if (content.text.length > _maxApplicationChatMessageTextCharacters) {
        fail('Edit-message intent content text exceeds 100000 characters.');
      }
      for (final collection in [
        content.mentions,
        content.attachments,
        content.blocks,
      ]) {
        if (collection != null &&
            collection.length > _maxApplicationChatMessageCollectionEntries) {
          fail('Edit-message intent content collection exceeds 1000 entries.');
        }
      }
    case SoftDeleteMessageRequest(:final messageId):
      if (!bounded(messageId.value)) {
        fail('Soft-delete intent messageId must be nonblank and bounded.');
      }
    case AddReactionInput(:final messageId) ||
          RemoveReactionInput(:final messageId):
      if (!bounded(messageId.value)) {
        fail('Reaction intent messageId must be nonblank and bounded.');
      }
    default:
      fail('Message-mutation request has an unsupported command type.');
  }
}

bool _isReactionMutation(Object request) =>
    request is AddReactionInput || request is RemoveReactionInput;

String _messageMutationConflictLane(Object request) => jsonEncode(
      switch (request) {
        ForwardMessageRequest(
          :final sourceMessageId,
          :final destinationConversationId,
        ) =>
          [
            'forward',
            sourceMessageId.value,
            destinationConversationId.value,
          ],
        EditMessageRequest(:final messageId) ||
        SoftDeleteMessageRequest(:final messageId) =>
          ['message', messageId.value],
        AddReactionInput(:final messageId, :final reactionKey) ||
        RemoveReactionInput(:final messageId, :final reactionKey) =>
          ['reaction', messageId.value, reactionKey],
        _ => throw StateError(
            'Unsupported validated message-mutation request.',
          ),
      },
    );

/// A validated, retry-stable conversation-preference request.
///
/// Construction reparses the complete generated request so persisted intents
/// are detached from caller-owned values and cannot contain trusted identity,
/// transport, provider, or server-derived fields.
final class ApplicationChatQueuedConversationPreferenceIntent {
  factory ApplicationChatQueuedConversationPreferenceIntent({
    required UpdateConversationPreferenceInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatConversationPreferenceContractVersion,
  }) {
    final intent = ApplicationChatQueuedConversationPreferenceIntent._validated(
      request: _parseConversationPreferenceRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedConversationPreferenceIntent.fromJson(
    Object? json,
  ) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationPreferenceIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued conversation-preference intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(
      json,
      'QueuedConversationPreferenceIntent',
    );
    const requestFields = {
      'operation',
      'conversationId',
      'expectedPreferenceRevision',
      'idempotencyKey',
      'notificationPreference',
      'isStarred',
      'mute',
    };
    _expectFields(
      object,
      const {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedConversationPreferenceIntent',
    );
    final contractVersion = _readInt(
      _required(
        object,
        'contractVersion',
        'QueuedConversationPreferenceIntent',
      ),
      'QueuedConversationPreferenceIntent.contractVersion',
    );
    if (contractVersion !=
        applicationChatConversationPreferenceContractVersion) {
      throw FormatException(
        'Unsupported conversation-preference contract version: '
        '$contractVersion.',
      );
    }
    final intent = ApplicationChatQueuedConversationPreferenceIntent._validated(
      request: _parseConversationPreferenceRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(
          object,
          'enqueueOrder',
          'QueuedConversationPreferenceIntent',
        ),
        'QueuedConversationPreferenceIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(
          object,
          'enqueuedAt',
          'QueuedConversationPreferenceIntent',
        ),
      ),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: false);
    return intent;
  }

  ApplicationChatQueuedConversationPreferenceIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final UpdateConversationPreferenceInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion !=
        applicationChatConversationPreferenceContractVersion) {
      fail('Conversation-preference intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Conversation-preference intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail(
        'Conversation-preference intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
          request.conversationId.value,
          maxConversationPreferenceIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          maxConversationPreferenceIdempotencyKeyUtf8Bytes,
        )) {
      fail(
        'Conversation-preference intent correlations must be nonblank and bounded.',
      );
    }
    if (request.expectedPreferenceRevision < 0 ||
        request.expectedPreferenceRevision >= _maxSafeJsonInteger) {
      fail(
        'Conversation-preference expected revision must be a nonnegative safe integer that can advance by one.',
      );
    }
    final mutedUntil = request.mute.mutedUntil;
    if (mutedUntil != null && !_isBoundedIsoTimestamp(mutedUntil.value)) {
      fail(
        'Conversation-preference mutedUntil must be a bounded ISO timestamp.',
      );
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationPreferenceIntentBytes,
    )) {
      fail(
        'Queued conversation-preference intent exceeds 16384 encoded bytes.',
      );
    }
  }
}

/// The latest desired preference request for each conversation, in FIFO order.
final class ApplicationChatQueuedConversationPreferenceIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedConversationPreferenceIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedConversationPreferenceIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedConversationPreferenceIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedConversationPreferenceIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(
      json,
      'QueuedConversationPreferenceIntentsPayload',
    );
    _expectFields(
      object,
      const {'intents'},
      'QueuedConversationPreferenceIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(
        object,
        'intents',
        'QueuedConversationPreferenceIntentsPayload',
      ),
      'QueuedConversationPreferenceIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedConversationPreferenceIntents) {
      throw const FormatException(
        'Stored conversation-preference intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedConversationPreferenceIntent.fromJson)
        .toList(growable: false);
    final record =
        ApplicationChatQueuedConversationPreferenceIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedConversationPreferenceIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedConversationPreferenceIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedConversationPreferenceIntent> _prepare(
    List<ApplicationChatQueuedConversationPreferenceIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length >
        maxApplicationChatQueuedConversationPreferenceIntents) {
      fail(
        'Conversation-preference intents must contain at most 1000 entries.',
      );
    }
    final detached = intents
        .map(
          (intent) =>
              ApplicationChatQueuedConversationPreferenceIntent._validated(
            request: _parseConversationPreferenceRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Conversation-preference intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail(
          'Conversation-preference intent idempotencyKey values must be unique.',
        );
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedConversationPreferenceIntent>[];
    final laneIndexes = <ConversationId, int>{};
    for (final intent in detached) {
      final lane = intent.request.conversationId;
      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
        continue;
      }
      final existing = normalized[existingIndex];
      normalized[existingIndex] =
          ApplicationChatQueuedConversationPreferenceIntent._validated(
        request: intent.request,
        enqueueOrder: existing.enqueueOrder,
        enqueuedAt: existing.enqueuedAt,
        contractVersion: existing.contractVersion,
      );
    }
    return normalized;
  }
}

UpdateConversationPreferenceInput _parseConversationPreferenceRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    final json =
        value is UpdateConversationPreferenceInput ? value.toJson() : value;
    return UpdateConversationPreferenceInput.fromJson(json);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Conversation-preference request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Conversation-preference request is invalid: ${error.message}',
    );
  }
}

/// A validated explicit thread follow or unfollow with retry-stable metadata.
///
/// Construction reparses the complete generated request so persisted intents
/// are detached from caller-owned values. Trusted identity remains exclusively
/// in the containing record envelope.
final class ApplicationChatQueuedThreadFollowIntent {
  factory ApplicationChatQueuedThreadFollowIntent({
    required SetThreadFollowInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatThreadFollowContractVersion,
  }) {
    final intent = ApplicationChatQueuedThreadFollowIntent._validated(
      request: _parseThreadFollowRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedThreadFollowIntent.fromJson(Object? json) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedThreadFollowIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued thread-follow intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedThreadFollowIntent');
    const requestFields = {
      'operation',
      'intent',
      'target',
      'expectedFollowRevision',
      'idempotencyKey',
    };
    _expectFields(
      object,
      const {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedThreadFollowIntent',
    );
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedThreadFollowIntent'),
      'QueuedThreadFollowIntent.contractVersion',
    );
    if (contractVersion != applicationChatThreadFollowContractVersion) {
      throw FormatException(
        'Unsupported thread-follow contract version: $contractVersion.',
      );
    }
    final parsed = ApplicationChatQueuedThreadFollowIntent._validated(
      request: _parseThreadFollowRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedThreadFollowIntent'),
        'QueuedThreadFollowIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedThreadFollowIntent'),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedThreadFollowIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final SetThreadFollowInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatThreadFollowContractVersion) {
      fail('Thread-follow intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
          'Thread-follow intent enqueueOrder must be a positive safe integer.');
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail('Thread-follow intent enqueuedAt must be a bounded ISO timestamp.');
    }
    if (!_isBoundedNonBlankUtf8(
          request.target.id.value,
          maxThreadFollowIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          maxThreadFollowIdempotencyKeyUtf8Bytes,
        )) {
      fail('Thread-follow intent correlations must be nonblank and bounded.');
    }
    if (request.expectedFollowRevision < 0 ||
        request.expectedFollowRevision >= _maxSafeJsonInteger) {
      fail(
        'Thread-follow expected revision must be a nonnegative safe integer that can advance by one.',
      );
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedThreadFollowIntentBytes,
    )) {
      fail('Queued thread-follow intent exceeds 16384 encoded bytes.');
    }
  }
}

/// The latest desired follow state for each thread, in original FIFO order.
final class ApplicationChatQueuedThreadFollowIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedThreadFollowIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedThreadFollowIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedThreadFollowIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedThreadFollowIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedThreadFollowIntentsPayload');
    _expectFields(
        object, const {'intents'}, 'QueuedThreadFollowIntentsPayload');
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedThreadFollowIntentsPayload'),
      'QueuedThreadFollowIntentsPayload.intents',
    );
    if (encodedIntents.length > maxApplicationChatQueuedThreadFollowIntents) {
      throw const FormatException(
        'Stored thread-follow intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedThreadFollowIntent.fromJson)
        .toList(growable: false);
    final record = ApplicationChatQueuedThreadFollowIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedThreadFollowIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedThreadFollowIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedThreadFollowIntent> _prepare(
    List<ApplicationChatQueuedThreadFollowIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedThreadFollowIntents) {
      fail('Thread-follow intents must contain at most 1000 entries.');
    }
    final detached = intents
        .map(
          (intent) => ApplicationChatQueuedThreadFollowIntent._validated(
            request: _parseThreadFollowRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail('Thread-follow intents must have strictly increasing FIFO order.');
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail('Thread-follow intent idempotencyKey values must be unique.');
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedThreadFollowIntent>[];
    final laneIndexes = <ConversationId, int>{};
    for (final intent in detached) {
      final lane = intent.request.target.id;
      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
        continue;
      }
      final existing = normalized[existingIndex];
      normalized[existingIndex] =
          ApplicationChatQueuedThreadFollowIntent._validated(
        request: intent.request,
        enqueueOrder: existing.enqueueOrder,
        enqueuedAt: existing.enqueuedAt,
        contractVersion: existing.contractVersion,
      );
    }
    return normalized;
  }
}

SetThreadFollowInput _parseThreadFollowRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    final json = value is SetThreadFollowInput ? value.toJson() : value;
    return SetThreadFollowInput.fromJson(json);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Thread-follow request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Thread-follow request is invalid: ${error.message}',
    );
  }
}

/// A validated set or cancel reminder request with retry-stable metadata.
///
/// Construction reparses the complete generated request so persisted intents
/// are detached from caller-owned values. Trusted identity remains exclusively
/// in the containing record envelope.
final class ApplicationChatQueuedMessageReminderIntent {
  factory ApplicationChatQueuedMessageReminderIntent({
    required MessageReminderRequest request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatMessageReminderContractVersion,
  }) {
    final intent = ApplicationChatQueuedMessageReminderIntent._validated(
      request: _parseMessageReminderRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedMessageReminderIntent.fromJson(Object? json) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedMessageReminderIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued message-reminder intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedMessageReminderIntent');
    final intentValue = _required(
      object,
      'intent',
      'QueuedMessageReminderIntent',
    );
    final requestFields = switch (intentValue) {
      'set' => const {
          'operation',
          'intent',
          'conversationId',
          'messageId',
          'expectedReminderRevision',
          'idempotencyKey',
          'dueAt',
        },
      'cancel' => const {
          'operation',
          'intent',
          'conversationId',
          'messageId',
          'expectedReminderRevision',
          'idempotencyKey',
        },
      _ => throw const FormatException(
          'QueuedMessageReminderIntent.intent must be set or cancel.',
        ),
    };
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedMessageReminderIntent',
    );
    final contractVersion = _readInt(
      _required(
        object,
        'contractVersion',
        'QueuedMessageReminderIntent',
      ),
      'QueuedMessageReminderIntent.contractVersion',
    );
    if (contractVersion != applicationChatMessageReminderContractVersion) {
      throw FormatException(
        'Unsupported message-reminder contract version: $contractVersion.',
      );
    }
    final parsed = ApplicationChatQueuedMessageReminderIntent._validated(
      request: _parseMessageReminderRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedMessageReminderIntent'),
        'QueuedMessageReminderIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedMessageReminderIntent'),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedMessageReminderIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final MessageReminderRequest request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatMessageReminderContractVersion) {
      fail('Message-reminder intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Message-reminder intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail(
        'Message-reminder intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
          request.conversationId.value,
          maxMessageReminderIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.messageId.value,
          maxMessageReminderIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          maxMessageReminderIdempotencyKeyUtf8Bytes,
        )) {
      fail(
          'Message-reminder intent correlations must be nonblank and bounded.');
    }
    if (request.expectedReminderRevision < 0 ||
        request.expectedReminderRevision >= _maxSafeJsonInteger) {
      fail(
        'Message-reminder expected revision must be a nonnegative safe integer that can advance by one.',
      );
    }
    if (request case SetMessageReminderRequest(:final dueAt)) {
      if (!_isBoundedIsoTimestamp(dueAt.value)) {
        fail('Message-reminder dueAt must be a bounded ISO timestamp.');
      }
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedMessageReminderIntentBytes,
    )) {
      fail('Queued message-reminder intent exceeds 16384 encoded bytes.');
    }
  }
}

/// The latest desired reminder state for each message, in original FIFO order.
final class ApplicationChatQueuedMessageReminderIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedMessageReminderIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedMessageReminderIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedMessageReminderIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedMessageReminderIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedMessageReminderIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedMessageReminderIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedMessageReminderIntentsPayload'),
      'QueuedMessageReminderIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedMessageReminderIntents) {
      throw const FormatException(
        'Stored message-reminder intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedMessageReminderIntent.fromJson)
        .toList(growable: false);
    final record = ApplicationChatQueuedMessageReminderIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedMessageReminderIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedMessageReminderIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedMessageReminderIntent> _prepare(
    List<ApplicationChatQueuedMessageReminderIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedMessageReminderIntents) {
      fail('Message-reminder intents must contain at most 1000 entries.');
    }
    final detached = intents
        .map(
          (intent) => ApplicationChatQueuedMessageReminderIntent._validated(
            request: _parseMessageReminderRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Message-reminder intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail('Message-reminder intent idempotencyKey values must be unique.');
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedMessageReminderIntent>[];
    final laneIndexes = <MessageId, int>{};
    for (final intent in detached) {
      final lane = intent.request.messageId;
      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
        continue;
      }
      final existing = normalized[existingIndex];
      normalized[existingIndex] =
          ApplicationChatQueuedMessageReminderIntent._validated(
        request: intent.request,
        enqueueOrder: existing.enqueueOrder,
        enqueuedAt: existing.enqueuedAt,
        contractVersion: existing.contractVersion,
      );
    }
    return normalized;
  }
}

MessageReminderRequest _parseMessageReminderRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    final json = value is MessageReminderRequest ? value.toJson() : value;
    return MessageReminderRequest.fromJson(
      json,
      referenceTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Message-reminder request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Message-reminder request is invalid: ${error.message}',
    );
  }
}

/// A validated archive or restore request with retry-stable metadata.
///
/// Construction reparses the complete generated request so persisted intents
/// are detached from caller-owned values. Trusted identity remains exclusively
/// in the containing record envelope.
final class ApplicationChatQueuedConversationArchiveIntent {
  factory ApplicationChatQueuedConversationArchiveIntent({
    required ConversationArchiveInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatConversationArchiveContractVersion,
  }) {
    final intent = ApplicationChatQueuedConversationArchiveIntent._validated(
      request: _parseConversationArchiveRequest(
        request.toJson(),
        argumentError: true,
      ),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedConversationArchiveIntent.fromJson(
    Object? json,
  ) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationArchiveIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued conversation-archive intent exceeds 16384 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedConversationArchiveIntent');
    const requestFields = {
      'operation',
      'intent',
      'conversationId',
      'expectedLifecycleRevision',
      'idempotencyKey',
    };
    _expectFields(
      object,
      const {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedConversationArchiveIntent',
    );
    final contractVersion = _readInt(
      _required(
        object,
        'contractVersion',
        'QueuedConversationArchiveIntent',
      ),
      'QueuedConversationArchiveIntent.contractVersion',
    );
    if (contractVersion != applicationChatConversationArchiveContractVersion) {
      throw FormatException(
        'Unsupported conversation-archive contract version: $contractVersion.',
      );
    }
    final parsed = ApplicationChatQueuedConversationArchiveIntent._validated(
      request: _parseConversationArchiveRequest(
        <String, Object?>{
          for (final field in requestFields) field: object[field],
        },
        argumentError: false,
      ),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedConversationArchiveIntent'),
        'QueuedConversationArchiveIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedConversationArchiveIntent'),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedConversationArchiveIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final ConversationArchiveInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatConversationArchiveContractVersion) {
      fail('Conversation-archive intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Conversation-archive intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail(
        'Conversation-archive intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
          request.conversationId.value,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          _maxApplicationChatIntentIdentifierUtf8Bytes,
        )) {
      fail(
        'Conversation-archive intent correlations must be nonblank and bounded.',
      );
    }
    if (request.expectedLifecycleRevision < 1 ||
        request.expectedLifecycleRevision >= _maxSafeJsonInteger) {
      fail(
        'Conversation-archive expected revision must be a positive safe integer that can advance by one.',
      );
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedConversationArchiveIntentBytes,
    )) {
      fail('Queued conversation-archive intent exceeds 16384 encoded bytes.');
    }
  }
}

/// The latest desired lifecycle state per conversation in original FIFO order.
final class ApplicationChatQueuedConversationArchiveIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedConversationArchiveIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedConversationArchiveIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedConversationArchiveIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedConversationArchiveIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedConversationArchiveIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedConversationArchiveIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(
        object,
        'intents',
        'QueuedConversationArchiveIntentsPayload',
      ),
      'QueuedConversationArchiveIntentsPayload.intents',
    );
    if (encodedIntents.length >
        maxApplicationChatQueuedConversationArchiveIntents) {
      throw const FormatException(
        'Stored conversation-archive intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedConversationArchiveIntent.fromJson)
        .toList(growable: false);
    final record =
        ApplicationChatQueuedConversationArchiveIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedConversationArchiveIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedConversationArchiveIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatStorageRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Application chat storage record exceeds 5242880 encoded bytes.',
      );
    }
    throw const FormatException(
      'Application chat storage record exceeds 5242880 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedConversationArchiveIntent> _prepare(
    List<ApplicationChatQueuedConversationArchiveIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedConversationArchiveIntents) {
      fail('Conversation-archive intents must contain at most 1000 entries.');
    }
    final detached = intents
        .map(
          (intent) => ApplicationChatQueuedConversationArchiveIntent._validated(
            request: _parseConversationArchiveRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Conversation-archive intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail(
          'Conversation-archive intent idempotencyKey values must be unique.',
        );
      }
      previousOrder = intent.enqueueOrder;
    }

    final normalized = <ApplicationChatQueuedConversationArchiveIntent>[];
    final laneIndexes = <ConversationId, int>{};
    for (final intent in detached) {
      final lane = intent.request.conversationId;
      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
        continue;
      }
      final existing = normalized[existingIndex];
      normalized[existingIndex] =
          ApplicationChatQueuedConversationArchiveIntent._validated(
        request: intent.request,
        enqueueOrder: existing.enqueueOrder,
        enqueuedAt: existing.enqueuedAt,
        contractVersion: existing.contractVersion,
      );
    }
    return normalized;
  }
}

ConversationArchiveInput _parseConversationArchiveRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    final json = value is ConversationArchiveInput ? value.toJson() : value;
    return ConversationArchiveInput.fromJson(json);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
        'Conversation-archive request is invalid: ${error.message}',
      );
    }
    throw FormatException(
      'Conversation-archive request is invalid: ${error.message}',
    );
  }
}

/// A closed, retry-stable huddle command with trusted correlation metadata.
///
/// [conversationId] associates session-targeted commands with their owning
/// conversation without persisting any huddle state or media descriptor. The
/// generated command parser is always reapplied so callers cannot extend the
/// command union with provider or transport data.
final class ApplicationChatQueuedHuddleCommandIntent {
  factory ApplicationChatQueuedHuddleCommandIntent({
    required HuddleCommandInput request,
    required ConversationId conversationId,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatHuddleCommandContractVersion,
  }) {
    final intent = ApplicationChatQueuedHuddleCommandIntent._validated(
      request: _parseHuddleCommandRequest(
        request.toJson(),
        argumentError: true,
      ),
      conversationId: ConversationId(conversationId.value),
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedHuddleCommandIntent.fromJson(Object? json) {
    _validateHuddleStorageSafety(json, argumentError: false);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedHuddleCommandIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued huddle-command intent exceeds 1024 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedHuddleCommandIntent');
    final operation = _readString(
      _required(object, 'operation', 'QueuedHuddleCommandIntent'),
      'QueuedHuddleCommandIntent.operation',
    );
    const commonFields = {
      'contractVersion',
      'enqueueOrder',
      'enqueuedAt',
      'conversationId',
      'operation',
      'idempotencyKey',
    };
    final expectedFields = switch (operation) {
      'start_huddle' => commonFields,
      'join_huddle' || 'leave_huddle' || 'end_huddle' => const {
          ...commonFields,
          'huddleSessionId',
        },
      'set_huddle_screen_share' => const {
          ...commonFields,
          'huddleSessionId',
          'intent',
        },
      _ => throw FormatException(
          'Unsupported queued huddle command operation: $operation.',
        ),
    };
    _expectFields(object, expectedFields, 'QueuedHuddleCommandIntent');
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedHuddleCommandIntent'),
      'QueuedHuddleCommandIntent.contractVersion',
    );
    if (contractVersion != applicationChatHuddleCommandContractVersion) {
      throw FormatException(
        'Unsupported huddle-command contract version: $contractVersion.',
      );
    }
    final requestJson = <String, Object?>{
      'operation': operation,
      if (operation == 'start_huddle')
        'conversationId': object['conversationId']
      else
        'huddleSessionId': object['huddleSessionId'],
      if (operation == 'set_huddle_screen_share') 'intent': object['intent'],
      'idempotencyKey': object['idempotencyKey'],
    };
    final parsed = ApplicationChatQueuedHuddleCommandIntent._validated(
      request: _parseHuddleCommandRequest(
        requestJson,
        argumentError: false,
      ),
      conversationId: ConversationId.fromJson(
        _required(object, 'conversationId', 'QueuedHuddleCommandIntent'),
      ),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedHuddleCommandIntent'),
        'QueuedHuddleCommandIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedHuddleCommandIntent'),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedHuddleCommandIntent._validated({
    required this.request,
    required this.conversationId,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final HuddleCommandInput request;
  final ConversationId conversationId;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        'conversationId': conversationId.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatHuddleCommandContractVersion) {
      fail('Huddle-command intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail(
        'Huddle-command intent enqueueOrder must be a positive safe integer.',
      );
    }
    if (!_isBoundedIsoTimestamp(enqueuedAt.value)) {
      fail(
        'Huddle-command intent enqueuedAt must be a bounded ISO timestamp.',
      );
    }
    if (!_isBoundedNonBlankUtf8(
          conversationId.value,
          maxHuddleIdentifierUtf8Bytes,
        ) ||
        !_isBoundedNonBlankUtf8(
          request.idempotencyKey,
          maxHuddleIdempotencyKeyUtf8Bytes,
        )) {
      fail('Huddle-command intent correlations must be nonblank and bounded.');
    }
    if (request case final StartHuddleInput startRequest) {
      if (startRequest.conversationId != conversationId) {
        fail(
          'Start-huddle request and storage conversation correlations must match.',
        );
      }
    }
    final json = toJson();
    try {
      _validateHuddleStorageSafety(json, argumentError: false);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedHuddleCommandIntentBytes,
    )) {
      fail('Queued huddle-command intent exceeds 1024 encoded bytes.');
    }
  }
}

/// Latest compatible huddle desires, retained in their original FIFO lanes.
///
/// Participation (`join`/`leave`) and screen-share (`set`/`clear`) commands
/// coalesce only within the same conversation/session correlation. Starts,
/// ends, cross-session correlations, and terminal/nonterminal mixtures are
/// rejected instead of being silently rewritten.
final class ApplicationChatQueuedHuddleCommandIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedHuddleCommandIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedHuddleCommandIntent> intents,
  })  : intents = List.unmodifiable(_prepare(intents, argumentError: true)),
        super._() {
    _validateEncodedSize(argumentError: true);
  }

  ApplicationChatQueuedHuddleCommandIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedHuddleCommandIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedHuddleCommandIntentsRecordBytes,
    )) {
      throw const FormatException(
        'Stored queued huddle-command record exceeds 262144 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedHuddleCommandIntentsPayload');
    _expectFields(
      object,
      const {'intents'},
      'QueuedHuddleCommandIntentsPayload',
    );
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedHuddleCommandIntentsPayload'),
      'QueuedHuddleCommandIntentsPayload.intents',
    );
    if (encodedIntents.length > maxApplicationChatQueuedHuddleCommandIntents) {
      throw const FormatException(
        'Stored huddle-command intents must contain at most 1000 entries.',
      );
    }
    final parsed = encodedIntents
        .map(ApplicationChatQueuedHuddleCommandIntent.fromJson)
        .toList(growable: false);
    final record = ApplicationChatQueuedHuddleCommandIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(_prepare(parsed, argumentError: false)),
    );
    record._validateEncodedSize(argumentError: false);
    return record;
  }

  final List<ApplicationChatQueuedHuddleCommandIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedHuddleCommandIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  void _validateEncodedSize({required bool argumentError}) {
    if (!_exceedsUtf8ByteLimit(
      jsonEncode(toJson()),
      maxApplicationChatQueuedHuddleCommandIntentsRecordBytes,
    )) {
      return;
    }
    if (argumentError) {
      throw ArgumentError(
        'Queued huddle-command record exceeds 262144 encoded bytes.',
      );
    }
    throw const FormatException(
      'Stored queued huddle-command record exceeds 262144 encoded bytes.',
    );
  }

  static List<ApplicationChatQueuedHuddleCommandIntent> _prepare(
    List<ApplicationChatQueuedHuddleCommandIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (intents.length > maxApplicationChatQueuedHuddleCommandIntents) {
      fail('Huddle-command intents must contain at most 1000 entries.');
    }
    final detached = intents
        .map(
          (intent) => ApplicationChatQueuedHuddleCommandIntent._validated(
            request: _parseHuddleCommandRequest(
              intent.request.toJson(),
              argumentError: argumentError,
            ),
            conversationId: ConversationId(intent.conversationId.value),
            enqueueOrder: intent.enqueueOrder,
            enqueuedAt: IsoTimestamp(intent.enqueuedAt.value),
            contractVersion: intent.contractVersion,
          ),
        )
        .toList(growable: false);
    final idempotencyKeys = <String>{};
    final starts = <ConversationId>{};
    final sessionToConversation = <HuddleSessionId, ConversationId>{};
    final conversationToSession = <ConversationId, HuddleSessionId>{};
    var previousOrder = 0;
    for (final intent in detached) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail(
          'Huddle-command intents must have strictly increasing FIFO order.',
        );
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail('Huddle-command intent idempotencyKey values must be unique.');
      }
      previousOrder = intent.enqueueOrder;
      final request = intent.request;
      if (request is StartHuddleInput) {
        if (!starts.add(intent.conversationId)) {
          fail('A conversation cannot contain multiple queued huddle starts.');
        }
        continue;
      }
      final sessionId = (request as SessionHuddleInput).huddleSessionId;
      final priorConversation = sessionToConversation[sessionId];
      final priorSession = conversationToSession[intent.conversationId];
      if ((priorConversation != null &&
              priorConversation != intent.conversationId) ||
          (priorSession != null && priorSession != sessionId)) {
        fail(
          'Huddle-command conversation and session correlations conflict.',
        );
      }
      sessionToConversation[sessionId] = intent.conversationId;
      conversationToSession[intent.conversationId] = sessionId;
    }
    if (starts.any(conversationToSession.containsKey)) {
      fail(
        'A queued huddle start is incompatible with session commands for the same conversation.',
      );
    }

    final normalized = <ApplicationChatQueuedHuddleCommandIntent>[];
    final laneIndexes = <String, int>{};
    final sessionKinds = <String, Set<String>>{};
    for (final intent in detached) {
      final request = intent.request;
      if (request is StartHuddleInput) {
        normalized.add(intent);
        continue;
      }
      final sessionId = (request as SessionHuddleInput).huddleSessionId;
      final correlation =
          '${intent.conversationId.value}\u0000${sessionId.value}';
      final category = switch (request) {
        JoinHuddleInput() || LeaveHuddleInput() => 'participation',
        SetHuddleScreenShareInput() => 'screen_share',
        EndHuddleInput() => 'end',
      };
      final categories =
          sessionKinds.putIfAbsent(correlation, () => <String>{});
      if (category == 'end') {
        if (categories.isNotEmpty) {
          fail(
            'An end-huddle command is incompatible with other queued commands for its correlation.',
          );
        }
        categories.add(category);
        normalized.add(intent);
        continue;
      }
      if (categories.contains('end')) {
        fail(
          'Commands cannot follow an end-huddle command for the same correlation.',
        );
      }
      categories.add(category);
      final lane = '$correlation\u0000$category';
      final existingIndex = laneIndexes[lane];
      if (existingIndex == null) {
        laneIndexes[lane] = normalized.length;
        normalized.add(intent);
        continue;
      }
      final existing = normalized[existingIndex];
      normalized[existingIndex] =
          ApplicationChatQueuedHuddleCommandIntent._validated(
        request: intent.request,
        conversationId: intent.conversationId,
        enqueueOrder: existing.enqueueOrder,
        enqueuedAt: existing.enqueuedAt,
        contractVersion: existing.contractVersion,
      );
    }
    return normalized;
  }
}

HuddleCommandInput _parseHuddleCommandRequest(
  Object? value, {
  required bool argumentError,
}) {
  try {
    final json = value is HuddleCommandInput ? value.toJson() : value;
    _validateHuddleStorageSafety(json, argumentError: false);
    return HuddleCommandInput.fromJson(json);
  } on FormatException catch (error) {
    if (argumentError) {
      throw ArgumentError(
          'Huddle-command request is invalid: ${error.message}');
    }
    throw FormatException(
      'Huddle-command request is invalid: ${error.message}',
    );
  }
}

void _validateHuddleStorageSafety(
  Object? value, {
  required bool argumentError,
  String path = r'$',
}) {
  Never fail(String message) {
    if (argumentError) throw ArgumentError(message);
    throw FormatException(message);
  }

  if (value == null || value is num || value is bool) return;
  if (value is String) {
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value) ||
        RegExp(r'^(?:Bearer|Basic)\s+', caseSensitive: false).hasMatch(value)) {
      fail('$path contains transport or credential material.');
    }
    return;
  }
  if (value is List<Object?>) {
    for (var index = 0; index < value.length; index += 1) {
      _validateHuddleStorageSafety(
        value[index],
        argumentError: argumentError,
        path: '$path[$index]',
      );
    }
    return;
  }
  if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) fail('$path contains a non-string JSON key.');
      final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
      if (_isForbiddenHuddleStorageField(normalized)) {
        fail('$path.$key is not permitted in huddle-command storage.');
      }
      _validateHuddleStorageSafety(
        entry.value,
        argumentError: argumentError,
        path: '$path.$key',
      );
    }
    return;
  }
  fail('$path contains a non-JSON value.');
}

bool _isForbiddenHuddleStorageField(String normalized) =>
    _isForbiddenStorageField(normalized) ||
    normalized == 'url' ||
    normalized.endsWith('url') ||
    normalized == 'uri' ||
    normalized.endsWith('uri') ||
    normalized.contains('header') ||
    normalized.contains('socket') ||
    normalized.contains('transport') ||
    normalized.contains('endpoint') ||
    normalized == 'result' ||
    normalized.endsWith('result') ||
    normalized == 'outcome' ||
    normalized == 'state' ||
    normalized == 'mediajoin' ||
    normalized == 'descriptor';

/// A validated draft synchronization request with deterministic FIFO metadata.
///
/// The complete generated replace/clear request is retained. Its
/// `baseRevision` is the authoritative server revision observed before the
/// optimistic draft projection; no projected snapshot or transport metadata
/// is representable in this record.
final class ApplicationChatQueuedDraftIntent {
  factory ApplicationChatQueuedDraftIntent({
    required SynchronizeDraftInput request,
    required int enqueueOrder,
    required IsoTimestamp enqueuedAt,
    int contractVersion = applicationChatDraftMutationContractVersion,
  }) {
    final detachedRequest = SynchronizeDraftInput.fromJson(request.toJson());
    final intent = ApplicationChatQueuedDraftIntent._validated(
      request: detachedRequest,
      enqueueOrder: enqueueOrder,
      enqueuedAt: IsoTimestamp(enqueuedAt.value),
      contractVersion: contractVersion,
    );
    intent._validate(argumentError: true);
    return intent;
  }

  factory ApplicationChatQueuedDraftIntent.fromJson(Object? json) {
    _validateSecretFreeJson(json, r'$', true);
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedDraftIntentBytes,
    )) {
      throw const FormatException(
        'Stored queued draft intent exceeds 131072 encoded bytes.',
      );
    }
    final object = _readObject(json, 'QueuedDraftIntent');
    final intentValue = _required(object, 'intent', 'QueuedDraftIntent');
    final requestFields = switch (intentValue) {
      'replace' => const {
          'operation',
          'intent',
          'conversationId',
          'baseRevision',
          'deviceMutationId',
          'idempotencyKey',
          'content',
        },
      'clear' => const {
          'operation',
          'intent',
          'conversationId',
          'baseRevision',
          'deviceMutationId',
          'idempotencyKey',
        },
      _ => throw const FormatException(
          'QueuedDraftIntent.intent must be replace or clear.',
        ),
    };
    _expectFields(
      object,
      {
        'contractVersion',
        'enqueueOrder',
        'enqueuedAt',
        ...requestFields,
      },
      'QueuedDraftIntent',
    );
    final contractVersion = _readInt(
      _required(object, 'contractVersion', 'QueuedDraftIntent'),
      'QueuedDraftIntent.contractVersion',
    );
    if (contractVersion != applicationChatDraftMutationContractVersion) {
      throw FormatException(
        'Unsupported draft mutation contract version: $contractVersion.',
      );
    }
    final requestJson = <String, Object?>{
      for (final field in requestFields) field: object[field],
    };
    final parsed = ApplicationChatQueuedDraftIntent._validated(
      request: SynchronizeDraftInput.fromJson(requestJson),
      enqueueOrder: _readInt(
        _required(object, 'enqueueOrder', 'QueuedDraftIntent'),
        'QueuedDraftIntent.enqueueOrder',
      ),
      enqueuedAt: IsoTimestamp.fromJson(
        _required(object, 'enqueuedAt', 'QueuedDraftIntent'),
      ),
      contractVersion: contractVersion,
    );
    parsed._validate(argumentError: false);
    return parsed;
  }

  ApplicationChatQueuedDraftIntent._validated({
    required this.request,
    required this.enqueueOrder,
    required this.enqueuedAt,
    required this.contractVersion,
  });

  final int contractVersion;
  final SynchronizeDraftInput request;
  final int enqueueOrder;
  final IsoTimestamp enqueuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'contractVersion': contractVersion,
        'enqueueOrder': enqueueOrder,
        'enqueuedAt': enqueuedAt.toJson(),
        ...request.toJson(),
      };

  void _validate({required bool argumentError}) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    if (contractVersion != applicationChatDraftMutationContractVersion) {
      fail('Draft intent contract version is not supported.');
    }
    if (enqueueOrder < 1 || enqueueOrder > _maxSafeJsonInteger) {
      fail('Draft intent enqueueOrder must be a positive safe integer.');
    }
    if (enqueuedAt.value.length >
            _maxApplicationChatIntentTimestampCharacters ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(enqueuedAt.value) ||
        DateTime.tryParse(enqueuedAt.value) == null) {
      fail('Draft intent enqueuedAt must be a bounded ISO timestamp.');
    }
    final json = toJson();
    try {
      _validateSecretFreeJson(json, r'$', true);
    } on FormatException catch (error) {
      fail(error.message.toString());
    }
    if (_exceedsUtf8ByteLimit(
      jsonEncode(json),
      maxApplicationChatQueuedDraftIntentBytes,
    )) {
      fail('Queued draft intent exceeds 131072 encoded bytes.');
    }
  }
}

/// The latest unacknowledged draft request for each conversation identity.
final class ApplicationChatQueuedDraftIntentsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatQueuedDraftIntentsRecord({
    required super.identity,
    required List<ApplicationChatQueuedDraftIntent> intents,
  })  : intents = List.unmodifiable(
          _prepare(intents, argumentError: true),
        ),
        super._();

  ApplicationChatQueuedDraftIntentsRecord._validated({
    required super.identity,
    required this.intents,
  }) : super._();

  factory ApplicationChatQueuedDraftIntentsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'QueuedDraftIntentsPayload');
    _expectFields(object, const {'intents'}, 'QueuedDraftIntentsPayload');
    final encodedIntents = _readList(
      _required(object, 'intents', 'QueuedDraftIntentsPayload'),
      'QueuedDraftIntentsPayload.intents',
    );
    final parsed = encodedIntents
        .map(ApplicationChatQueuedDraftIntent.fromJson)
        .toList(growable: false);
    return ApplicationChatQueuedDraftIntentsRecord._validated(
      identity: identity,
      intents: List.unmodifiable(
        _prepare(parsed, argumentError: false),
      ),
    );
  }

  final List<ApplicationChatQueuedDraftIntent> intents;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.queuedDraftIntents;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'intents': intents.map((intent) => intent.toJson()).toList(),
      };

  static List<ApplicationChatQueuedDraftIntent> _prepare(
    List<ApplicationChatQueuedDraftIntent> intents, {
    required bool argumentError,
  }) {
    Never fail(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    final deviceMutationIds = <String>{};
    final idempotencyKeys = <String>{};
    var previousOrder = 0;
    for (final intent in intents) {
      intent._validate(argumentError: argumentError);
      if (intent.enqueueOrder <= previousOrder) {
        fail('Draft intents must have strictly increasing FIFO order.');
      }
      if (!deviceMutationIds.add(intent.request.deviceMutationId)) {
        fail('Draft intent deviceMutationId values must be unique.');
      }
      if (!idempotencyKeys.add(intent.request.idempotencyKey)) {
        fail('Draft intent idempotencyKey values must be unique.');
      }
      previousOrder = intent.enqueueOrder;
    }

    final latestByConversation =
        <ConversationId, ApplicationChatQueuedDraftIntent>{};
    for (final intent in intents) {
      latestByConversation[intent.request.conversationId] = intent;
    }
    final normalized = intents
        .where(
          (intent) => identical(
            latestByConversation[intent.request.conversationId],
            intent,
          ),
        )
        .toList(growable: false);
    if (normalized.length > maxApplicationChatQueuedDraftConversations) {
      fail('Draft intents must contain at most 500 conversations.');
    }
    return normalized;
  }
}

/// Token-free canonical revision metadata for one push delivery target.
///
/// The opaque provider token is intentionally not representable here. The
/// JSON field is named `pushService` so the storage secret-field guard can
/// continue rejecting all provider credential/configuration fields.
final class ApplicationChatPushTokenRevision {
  ApplicationChatPushTokenRevision({
    required this.platform,
    required this.pushService,
    required this.environment,
    required this.status,
    required this.revision,
    required this.updatedAt,
  }) {
    CanonicalDevicePushTokenState(
      deviceId: const DeviceId('storage-validation-device'),
      status: status,
      platform: platform,
      provider: pushService,
      environment: environment,
      tokenRevision: revision,
      updatedAt: updatedAt,
    );
  }

  factory ApplicationChatPushTokenRevision.fromJson(Object? json) {
    final object = _readObject(json, 'PushTokenRevision');
    _expectFields(
      object,
      const {
        'platform',
        'pushService',
        'environment',
        'status',
        'revision',
        'updatedAt',
      },
      'PushTokenRevision',
    );
    final canonical = CanonicalDevicePushTokenState.fromJson({
      'deviceId': 'storage-validation-device',
      'status': _required(object, 'status', 'PushTokenRevision'),
      'platform': _required(object, 'platform', 'PushTokenRevision'),
      'provider': _required(object, 'pushService', 'PushTokenRevision'),
      'environment': _required(object, 'environment', 'PushTokenRevision'),
      'tokenRevision': _required(object, 'revision', 'PushTokenRevision'),
      'updatedAt': _required(object, 'updatedAt', 'PushTokenRevision'),
    });
    return ApplicationChatPushTokenRevision(
      platform: canonical.platform,
      pushService: canonical.provider,
      environment: canonical.environment,
      status: canonical.status,
      revision: canonical.tokenRevision,
      updatedAt: canonical.updatedAt,
    );
  }

  factory ApplicationChatPushTokenRevision.fromCanonical(
    CanonicalDevicePushTokenState state,
  ) =>
      ApplicationChatPushTokenRevision(
        platform: state.platform,
        pushService: state.provider,
        environment: state.environment,
        status: state.status,
        revision: state.tokenRevision,
        updatedAt: state.updatedAt,
      );

  final DevicePlatform platform;
  final DevicePushProvider pushService;
  final DevicePushProviderEnvironment environment;
  final DevicePushTokenStatus status;
  final int revision;
  final IsoTimestamp updatedAt;

  CanonicalDevicePushTokenState toCanonical(DeviceId deviceId) =>
      CanonicalDevicePushTokenState(
        deviceId: deviceId,
        status: status,
        platform: platform,
        provider: pushService,
        environment: environment,
        tokenRevision: revision,
        updatedAt: updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'platform': platform.toJson(),
        'pushService': pushService.toJson(),
        'environment': environment.toJson(),
        'status': status.toJson(),
        'revision': revision,
        'updatedAt': updatedAt.toJson(),
      };
}

/// Complete token-free push revision set for one trusted device identity.
final class ApplicationChatPushTokenRevisionsRecord
    extends ApplicationChatStorageRecord {
  ApplicationChatPushTokenRevisionsRecord({
    required super.identity,
    required List<ApplicationChatPushTokenRevision> revisions,
  })  : revisions = List.unmodifiable(revisions),
        super._() {
    _validateUniquePushTokenTargets(this.revisions, argumentError: true);
  }

  factory ApplicationChatPushTokenRevisionsRecord._fromPayload(
    ApplicationChatStorageIdentity identity,
    Object? json,
  ) {
    final object = _readObject(json, 'PushTokenRevisionsPayload');
    _expectFields(object, const {'revisions'}, 'PushTokenRevisionsPayload');
    final revisions = _readList(
      _required(object, 'revisions', 'PushTokenRevisionsPayload'),
      'PushTokenRevisionsPayload.revisions',
    ).map(ApplicationChatPushTokenRevision.fromJson).toList(growable: false);
    _validateUniquePushTokenTargets(revisions, argumentError: false);
    return ApplicationChatPushTokenRevisionsRecord(
      identity: identity,
      revisions: revisions,
    );
  }

  final List<ApplicationChatPushTokenRevision> revisions;

  @override
  ApplicationChatStorageRecordKind get kind =>
      ApplicationChatStorageRecordKind.pushTokenRevisions;

  @override
  Map<String, Object?> payloadToJson() => <String, Object?>{
        'revisions': revisions.map((revision) => revision.toJson()).toList(),
      };
}

void _validateUniquePushTokenTargets(
  List<ApplicationChatPushTokenRevision> revisions, {
  required bool argumentError,
}) {
  final targets = <String>{};
  for (final revision in revisions) {
    final target = '${revision.platform.toJson()}\u0000'
        '${revision.pushService.toJson()}\u0000'
        '${revision.environment.toJson()}';
    if (targets.add(target)) continue;
    if (argumentError) {
      throw ArgumentError('Push token revision targets must be unique.');
    }
    throw const FormatException(
      'Stored push token revision targets must be unique.',
    );
  }
}

/// Application-provided async persistence for Handrail Chat core state.
///
/// Each operation must be atomic: readers observe the complete record before
/// or after a replace/remove, never an intermediate representation. Corrupt
/// data must surface as a [FormatException], not as partial state.
abstract interface class ApplicationChatStorage {
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  );

  Future<void> replace(ApplicationChatStorageRecord record);

  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  );

  /// Atomically removes all records for the identity that logged out.
  Future<void> clearForLogout(ApplicationChatStorageIdentity previousIdentity);

  /// Atomically removes only the prior identity when an application switches.
  ///
  /// When both identities are equal, no records are removed.
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  });
}

/// Optional atomic extension for storage shared by concurrent chat runtimes.
///
/// [readEncoded] returns the exact stored representation rather than a
/// re-encoding so compare/exchange and corrupt-value quarantine cannot act on
/// a newer value. A non-null replacement must be an encoded
/// [ApplicationChatStorageRecord] for the supplied [identity] and [kind]. The
/// expected value is opaque and may be malformed when it came directly from
/// [readEncoded]. The exchange commits only when that exact value still
/// exists. A null expected value requires the key to be absent, while a null
/// replacement removes the matching key.
abstract interface class AtomicApplicationChatStorage
    implements ApplicationChatStorage {
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  );

  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  );
}

/// Synchronous transform used by [ApplicationChatStorageMutator.mutate].
typedef ApplicationChatStorageUpdater<
        TRecord extends ApplicationChatStorageRecord>
    = TRecord? Function(TRecord? current);

/// A bounded atomic mutation could not commit because its key stayed busy.
final class ApplicationChatStorageUnavailableException implements Exception {
  const ApplicationChatStorageUnavailableException();

  String get code => applicationChatStorageContentionErrorCode;
  String get message => applicationChatStorageContentionErrorMessage;

  @override
  String toString() => 'ApplicationChatStorageUnavailableException: $message';
}

/// Validated bounded mutation facade over [ApplicationChatStorage].
///
/// Atomic storage retries compare/exchange contention and conditionally
/// quarantines only the exact malformed encoded value it read. A legacy
/// storage implementation retains a read-then-replace/remove fallback for a
/// single runtime only. That fallback cannot prevent lost updates across
/// runtimes and may unconditionally remove a malformed value, so shared
/// storage implementations must implement [AtomicApplicationChatStorage].
final class ApplicationChatStorageMutator {
  const ApplicationChatStorageMutator(this._storage);

  final ApplicationChatStorage _storage;

  /// Applies [updater] synchronously to one exact identity-and-kind record.
  ///
  /// A non-null result is fully encoded and decoded before any write, which
  /// validates its schema, content, identity, kind, and encoded size and also
  /// makes the committed return value detached from the updater's instance.
  Future<TRecord?> mutate<TRecord extends ApplicationChatStorageRecord>(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    ApplicationChatStorageUpdater<TRecord> updater,
  ) async {
    final trustedIdentity =
        ApplicationChatStorageIdentity.fromJson(identity.toJson());
    final storage = _storage;
    if (storage is AtomicApplicationChatStorage) {
      return _mutateAtomic<TRecord>(
        storage,
        trustedIdentity,
        kind,
        updater,
      );
    }
    return _mutateLegacy<TRecord>(trustedIdentity, kind, updater);
  }

  Future<TRecord?> _mutateAtomic<TRecord extends ApplicationChatStorageRecord>(
    AtomicApplicationChatStorage storage,
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    ApplicationChatStorageUpdater<TRecord> updater,
  ) async {
    for (var attempt = 0;
        attempt < maxApplicationChatStorageMutationAttempts;
        attempt += 1) {
      final encoded = await storage.readEncoded(identity, kind);
      TRecord? current;
      if (encoded != null) {
        try {
          current = _decodeStoredMutationRecord<TRecord>(
            encoded,
            identity,
            kind,
          );
        } on FormatException {
          try {
            await storage.compareExchange(identity, kind, encoded, null);
          } on Object {
            // Validation errors must not expose adapter or record details.
          }
          throw const FormatException(
            'Application chat storage record failed validation.',
          );
        }
      }
      final proposal = _normalizeMutationProposal(
        updater(current),
        identity,
        kind,
      );
      if (await storage.compareExchange(
        identity,
        kind,
        encoded,
        proposal?.encoded,
      )) {
        return proposal?.record;
      }
    }
    throw const ApplicationChatStorageUnavailableException();
  }

  Future<TRecord?> _mutateLegacy<TRecord extends ApplicationChatStorageRecord>(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    ApplicationChatStorageUpdater<TRecord> updater,
  ) async {
    ApplicationChatStorageRecord? stored;
    try {
      stored = await _storage.read(identity, kind);
    } on FormatException {
      await _quarantineLegacy(identity, kind);
    }

    TRecord? current;
    String? encoded;
    if (stored != null) {
      try {
        encoded = stored.encode();
      } on ArgumentError {
        await _quarantineLegacy(identity, kind);
      }
      try {
        current = _decodeStoredMutationRecord<TRecord>(
          encoded,
          identity,
          kind,
        );
      } on FormatException {
        await _quarantineLegacy(identity, kind);
      }
    }

    final proposal = _normalizeMutationProposal(
      updater(current),
      identity,
      kind,
    );
    // Legacy single-writer hydration and unchanged updates need no write.
    // Atomic storage still compares/exchanges even unchanged values so a
    // concurrent replacement cannot make the returned record stale.
    if (proposal?.encoded == encoded) return proposal?.record;
    if (proposal == null) {
      await _storage.remove(identity, kind);
      return null;
    }
    await _storage.replace(proposal.record);
    return proposal.record;
  }

  Future<Never> _quarantineLegacy(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    try {
      await _storage.remove(identity, kind);
    } on Object {
      // Validation errors must not expose adapter or record details.
    }
    throw const FormatException(
      'Application chat storage record failed validation.',
    );
  }
}

final class _ApplicationChatMutationProposal<
    TRecord extends ApplicationChatStorageRecord> {
  const _ApplicationChatMutationProposal(this.record, this.encoded);

  final TRecord record;
  final String encoded;
}

_ApplicationChatMutationProposal<TRecord>?
    _normalizeMutationProposal<TRecord extends ApplicationChatStorageRecord>(
  TRecord? proposal,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
) {
  if (proposal == null) return null;
  final encoded = proposal.encode();
  final normalized = _decodeMutationRecord<TRecord>(encoded, identity, kind);
  return _ApplicationChatMutationProposal(normalized, encoded);
}

TRecord _decodeMutationRecord<TRecord extends ApplicationChatStorageRecord>(
  String encoded,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
) {
  final record = ApplicationChatStorageRecord.decode(encoded);
  if (record.identity != identity) {
    throw ArgumentError(
      'Application chat storage mutation result identity must match its key.',
    );
  }
  if (record.kind != kind) {
    throw ArgumentError(
      'Application chat storage mutation result kind must match its key.',
    );
  }
  if (record is! TRecord) {
    throw ArgumentError(
      'Application chat storage mutation result type must match its key.',
    );
  }
  return record;
}

TRecord
    _decodeStoredMutationRecord<TRecord extends ApplicationChatStorageRecord>(
  String encoded,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
) {
  final record = ApplicationChatStorageRecord.decode(encoded);
  if (record.identity != identity || record.kind != kind) {
    throw const FormatException(
      'Stored application chat record does not match its storage scope.',
    );
  }
  if (record is! TRecord) {
    throw ArgumentError(
      'Application chat storage mutation record type must match its key.',
    );
  }
  return record;
}

bool _exceedsUtf8ByteLimit(String value, int maximumBytes) =>
    value.length > maximumBytes || utf8.encode(value).length > maximumBytes;

void _validateSnapshotTenant(
  NormalizedSnapshotState snapshot,
  TenantId tenantId,
) {
  for (final conversation in snapshot.conversations.values) {
    if (conversation.tenantId != tenantId) {
      throw ArgumentError('The normalized snapshot crosses tenant identity.');
    }
  }
  for (final message in snapshot.canonicalMessages.values) {
    if (message.tenantId != tenantId) {
      throw ArgumentError('The normalized snapshot crosses tenant identity.');
    }
  }
  for (final message in snapshot.messages.values) {
    if (message.tenantId != tenantId) {
      throw ArgumentError('The normalized snapshot crosses tenant identity.');
    }
  }
  for (final members in snapshot.membersByConversation.values) {
    for (final member in members.values) {
      if (member.tenantId != tenantId) {
        throw ArgumentError(
          'The normalized snapshot crosses tenant identity.',
        );
      }
    }
  }
}

const _secretFieldNames = <String>{
  'accesstoken',
  'apikey',
  'auth',
  'authentication',
  'authorizationdata',
  'authtoken',
  'authorization',
  'authorizationheader',
  'bearertoken',
  'credential',
  'credentials',
  'password',
  'provider',
  'providerconfig',
  'providerconfiguration',
  'providerdescriptor',
  'providerdata',
  'uploadprovider',
  'uploadproviderconfig',
  'uploadproviderconfiguration',
  'providertoken',
  'token',
  'secret',
  'clientsecret',
  'apisecret',
  'bytes',
  'rawbytes',
  'attachmentbytes',
  'attachmentsource',
  'bytesource',
  'mediadescriptor',
  'mediadescriptors',
  'mediatoken',
  'huddlemediatoken',
  'huddletoken',
  'commandbody',
  'commandrequestbody',
  'requestbody',
  'diagnostic',
  'diagnostics',
  'rawdiagnostic',
  'error',
  'rawerror',
  'exception',
  'stack',
  'stacktrace',
  'throwable',
  'thrown',
  'thrownvalue',
};

void _validateSecretFreeJson(
  Object? value, [
  String path = r'$',
  bool rejectByteLikeData = false,
]) {
  if (value == null || value is String || value is num || value is bool) {
    return;
  }
  if (value is List<Object?>) {
    if (rejectByteLikeData &&
        value.isNotEmpty &&
        value.every((item) => item is int && item >= 0 && item <= 255)) {
      throw FormatException('$path contains byte-like data.');
    }
    for (var index = 0; index < value.length; index += 1) {
      _validateSecretFreeJson(
        value[index],
        '$path[$index]',
        rejectByteLikeData,
      );
    }
    return;
  }
  if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException('$path contains a non-string JSON key.');
      }
      final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
      if (_isForbiddenStorageField(normalized)) {
        throw FormatException('$path.$key is not permitted in storage.');
      }
      _validateSecretFreeJson(
        entry.value,
        '$path.$key',
        rejectByteLikeData,
      );
    }
    return;
  }
  throw FormatException('$path contains a non-JSON value.');
}

bool _isForbiddenStorageField(String normalized) =>
    _secretFieldNames.contains(normalized) ||
    normalized.contains('authorization') ||
    normalized.contains('accesstoken') ||
    normalized.contains('authtoken') ||
    normalized.endsWith('token') ||
    normalized.contains('authentication') ||
    normalized.contains('secret') ||
    normalized.contains('credential') ||
    normalized.contains('providerc') ||
    normalized.contains('providerdata') ||
    normalized.contains('providerdescriptor') ||
    normalized.contains('attachmentbytes') ||
    normalized.contains('attachmentsource') ||
    normalized.contains('bytesource') ||
    normalized.contains('mediatoken') ||
    normalized.contains('huddletoken') ||
    normalized.contains('mediadescriptor') ||
    normalized.contains('diagnostic') ||
    normalized.endsWith('error') ||
    normalized.contains('exception') ||
    normalized.contains('stacktrace') ||
    normalized.endsWith('stack') ||
    normalized.startsWith('stack');

Map<String, Object?> _readObject(Object? json, String name) {
  if (json is! Map<Object?, Object?>) {
    throw FormatException('$name must be a JSON object.');
  }
  final result = <String, Object?>{};
  for (final entry in json.entries) {
    if (entry.key is! String) {
      throw FormatException('$name keys must be strings.');
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}

List<Object?> _readList(Object? json, String name) {
  if (json is! List<Object?>) {
    throw FormatException('$name must be a JSON array.');
  }
  return json;
}

void _expectFields(
    Map<String, Object?> object, Set<String> fields, String name) {
  for (final key in object.keys) {
    if (!fields.contains(key)) {
      throw FormatException('$name.$key is not supported.');
    }
  }
  for (final field in fields) {
    if (!object.containsKey(field)) {
      throw FormatException('$name.$field is required.');
    }
  }
}

Object? _required(Map<String, Object?> object, String key, String name) {
  if (!object.containsKey(key)) {
    throw FormatException('$name.$key is required.');
  }
  return object[key];
}

String _readString(Object? json, String name) {
  if (json is! String) throw FormatException('$name must be a string.');
  return json;
}

int _readInt(Object? json, String name) {
  if (json is! int) throw FormatException('$name must be an integer.');
  return json;
}

void _requireNonBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be blank');
  }
}

void _requireNonBlankFormat(String value, String name) {
  if (value.trim().isEmpty) throw FormatException('$name must not be blank.');
}

bool _isBoundedNonBlankUtf8(String value, int maximumBytes) =>
    value.trim().isNotEmpty && !_exceedsUtf8ByteLimit(value, maximumBytes);

void _requireBoundedNonBlank(
  String value,
  String name,
  int maximumBytes,
) {
  if (!_isBoundedNonBlankUtf8(value, maximumBytes)) {
    throw ArgumentError.value(
      value,
      name,
      'must be nonblank and at most $maximumBytes UTF-8 bytes',
    );
  }
}

void _requireBoundedNonBlankFormat(
  String value,
  String name,
  int maximumBytes,
) {
  if (!_isBoundedNonBlankUtf8(value, maximumBytes)) {
    throw FormatException(
      '$name must be nonblank and at most $maximumBytes UTF-8 bytes.',
    );
  }
}
