import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'chat_deep_link.dart';
import 'core/attachment_upload_manager.dart';
import 'core/application_chat_storage.dart';
import 'core/command_dispatcher.dart';
import 'core/ephemeral_signal_state.dart';
import 'core/normalized_snapshot_state.dart';
import 'generated/attachment_transport.dart';
import 'generated/conversation.dart';
import 'generated/conversation_archive.dart';
import 'generated/conversation_creation.dart';
import 'generated/conversation_membership.dart';
import 'generated/conversation_preference.dart';
import 'generated/conversation_snapshot.dart';
import 'generated/delete_message.dart';
import 'generated/device_push_token.dart';
import 'generated/draft_mutation.dart';
import 'generated/durable_events.dart';
import 'generated/edit_message.dart';
import 'generated/ephemeral_signals.dart';
import 'generated/forward_message.dart';
import 'generated/huddle_session.dart';
import 'generated/identifiers.dart';
import 'generated/message.dart';
import 'generated/message_context.dart';
import 'generated/message_reminder.dart';
import 'generated/message_search.dart';
import 'generated/message_timeline.dart';
import 'generated/read_cursor_mutation.dart';
import 'generated/reaction_mutations.dart';
import 'generated/realtime_handshake.dart';
import 'generated/realtime_session.dart' show EventCursor;
import 'generated/reply_style_preference.dart';
import 'generated/send_message.dart';
import 'generated/thread_creation.dart';
import 'generated/thread_lifecycle.dart';
import 'generated/thread_list.dart';
import 'generated/thread_follow_mutation.dart';
import 'message_search.dart';
import 'realtime_session_transport.dart';

part 'core/conversation_snapshot_query.dart';
part 'core/attachment_download_query.dart';
part 'core/conversation_archive_command.dart';
part 'core/conversation_creation_command.dart';
part 'core/conversation_creation_recovery_runtime.dart';
part 'core/conversation_membership_command.dart';
part 'core/conversation_membership_recovery_runtime.dart';
part 'core/conversation_preference_command.dart';
part 'core/conversation_preference_recovery_runtime.dart';
part 'core/delete_message_command.dart';
part 'core/delete_message_recovery_runtime.dart';
part 'core/draft_runtime.dart';
part 'core/edit_message_command.dart';
part 'core/edit_message_recovery_runtime.dart';
part 'core/forward_message_command.dart';
part 'core/forward_message_recovery_runtime.dart';
part 'core/huddle_controller.dart';
part 'core/message_timeline_query.dart';
part 'core/message_context_controller.dart';
part 'core/message_reminder_command.dart';
part 'core/message_mutation_intent_storage_coordinator.dart';
part 'core/offline_send_message_queue.dart';
part 'core/push_token_runtime.dart';
part 'core/reaction_command.dart';
part 'core/read_cursor_runtime.dart';
part 'core/read_visibility_coordinator.dart';
part 'core/reply_style_runtime.dart';
part 'core/send_message_command.dart';
part 'core/unread_mention_refresh.dart';
part 'core/thread_opening_controller.dart';
part 'core/thread_lifecycle_controller.dart';
part 'core/thread_list_controller.dart';
part 'core/thread_follow_command.dart';

/// Current wire protocol spoken by the Dart client.
const int handrailChatProtocolVersion = 4;

/// Message shown when the server no longer supports this client's protocol.
const String handrailChatRefreshRequiredMessage =
    'Chat was updated; refresh to continue.';

const int _maximumMessageReminderRecoveryPages = 100;

/// Stable diagnostic codes emitted during client initialization.
abstract final class ChatClientDiagnosticCode {
  static const String accessTokenFailed = 'access_token_failed';
  static const String metadataRequestFailed = 'metadata_request_failed';
  static const String malformedMetadata = 'malformed_metadata';
  static const String normalizedSnapshotReadFailed =
      'normalized_snapshot_read_failed';
  static const String normalizedSnapshotRejected =
      'normalized_snapshot_rejected';
  static const String normalizedSnapshotQuarantineFailed =
      'normalized_snapshot_quarantine_failed';
  static const String normalizedSnapshotWriteFailed =
      'normalized_snapshot_write_failed';
  static const String draftIntentsReadFailed = 'draft_intents_read_failed';
  static const String draftIntentsRejected = 'draft_intents_rejected';
  static const String draftIntentsQuarantineFailed =
      'draft_intents_quarantine_failed';
  static const String messageMutationIntentsReadFailed =
      'message_mutation_intents_read_failed';
  static const String messageMutationIntentsRejected =
      'message_mutation_intents_rejected';
  static const String messageMutationIntentsQuarantineFailed =
      'message_mutation_intents_quarantine_failed';
  static const String messageMutationIntentsWriteFailed =
      'message_mutation_intents_write_failed';
  static const String membershipIntentsReadFailed =
      'membership_intents_read_failed';
  static const String membershipIntentsRejected = 'membership_intents_rejected';
  static const String membershipIntentsQuarantineFailed =
      'membership_intents_quarantine_failed';
  static const String membershipIntentsWriteFailed =
      'membership_intents_write_failed';
  static const String conversationCreationIntentsReadFailed =
      'conversation_creation_intents_read_failed';
  static const String conversationCreationIntentsRejected =
      'conversation_creation_intents_rejected';
  static const String conversationCreationIntentsQuarantineFailed =
      'conversation_creation_intents_quarantine_failed';
  static const String conversationCreationIntentsWriteFailed =
      'conversation_creation_intents_write_failed';
  static const String conversationPreferenceIntentsReadFailed =
      'conversation_preference_intents_read_failed';
  static const String conversationPreferenceIntentsRejected =
      'conversation_preference_intents_rejected';
  static const String conversationPreferenceIntentsQuarantineFailed =
      'conversation_preference_intents_quarantine_failed';
  static const String conversationPreferenceIntentsWriteFailed =
      'conversation_preference_intents_write_failed';
  static const String threadFollowIntentsReadFailed =
      'thread_follow_intents_read_failed';
  static const String threadFollowIntentsRejected =
      'thread_follow_intents_rejected';
  static const String threadFollowIntentsQuarantineFailed =
      'thread_follow_intents_quarantine_failed';
  static const String threadFollowIntentsWriteFailed =
      'thread_follow_intents_write_failed';
  static const String messageReminderIntentsReadFailed =
      'message_reminder_intents_read_failed';
  static const String messageReminderIntentsRejected =
      'message_reminder_intents_rejected';
  static const String messageReminderIntentsQuarantineFailed =
      'message_reminder_intents_quarantine_failed';
  static const String messageReminderIntentsWriteFailed =
      'message_reminder_intents_write_failed';
  static const String conversationArchiveIntentsReadFailed =
      'conversation_archive_intents_read_failed';
  static const String conversationArchiveIntentsRejected =
      'conversation_archive_intents_rejected';
  static const String conversationArchiveIntentsQuarantineFailed =
      'conversation_archive_intents_quarantine_failed';
  static const String conversationArchiveIntentsWriteFailed =
      'conversation_archive_intents_write_failed';
  static const String huddleIntentsReadFailed = 'huddle_intents_read_failed';
  static const String huddleIntentsRejected = 'huddle_intents_rejected';
  static const String huddleIntentsQuarantineFailed =
      'huddle_intents_quarantine_failed';
  static const String huddleIntentsWriteFailed = 'huddle_intents_write_failed';
}

/// Receives stable, credential-safe client diagnostics.
typedef ChatClientDiagnosticCallback = void Function(
  ChatClientDiagnostic diagnostic,
);

/// Resolves the access token immediately before an authenticated request.
typedef HandrailChatAccessTokenProvider = Future<String> Function();

/// A minimal, pure-Dart HTTP boundary supplied by the host application.
abstract interface class HandrailChatHttpTransport {
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request);
}

/// An immutable request passed to [HandrailChatHttpTransport].
final class HandrailChatHttpRequest {
  HandrailChatHttpRequest({
    required this.method,
    required this.uri,
    required Map<String, String> headers,
    this.body,
    this.cancellationSignal,
  }) : headers = Map<String, String>.unmodifiable(headers);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  /// Optional command cancellation signal supplied to cancellation-aware
  /// transports. Metadata bootstrap requests do not currently use one.
  final Object? cancellationSignal;

  @override
  String toString() => 'HandrailChatHttpRequest(method: $method, '
      'hasBody: ${body != null})';
}

/// A minimal immutable HTTP response.
final class HandrailChatHttpResponse {
  const HandrailChatHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;

  @override
  String toString() => 'HandrailChatHttpResponse(statusCode: $statusCode)';
}

/// A stable, token-safe initialization failure description.
final class ChatClientDiagnostic {
  const ChatClientDiagnostic({
    required this.code,
    required this.message,
    this.httpStatus,
  });

  final String code;
  final String message;
  final int? httpStatus;

  @override
  String toString() => httpStatus == null
      ? 'ChatClientDiagnostic(code: $code, message: $message)'
      : 'ChatClientDiagnostic(code: $code, message: $message, '
          'httpStatus: $httpStatus)';
}

/// An immutable state in the metadata-initialization lifecycle.
sealed class ChatClientLifecycleState {
  const ChatClientLifecycleState();

  String get state;

  @override
  String toString() => '$runtimeType(state: $state)';
}

final class ChatClientIdleState extends ChatClientLifecycleState {
  const ChatClientIdleState();

  @override
  String get state => 'idle';
}

final class ChatClientInitializingState extends ChatClientLifecycleState {
  const ChatClientInitializingState();

  @override
  String get state => 'initializing';
}

final class ChatClientReadyState extends ChatClientLifecycleState {
  ChatClientReadyState({
    required this.metadata,
    required Map<String, bool> negotiatedCapabilities,
  }) : negotiatedCapabilities =
            Map<String, bool>.unmodifiable(negotiatedCapabilities);

  @override
  String get state => 'ready';

  final ServerHandshakeMetadata metadata;
  final Map<String, bool> negotiatedCapabilities;
}

final class ChatClientRefreshRequiredState extends ChatClientLifecycleState {
  const ChatClientRefreshRequiredState({
    required this.metadata,
    this.reason = 'unsupportedProtocol',
    this.message = handrailChatRefreshRequiredMessage,
    this.requestedProtocolVersion = handrailChatProtocolVersion,
  });

  @override
  String get state => 'refreshRequired';

  final String reason;
  final String message;
  final int requestedProtocolVersion;
  final ServerHandshakeMetadata metadata;
}

final class ChatClientErrorState extends ChatClientLifecycleState {
  const ChatClientErrorState({required this.diagnostic});

  @override
  String get state => 'error';

  final ChatClientDiagnostic diagnostic;
}

/// Creates the rolling current-and-immediately-previous protocol window.
SupportedProtocolRange createSupportedProtocolRange(
  int currentProtocolVersion,
) {
  if (currentProtocolVersion < 1) {
    throw ArgumentError.value(
      currentProtocolVersion,
      'currentProtocolVersion',
      'must be positive',
    );
  }

  return SupportedProtocolRange(
    minimumVersion: currentProtocolVersion > 1
        ? currentProtocolVersion - 1
        : currentProtocolVersion,
    maximumVersion: currentProtocolVersion,
  );
}

/// Checks both endpoints of an advertised protocol range inclusively.
bool isProtocolSupported(
  int protocolVersion,
  SupportedProtocolRange supportedRange,
) =>
    protocolVersion >= supportedRange.minimumVersion &&
    protocolVersion <= supportedRange.maximumVersion;

/// The pure-Dart Handrail Chat client bootstrap.
///
/// No network work occurs until [initialize] is called. The supplied transport
/// keeps HTTP implementation details outside this package and deterministic in
/// tests.
final class HandrailChatClient {
  HandrailChatClient({
    required this.apiBaseUri,
    required this.tokenProvider,
    required this.transport,
    Map<String, bool> requestedCapabilities = const <String, bool>{},
    this.onSnapshotQueryDiagnostic,
    this.onStorageDiagnostic,
    ChatCommandRetryOptions commandRetryOptions =
        const ChatCommandRetryOptions(),
    ChatCommandDiagnosticCallback? onCommandDiagnostic,
    ChatClientMessageIdGenerator? generateClientMessageId,
    ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
    ChatForwardMessageCorrelationIdGenerator?
        generateForwardMessageCorrelationId,
    ChatForwardMessageClock? forwardMessageClock,
    ChatForwardMessageRetryBackoff? forwardMessageRetryBackoff,
    ChatForwardMessageRetryWait? forwardMessageRetryWait,
    ChatConversationClientRequestIdGenerator?
        generateConversationClientRequestId,
    ChatDraftDeviceMutationIdGenerator? generateDraftDeviceMutationId,
    ChatDraftMutationScheduler? draftMutationScheduler,
    Duration draftDebounce = Duration.zero,
    ChatReadVisibilityClock? readVisibilityClock,
    ChatReadVisibilityScheduler? readVisibilityScheduler,
    Duration readVisibilityMinimumExposure = const Duration(milliseconds: 500),
    Duration readVisibilityFailureRetryDelay = const Duration(seconds: 2),
    double readVisibilityRapidScrollVelocityThreshold = 1200,
    ChatConversationPreferenceClock? conversationPreferenceClock,
    ChatConversationPreferenceRetryBackoff? conversationPreferenceRetryBackoff,
    ChatConversationPreferenceRetryWait? conversationPreferenceRetryWait,
    ChatThreadFollowClock? threadFollowClock,
    ChatThreadFollowRetryBackoff? threadFollowRetryBackoff,
    ChatThreadFollowRetryWait? threadFollowRetryWait,
    ChatMessageReminderClock? messageReminderClock,
    ChatMessageReminderRetryBackoff? messageReminderRetryBackoff,
    ChatMessageReminderRetryWait? messageReminderRetryWait,
    ChatConversationArchiveClock? conversationArchiveClock,
    ChatConversationArchiveRetryBackoff? conversationArchiveRetryBackoff,
    ChatConversationArchiveRetryWait? conversationArchiveRetryWait,
    ChatAttachmentByteTransferTransport? attachmentTransferTransport,
    ChatAttachmentUploadOptions attachmentUploadOptions =
        const ChatAttachmentUploadOptions(),
    ChatAttachmentUploadIdGenerator? generateAttachmentUploadId,
    ChatAttachmentDownloadClock? attachmentDownloadClock,
    ApplicationChatStorage? localStorage,
    ApplicationChatStorageIdentity? storageIdentity,
    ChatOfflineSendClock? offlineSendClock,
    ChatOfflineSendRetryBackoff? offlineSendRetryBackoff,
    ChatOfflineSendRetryWait? offlineSendRetryWait,
    ChatReadCursorRetryBackoff? readCursorRetryBackoff,
    ChatReadCursorRetryWait? readCursorRetryWait,
    ChatRetainedDraftRetryBackoff? retainedDraftRetryBackoff,
    ChatRetainedDraftRetryWait? retainedDraftRetryWait,
    ChatMessageEditClock? messageEditClock,
    ChatMessageEditRetryBackoff? messageEditRetryBackoff,
    ChatMessageEditRetryWait? messageEditRetryWait,
    ChatMessageDeleteClock? messageDeleteClock,
    ChatMessageDeleteRetryBackoff? messageDeleteRetryBackoff,
    ChatMessageDeleteRetryWait? messageDeleteRetryWait,
    ChatConversationMembershipClock? conversationMembershipClock,
    ChatConversationMembershipRetryBackoff? conversationMembershipRetryBackoff,
    ChatConversationMembershipRetryWait? conversationMembershipRetryWait,
    ChatConversationCreationClock? conversationCreationClock,
    ChatConversationCreationRetryBackoff? conversationCreationRetryBackoff,
    ChatConversationCreationRetryWait? conversationCreationRetryWait,
    ChatReactionClock? reactionClock,
    ChatReactionRetryBackoff? reactionRetryBackoff,
    ChatReactionRetryWait? reactionRetryWait,
    ChatHuddleClock? huddleClock,
    ChatHuddleTimerScheduler? huddleTimerScheduler,
    ChatHuddleRetryBackoff? huddleRetryBackoff,
    ChatHuddleRetryWait? huddleRetryWait,
    NormalizedSnapshotStore? normalizedSnapshotStore,
    EphemeralSignalStore? ephemeralSignalStore,
    this.realtimeSession,
    ChatReplyStyleConfiguration replyStyleConfiguration =
        const ChatReplyStyleConfiguration(),
    ChatReplyStyleIdentity? replyStyleIdentity,
  }) : requestedCapabilities = _copyRequestedCapabilities(
          requestedCapabilities,
        ) {
    normalizedState = normalizedSnapshotStore ?? NormalizedSnapshotStore();
    _ownsNormalizedState = normalizedSnapshotStore == null;
    ephemeralSignals = ephemeralSignalStore ?? EphemeralSignalStore();
    _ownsEphemeralSignals = ephemeralSignalStore == null;
    _generateClientMessageId =
        generateClientMessageId ?? _generateSecureClientMessageId;
    _generateCommandIdempotencyKey =
        generateIdempotencyKey ?? _generateSecureCommandIdempotencyKey;
    _generateForwardMessageCorrelationId =
        generateForwardMessageCorrelationId ??
            _generateSecureForwardMessageCorrelationId;
    _generateConversationClientRequestId =
        generateConversationClientRequestId ??
            _generateSecureConversationClientRequestId;
    _conversationPreferenceClock =
        conversationPreferenceClock ?? _currentConversationPreferenceTime;
    _attachmentDownloadClock =
        attachmentDownloadClock ?? _currentAttachmentDownloadTime;
    if (storageIdentity != null && localStorage == null) {
      throw ArgumentError(
        'storageIdentity requires an ApplicationChatStorage.',
      );
    }
    _localStorage = localStorage;
    _forwardIdentity = storageIdentity;
    if (localStorage != null) {
      _offlineSendQueue = _OfflineSendMessageQueue(
        storage: localStorage,
        initialIdentity: storageIdentity,
        clock: offlineSendClock ?? DateTime.now,
      );
    }
    _states = _createStateStream();
    _snapshotQueries = _ConversationSnapshotQueryReader(
      apiBaseUri: apiBaseUri,
      tokenProvider: tokenProvider,
      transport: transport,
      onDiagnostic: onSnapshotQueryDiagnostic,
    );
    _commandDispatcher = ChatCommandDispatcher(
      apiBaseUri: apiBaseUri,
      tokenProvider: tokenProvider,
      transport: transport,
      retryOptions: commandRetryOptions,
      onDiagnostic: onCommandDiagnostic,
    );
    if (localStorage != null) {
      final messageMutationStorageCoordinator =
          _MessageMutationIntentStorageCoordinator();
      _forwardMessageRuntime = _ForwardMessageRecoveryRuntime(
        storage: localStorage,
        storageCoordinator: messageMutationStorageCoordinator,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateCorrelationId: _generateForwardMessageCorrelationId,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
        clock: forwardMessageClock ?? DateTime.now,
        backoff:
            forwardMessageRetryBackoff ?? _defaultForwardMessageRetryBackoff,
        wait: forwardMessageRetryWait ?? _defaultForwardMessageRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _messageEditRuntime = _MessageEditRecoveryRuntime(
        storage: localStorage,
        storageCoordinator: messageMutationStorageCoordinator,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        clock: messageEditClock ?? DateTime.now,
        backoff: messageEditRetryBackoff ?? _defaultMessageEditRetryBackoff,
        wait: messageEditRetryWait ?? _defaultMessageEditRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _messageDeleteRuntime = _MessageDeleteRecoveryRuntime(
        storage: localStorage,
        storageCoordinator: messageMutationStorageCoordinator,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        clock: messageDeleteClock ?? DateTime.now,
        backoff: messageDeleteRetryBackoff ?? _defaultMessageDeleteRetryBackoff,
        wait: messageDeleteRetryWait ?? _defaultMessageDeleteRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _reactionRuntime = _ReactionRecoveryRuntime(
        storage: localStorage,
        storageCoordinator: messageMutationStorageCoordinator,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        clock: reactionClock ?? DateTime.now,
        backoff: reactionRetryBackoff ?? _defaultReactionRetryBackoff,
        wait: reactionRetryWait ?? _defaultReactionRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _conversationMembershipRuntime = _ConversationMembershipRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        refreshAuthority: _refreshConversationMembershipAuthority,
        clearConversationSubscription:
            realtimeSession?.clearConversationSubscription,
        clock: conversationMembershipClock ?? DateTime.now,
        backoff: conversationMembershipRetryBackoff ??
            _defaultConversationMembershipRetryBackoff,
        wait: conversationMembershipRetryWait ??
            _defaultConversationMembershipRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _conversationCreationRuntime = _ConversationCreationRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
        generateClientRequestId: _generateConversationClientRequestId,
        clock: conversationCreationClock ?? DateTime.now,
        backoff: conversationCreationRetryBackoff ??
            _defaultConversationCreationRetryBackoff,
        wait: conversationCreationRetryWait ??
            _defaultConversationCreationRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _conversationPreferenceRuntime = _ConversationPreferenceRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        clock: _conversationPreferenceClock,
        backoff: conversationPreferenceRetryBackoff ??
            _defaultConversationPreferenceRetryBackoff,
        wait: conversationPreferenceRetryWait ??
            _defaultConversationPreferenceRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _threadFollowRecoveryRuntime = _ThreadFollowRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
        clock: threadFollowClock ?? _currentThreadFollowTime,
        backoff: threadFollowRetryBackoff ?? _defaultThreadFollowRetryBackoff,
        wait: threadFollowRetryWait ?? _defaultThreadFollowRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _messageReminderRecoveryRuntime = _MessageReminderRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
        clock: messageReminderClock ?? _currentMessageReminderTime,
        backoff:
            messageReminderRetryBackoff ?? _defaultMessageReminderRetryBackoff,
        wait: messageReminderRetryWait ?? _defaultMessageReminderRetryWait,
        refreshAuthority: _refreshMessageReminderAuthority,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
      _conversationArchiveRecoveryRuntime = _ConversationArchiveRecoveryRuntime(
        storage: localStorage,
        dispatcher: _commandDispatcher,
        store: normalizedState,
        clock: conversationArchiveClock ?? _currentConversationArchiveTime,
        backoff: conversationArchiveRetryBackoff ??
            _defaultConversationArchiveRetryBackoff,
        wait: conversationArchiveRetryWait ??
            _defaultConversationArchiveRetryWait,
        lifecycleManaged: realtimeSession != null,
        onStorageDiagnostic: _reportStorageDiagnostic,
      );
    }
    final configuredOfflineSendQueue = _offlineSendQueue;
    if (configuredOfflineSendQueue != null && realtimeSession != null) {
      _offlineSendPump = _OfflineSendMessagePump(
        queue: configuredOfflineSendQueue,
        dispatcher: _commandDispatcher,
        normalizedState: normalizedState,
        backoff: offlineSendRetryBackoff ?? _defaultOfflineSendRetryBackoff,
        wait: offlineSendRetryWait ?? _defaultOfflineSendRetryWait,
      );
    }
    if (localStorage == null) {
      _immediateThreadFollowRuntime = _ImmediateThreadFollowRuntime(
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
        clock: threadFollowClock ?? _currentThreadFollowTime,
      );
      _immediateMessageReminderRuntime = _ImmediateMessageReminderRuntime(
        dispatcher: _commandDispatcher,
        store: normalizedState,
        generateIdempotencyKey: _generateCommandIdempotencyKey,
      );
    }
    if (localStorage != null) {
      _pushTokenRuntime = _PushTokenRuntime(
        storage: localStorage,
        initialIdentity: storageIdentity,
        dispatcher: _commandDispatcher,
      );
    }
    if (attachmentTransferTransport != null) {
      _attachmentUploadManager = ChatAttachmentUploadManager(
        commandDispatcher: _commandDispatcher,
        normalizedState: normalizedState,
        transferTransport: attachmentTransferTransport,
        generateUploadId: generateAttachmentUploadId ??
            () => _generateSecureIdentifier('upload'),
        generateIdempotencyKey: (phase, _) =>
            _generateSecureIdentifier('attachment-${phase.name}'),
        options: attachmentUploadOptions,
      );
    }
    _readCursorRuntime = _ReadCursorRuntime(
      store: normalizedState,
      dispatcher: _commandDispatcher,
      generateIdempotencyKey: _generateCommandIdempotencyKey,
      storage: localStorage,
      initialIdentity: storageIdentity,
      // Prime authored read validation synchronously, but do not load retained
      // work until normalized snapshot hydration has settled.
      deferInitialRetainedLoad: localStorage != null,
      retryBackoff: readCursorRetryBackoff,
      retryWait: readCursorRetryWait,
      lifecycleManaged: localStorage != null && realtimeSession != null,
    );
    reads = ChatReadVisibilityCoordinator(
      markRead: _readCursorRuntime.markRead,
      minimumExposure: readVisibilityMinimumExposure,
      failureRetryDelay: readVisibilityFailureRetryDelay,
      rapidScrollVelocityThreshold: readVisibilityRapidScrollVelocityThreshold,
      clock: readVisibilityClock,
      scheduler: readVisibilityScheduler,
      generateIdempotencyKey: _generateCommandIdempotencyKey,
    );
    _draftRuntime = _DraftRuntime(
      dispatcher: _commandDispatcher,
      generateDeviceMutationId:
          generateDraftDeviceMutationId ?? _generateSecureDraftMutationId,
      generateIdempotencyKey: _generateCommandIdempotencyKey,
      scheduler: draftMutationScheduler ?? const _DartDraftMutationScheduler(),
      debounce: draftDebounce,
      storage: localStorage,
      store: normalizedState,
      initialIdentity: storageIdentity,
      retainedRetryBackoff: retainedDraftRetryBackoff,
      retainedRetryWait: retainedDraftRetryWait,
      lifecycleManaged: localStorage != null && realtimeSession != null,
      onStorageDiagnostic: _reportStorageDiagnostic,
    );
    replyStyles = ChatReplyStyleRuntime._(
      this,
      replyStyleConfiguration,
      replyStyleIdentity ??
          (storageIdentity == null
              ? null
              : ChatReplyStyleIdentity(
                  tenantId: storageIdentity.tenantId,
                  userId: storageIdentity.userId,
                )),
    );
    threadLifecycles = ChatThreadLifecyclesController._(this);
    threadLists = ChatThreadListsController._(this);
    messageContexts = ChatMessageContextsController._(this);
    threads = ChatThreadsController._(
      snapshotQueries: _snapshotQueries,
      commandDispatcher: _commandDispatcher,
      normalizedState: normalizedState,
      generateIdempotencyKey: _generateCommandIdempotencyKey,
      subscribeConversation: realtimeSession?.subscribeConversation,
      followThread: _threadFollowRecoveryRuntime?.follow ??
          _immediateThreadFollowRuntime!.follow,
      unfollowThread: _threadFollowRecoveryRuntime?.unfollow ??
          _immediateThreadFollowRuntime!.unfollow,
    );
    huddles = ChatHuddlesController._(
      apiBaseUri: apiBaseUri,
      tokenProvider: tokenProvider,
      transport: transport,
      commandDispatcher: _commandDispatcher,
      generateIdempotencyKey: _generateCommandIdempotencyKey,
      isFeatureEnabled: _huddlesFeatureEnabled,
      subscribeConversation: realtimeSession?.subscribeConversation,
      clock: huddleClock ?? _currentHuddleTime,
      scheduleTimer: huddleTimerScheduler ?? _scheduleHuddleTimer,
      storage: localStorage,
      normalizedState: normalizedState,
      retryBackoff: huddleRetryBackoff ?? _defaultHuddleRetryBackoff,
      retryWait: huddleRetryWait ?? _defaultHuddleRetryWait,
      lifecycleManaged: localStorage != null && realtimeSession != null,
      onStorageDiagnostic: _reportStorageDiagnostic,
    );
    _unreadMentionRefresh = _UnreadMentionRefreshCoordinator(this);
    final configuredRealtimeSession = realtimeSession;
    if (configuredRealtimeSession != null) {
      _realtimeDurableStateBindingRelease =
          configuredRealtimeSession.bindDurableState(
        reduceDurableEvent: _reduceRealtimeDurableEvent,
        hydrateSnapshot: _hydrateRealtimeSnapshots,
      );
      _realtimeStorageIdentitySubscription =
          configuredRealtimeSession.states.listen((state) {
        replyStyles._realtime(state);
        if (state case ChatRealtimeConnectedState(:final identity)) {
          unawaited(_activateRealtimeStorageIdentity(identity));
          return;
        }
        _updateDurablePumpReadiness();
      });
    }
    if (localStorage != null && configuredRealtimeSession != null) {
      _realtimeCanonicalEventSubscription =
          configuredRealtimeSession.canonicalEvents.listen((event) {
        unawaited(_offlineSendPump?.settleCanonicalEvent(event));
        unawaited(_threadFollowRecoveryRuntime?.settleCanonicalEvent(event));
        unawaited(
          _conversationArchiveRecoveryRuntime?.settleCanonicalEvent(event),
        );
      });
    }
    if (storageIdentity != null) {
      // Begin application-owned I/O without waiting for network bootstrap.
      // The cached operation is awaited by initialize and repeated activation.
      unawaited(
        _activateTrustedStorageIdentity(storageIdentity).catchError((_) {
          _updateDurablePumpReadiness(realtimeIdentityReady: false);
        }),
      );
    }
  }

  final Uri apiBaseUri;
  final HandrailChatAccessTokenProvider tokenProvider;
  final HandrailChatHttpTransport transport;
  final Map<String, bool> requestedCapabilities;
  final ChatSnapshotQueryDiagnosticCallback? onSnapshotQueryDiagnostic;
  final ChatClientDiagnosticCallback? onStorageDiagnostic;
  final ChatRealtimeSessionTransport? realtimeSession;
  late final NormalizedSnapshotStore normalizedState;
  late final EphemeralSignalStore ephemeralSignals;

  /// Saved reply style and host policy, independent of message composition.
  late final ChatReplyStyleRuntime replyStyles;

  late final ChatThreadsController threads;
  late final ChatThreadLifecyclesController threadLifecycles;
  late final ChatThreadListsController threadLists;
  late final ChatMessageContextsController messageContexts;
  late final ChatHuddlesController huddles;

  /// Read visibility reporting for framework-owned and custom timelines.
  late final ChatReadVisibilityCoordinator reads;

  final StreamController<ChatClientLifecycleState> _stateChanges =
      StreamController<ChatClientLifecycleState>.broadcast(sync: true);
  ChatClientLifecycleState _state = const ChatClientIdleState();
  Future<ChatClientLifecycleState>? _initialization;
  late final Stream<ChatClientLifecycleState> _states;
  late final _ConversationSnapshotQueryReader _snapshotQueries;
  late final ChatCommandDispatcher _commandDispatcher;
  ChatAttachmentUploadManager? _attachmentUploadManager;
  late final _DraftRuntime _draftRuntime;
  late final _ReadCursorRuntime _readCursorRuntime;
  _ThreadFollowRecoveryRuntime? _threadFollowRecoveryRuntime;
  _ImmediateThreadFollowRuntime? _immediateThreadFollowRuntime;
  _MessageReminderRecoveryRuntime? _messageReminderRecoveryRuntime;
  _ImmediateMessageReminderRuntime? _immediateMessageReminderRuntime;
  _ConversationArchiveRecoveryRuntime? _conversationArchiveRecoveryRuntime;
  late final ChatClientMessageIdGenerator _generateClientMessageId;
  late final ChatCommandIdempotencyKeyGenerator _generateCommandIdempotencyKey;
  late final ChatForwardMessageCorrelationIdGenerator
      _generateForwardMessageCorrelationId;
  late final ChatConversationClientRequestIdGenerator
      _generateConversationClientRequestId;
  late final ChatConversationPreferenceClock _conversationPreferenceClock;
  late final ChatAttachmentDownloadClock _attachmentDownloadClock;
  late final ApplicationChatStorage? _localStorage;
  _OfflineSendMessageQueue? _offlineSendQueue;
  _OfflineSendMessagePump? _offlineSendPump;
  _PushTokenRuntime? _pushTokenRuntime;
  _ForwardMessageRecoveryRuntime? _forwardMessageRuntime;
  _MessageEditRecoveryRuntime? _messageEditRuntime;
  _MessageDeleteRecoveryRuntime? _messageDeleteRuntime;
  _ReactionRecoveryRuntime? _reactionRuntime;
  _ConversationMembershipRecoveryRuntime? _conversationMembershipRuntime;
  _ConversationCreationRecoveryRuntime? _conversationCreationRuntime;
  _ConversationPreferenceRecoveryRuntime? _conversationPreferenceRuntime;
  StreamSubscription<ChatRealtimeLifecycleState>?
      _realtimeStorageIdentitySubscription;
  StreamSubscription<KnownDurableEvent>? _realtimeCanonicalEventSubscription;
  StreamSubscription<NormalizedSnapshotState>?
      _normalizedSnapshotCommitSubscription;
  ChatRealtimeDurableStateBindingRelease? _realtimeDurableStateBindingRelease;
  late final bool _ownsNormalizedState;
  late final bool _ownsEphemeralSignals;
  final Map<String, Future<Object>> _conversationCreationOperations = {};
  final Map<ConversationId, _ConversationArchiveCommandLane>
      _conversationArchiveCommandLanes = {};
  final Set<Future<void>> _conversationArchiveCommandDrains = {};
  final Map<ConversationId, _ConversationMembershipCommandLane>
      _conversationMembershipCommandLanes = {};
  final Set<Future<void>> _conversationMembershipCommandDrains = {};
  final Map<ConversationId, _ConversationPreferenceCommandLane>
      _conversationPreferenceCommandLanes = {};
  final Set<Future<void>> _conversationPreferenceCommandDrains = {};
  final Map<String, _ReactionCommandLane> _reactionCommandLanes = {};
  final Set<Future<void>> _reactionCommandDrains = {};
  final Set<_PendingForwardMessageCorrelation>
      _pendingForwardMessageCorrelations =
      <_PendingForwardMessageCorrelation>{};
  ApplicationChatStorageIdentity? _forwardIdentity;
  ApplicationChatStorageIdentity? _storageActivationIdentity;
  ApplicationChatStorageIdentity? _installedSnapshotIdentity;
  Future<void>? _storageActivation;
  _NormalizedSnapshotCheckpoint? _pendingNormalizedSnapshotCheckpoint;
  _NormalizedSnapshotCheckpointBaseline? _normalizedSnapshotCheckpointBaseline;
  bool _normalizedSnapshotCheckpointDraining = false;
  int _storageIdentityGeneration = 0;
  bool _applicationForeground = true;
  late final _UnreadMentionRefreshCoordinator _unreadMentionRefresh;
  bool _disposed = false;

  ChatClientLifecycleState get state => _state;

  /// A broadcast stream that gives each listener the current state first.
  Stream<ChatClientLifecycleState> get states => _states;

  /// Current durable optimistic sends in deterministic FIFO order.
  List<ChatQueuedSendMessage> get queuedSendMessages =>
      _offlineSendQueue?.state.intents ?? const <ChatQueuedSendMessage>[];

  /// Current identity-scoped durable edits, including recovery conflicts.
  List<ChatQueuedMessageEdit> get queuedMessageEdits =>
      _messageEditRuntime?.edits ?? const <ChatQueuedMessageEdit>[];

  /// Current identity-scoped durable deletes awaiting canonical settlement.
  List<ChatQueuedMessageDelete> get queuedMessageDeletes =>
      _messageDeleteRuntime?.deletes ?? const <ChatQueuedMessageDelete>[];

  /// Current identity-scoped durable membership commands in global FIFO order.
  List<ChatQueuedConversationMembership> get queuedConversationMemberships =>
      _conversationMembershipRuntime?.intents ??
      const <ChatQueuedConversationMembership>[];

  /// Current identity-scoped durable conversation creations in FIFO order.
  List<ChatQueuedConversationCreation> get queuedConversationCreations =>
      _conversationCreationRuntime?.intents ??
      const <ChatQueuedConversationCreation>[];

  /// Current identity-scoped durable preference commands and conflicts.
  List<ChatQueuedConversationPreference> get queuedConversationPreferences =>
      _conversationPreferenceRuntime?.intents ??
      const <ChatQueuedConversationPreference>[];

  /// Current identity-scoped durable thread-follow command and conflict state.
  List<ChatQueuedThreadFollow> get queuedThreadFollows =>
      _threadFollowRecoveryRuntime?.intents ?? const <ChatQueuedThreadFollow>[];

  /// Current identity-scoped durable reminder commands and conflicts.
  List<ChatQueuedMessageReminder> get queuedMessageReminders =>
      _messageReminderRecoveryRuntime?.intents ??
      const <ChatQueuedMessageReminder>[];

  /// Current identity-scoped durable archive commands and lifecycle conflicts.
  List<ChatQueuedConversationArchive> get queuedConversationArchives =>
      _conversationArchiveRecoveryRuntime?.intents ??
      const <ChatQueuedConversationArchive>[];

  /// Current identity-scoped durable huddle commands and conflicts.
  List<ChatQueuedHuddleCommand> get queuedHuddleCommands =>
      huddles.queuedCommands;

  /// Current-first, framework-neutral durable optimistic send state.
  Stream<ChatOfflineSendQueueState> get queuedSendMessageStates =>
      _offlineSendQueue?.states ??
      Stream<ChatOfflineSendQueueState>.value(
        const ChatOfflineSendQueueState.unconfigured(),
      );

  /// Gates lifecycle-sensitive durable dispatch without mutating state.
  ///
  /// Flutter bindings set this to `false` before suspending realtime and only
  /// restore it after realtime recovery reaches connected readiness. Replay
  /// cursors, queued send/read intents, normalized state, and read state are
  /// untouched.
  void setApplicationForeground(bool foreground) {
    if (_disposed || _applicationForeground == foreground) return;
    _applicationForeground = foreground;
    _updateDurablePumpReadiness();
  }

  /// Activates a trusted tenant/user/device scope and rehydrates its queues.
  ///
  /// Repeated activation of the same identity is idempotent. This is suitable
  /// for use from an accepted realtime-session identity callback.
  Future<void> activateStorageIdentity(
    ApplicationChatStorageIdentity identity,
  ) async {
    if (_disposed) {
      throw StateError('The Handrail chat client has been disposed.');
    }
    if (_offlineSendQueue == null) {
      throw StateError('No ApplicationChatStorage was configured.');
    }
    await _activateTrustedStorageIdentity(identity);
  }

  /// Registers an opaque provider push token for the trusted active device.
  Future<ChatCommandResult<DevicePushTokenResult>> registerPushToken(
    RegisterDevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _pushTokenRuntime?.execute(input,
          cancellationSignal: cancellationSignal) ??
      Future.value(const ChatCommandValidationFailure<DevicePushTokenResult>());

  /// Refreshes the opaque provider push token for the trusted active device.
  Future<ChatCommandResult<DevicePushTokenResult>> refreshPushToken(
    RefreshDevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _pushTokenRuntime?.execute(input,
          cancellationSignal: cancellationSignal) ??
      Future.value(const ChatCommandValidationFailure<DevicePushTokenResult>());

  /// Unregisters the current push token while retaining its canonical revision.
  Future<ChatCommandResult<DevicePushTokenResult>> unregisterPushToken(
    UnregisterDevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _pushTokenRuntime?.execute(input,
          cancellationSignal: cancellationSignal) ??
      Future.value(const ChatCommandValidationFailure<DevicePushTokenResult>());

  /// Applies host-reported token rotation as unregister-then-register.
  Future<ChatCommandResult<ChatPushTokenRotationResult>> rotatePushToken({
    required UnregisterDevicePushTokenInput unregister,
    required RegisterDevicePushTokenInput replacement,
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _pushTokenRuntime?.rotate(
        unregister: unregister,
        replacement: replacement,
        cancellationSignal: cancellationSignal,
      ) ??
      Future.value(
        const ChatCommandValidationFailure<ChatPushTokenRotationResult>(),
      );

  /// Unregisters during account logout, then removes only the local revision.
  Future<ChatCommandResult<DevicePushTokenResult>> unregisterPushTokenForLogout(
    UnregisterDevicePushTokenInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _pushTokenRuntime?.logout(
        input,
        cancellationSignal: cancellationSignal,
      ) ??
      Future.value(
        const ChatCommandValidationFailure<DevicePushTokenResult>(),
      );

  /// Removes one persisted send intent and its optimistic projection.
  Future<bool> cancelQueuedSendMessage(String clientMessageId) async {
    if (_disposed) return false;
    final queue = _offlineSendQueue;
    if (queue == null) return false;
    return queue.cancel(clientMessageId);
  }

  /// Starts one provider-neutral attachment upload.
  ///
  /// An attachment byte-transfer transport must have been supplied to the
  /// constructor. The transfer boundary never receives chat authorization.
  ChatAttachmentUploadHandle uploadAttachment(
    ChatAttachmentUploadInput input,
  ) {
    if (_disposed) {
      throw StateError('The Handrail chat client has been disposed.');
    }
    final manager = _attachmentUploadManager;
    if (manager == null) {
      throw StateError(
        'No attachment byte-transfer transport was configured.',
      );
    }
    return manager.upload(input);
  }

  /// Creates a named root thread; retry through `threads.forRoot(id).retry()`.
  Future<ChatThreadOpenResult> createThread({
    required MessageId rootMessageId,
    required String name,
    bool? initialFollow,
  }) =>
      threads.create(
        rootMessageId: rootMessageId,
        name: name,
        initialFollow: initialFollow,
      );

  /// Opens authorized history without creation, follow, or lifecycle writes.
  Future<ChatExistingThreadOpenResult> openExistingThread(
    ConversationId threadId,
  ) =>
      threads.openExistingThread(threadId);

  /// Fetches one validated conversation snapshot page without caching or
  /// automatic pagination.
  Future<ChatSnapshotQueryResult<ConversationListSnapshot>> listConversations(
    ConversationListSnapshotInput input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
      _snapshotQueries.listConversations(input, options: options);

  /// Fetches one validated conversation detail snapshot without caching.
  Future<ChatSnapshotQueryResult<ConversationDetailSnapshot>> getConversation(
    ConversationDetailSnapshotInput input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
      _snapshotQueries.getConversation(input, options: options);

  /// Fetches one validated message timeline page without caching or automatic
  /// pagination.
  Future<ChatSnapshotQueryResult<MessageTimelinePage>> getMessageTimeline(
    MessageTimelineRequest input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
      _snapshotQueries.getMessageTimeline(input, options: options);

  /// Fetches one validated page of the trusted actor's active reminders.
  Future<ChatSnapshotQueryResult<MessageReminderListSnapshot>>
      listMessageReminders(
    MessageReminderListSnapshotInput input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
          _snapshotQueries.listMessageReminders(input, options: options);

  /// Searches the authorized server index without caching hits or snippets.
  ///
  /// Request filters and cursors are validated by the generated contract.
  /// Hit-type flags are applied after decoding because they are UI semantics,
  /// not fields in the HTTP contract.
  Future<ChatSnapshotQueryResult<HandrailMessageSearchPage>> searchMessages(
    HandrailMessageSearchRequest input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
      _snapshotQueries.searchMessages(input, options: options);

  /// Resolves one short-lived opaque attachment download descriptor.
  ///
  /// The client validates the descriptor's attachment, message, lifecycle,
  /// kind, and expiry binding. It does not fetch bytes or follow provider
  /// instructions.
  Future<ChatSnapshotQueryResult<GetAttachmentDownloadResult>>
      getAttachmentDownload(
    GetAttachmentDownloadInput input, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) =>
          _snapshotQueries.getAttachmentDownload(
            input,
            options: options,
            clock: _attachmentDownloadClock,
          );

  /// Advances the current user's cursor through one conversation sequence.
  ///
  /// Synchronous forward advances coalesce to the highest sequence, publish
  /// optimistically, and share one retry-stable wire intent.
  Future<ChatCommandResult<ReadCursorMutationResult>> markRead(
    ChatMarkReadInput input,
  ) =>
      _readCursorRuntime.markRead(input);

  /// Marks an already-read sequence and everything after it unread.
  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    ChatMarkUnreadInput input,
  ) =>
      _readCursorRuntime.markUnread(input);

  /// Reconciles a generated private read-cursor event.
  ///
  /// Returns false for stale events or events that do not describe the
  /// normalized current user and conversation.
  bool reconcileReadCursorEvent(ReadCursorUpdatedEvent event) =>
      _readCursorRuntime.reconcileEvent(event);

  /// Returns the synchronous latest-local draft projection, when known.
  ChatDraftProjection? draftFor(ConversationId conversationId) =>
      _draftRuntime.draftFor(conversationId);

  /// Restores the authenticated actor's server-saved draft. Newer canonical
  /// revisions and pending local edits take precedence over a late snapshot.
  Future<ChatSnapshotQueryResult<ChatDraftProjection>> loadDraft(
    ConversationId conversationId, {
    ChatSnapshotQueryOptions options = const ChatSnapshotQueryOptions(),
  }) async {
    final generation = _storageIdentityGeneration;
    final result = await _snapshotQueries.getConversationDraft(
      conversationId,
      options: options,
    );
    if (_disposed || generation != _storageIdentityGeneration) {
      return const ChatSnapshotQueryAborted<ChatDraftProjection>();
    }
    if (result case ChatSnapshotQuerySuccess(:final value)) {
      _draftRuntime.hydrate(value);
    }
    return result;
  }

  /// Returns a current-first, framework-neutral stream for one draft.
  Stream<ChatDraftProjection?> draftStatesFor(
    ConversationId conversationId,
  ) =>
      _draftRuntime.statesFor(conversationId);

  /// Schedules one replace or clear draft mutation.
  ///
  /// Each logical mutation owns stable device and idempotency identities.
  /// Mutations serialize per conversation and unrelated conversations remain
  /// independent.
  Future<ChatCommandResult<SynchronizeDraftResult>> synchronizeDraft(
    ChatSynchronizeDraftInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _draftRuntime
          .synchronize(
            input,
            cancellationSignal: cancellationSignal,
          )
          .remoteSettlement;

  /// Schedules one draft mutation with separate local and remote completion.
  ///
  /// Uses the same validation, storage record, stable mutation identities, and
  /// remote dispatch as [synchronizeDraft]. Await the returned handle's
  /// [ChatDraftSynchronization.localPersistence] for a typed local outcome;
  /// only [ChatDraftLocallyPersisted] acknowledges verified local persistence
  /// under the still-current storage identity, never server acceptance.
  /// [ChatDraftNotPersisted] explains why durability cannot be claimed.
  /// The same handle's [ChatDraftSynchronization.remoteSettlement] preserves
  /// the existing command result behavior and may remain pending offline.
  ChatDraftSynchronization synchronizeDraftWithLocalPersistence(
    ChatSynchronizeDraftInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) =>
      _draftRuntime.synchronize(
        input,
        cancellationSignal: cancellationSignal,
      );

  /// Accepts a generated private durable draft event when it is canonical and
  /// at least as fresh as the latest accepted revision and timestamp.
  bool reconcileDraftEvent(ConversationDraftUpdatedEvent event) =>
      _draftRuntime.reconcileEvent(event);

  /// Discards one explicitly conflicted retained local draft and restores the
  /// authoritative server projection.
  Future<bool> discardRetainedDraftConflict(ConversationId conversationId) =>
      _draftRuntime.discardConflict(conversationId);

  /// Reduces one already-authenticated transient realtime signal.
  bool applyEphemeralSignal(EphemeralSignalEvent event) =>
      ephemeralSignals.apply(event);

  /// Starts or refreshes the current actor's typing signal.
  bool startTyping(
    ConversationId conversationId, {
    ChatRealtimeConversationVisibility? visibility,
  }) =>
      realtimeSession?.startTyping(
        conversationId,
        visibility: visibility,
      ) ??
      false;

  /// Stops the current actor's typing signal for one conversation.
  void stopTyping(ConversationId conversationId) =>
      realtimeSession?.stopTyping(conversationId);

  /// Updates the desired presence state on the shared realtime session.
  void setPresence(PresenceSignalState presence) =>
      realtimeSession?.setPresence(presence);

  /// Reports current-user activity to the presence runtime.
  void notifyActivity() => realtimeSession?.notifyActivity();

  /// Atomically reduces one known durable event into normalized state.
  ///
  /// Private read and draft projections settle through their existing
  /// revision-aware runtimes only after the normalized commit succeeds.
  /// Current-user access loss also clears retained realtime subscription
  /// intent so reconnect cannot replay the inaccessible conversation stream.
  DurableEventReduction reduceDurableEvent(KnownDurableEvent event) {
    if (event is ReplyStyleUpdatedDurableEvent) return replyStyles._event(event);
    final reduction = normalizedState.reduceDurableEvent(
      event,
      onReadCursorUpdated: _readCursorRuntime.reconcileEvent,
      onDraftUpdated: _draftRuntime.reconcileEvent,
      onHuddleUpdated: huddles.reconcileCanonicalState,
      onConversationAccessRevoked: (id) {
        threadLifecycles._revoke(id);
        threadLists._revoke(id);
        messageContexts._revoke(id);
        realtimeSession?.clearConversationSubscription(id);
      },
    );
    if (reduction.status == DurableEventReductionStatus.applied &&
        (event is MessageCreatedDurableEvent ||
            event is MessageUpdatedDurableEvent ||
            event is MessageDeletedDurableEvent ||
            event is ReadCursorUpdatedDurableEvent)) {
      final id = event is ReadCursorUpdatedDurableEvent
          ? ConversationId.fromJson(event.payload.data['conversationId'])
          : Message.fromJson(event.payload.data['message']).conversationId;
      _unreadMentionRefresh.request(id);
    }
    if (reduction.status == DurableEventReductionStatus.applied) {
      threadLists._event(event);
      messageContexts._event(event);
    }
    unawaited(_messageEditRuntime?.settleCanonicalEvent(event));
    unawaited(_messageDeleteRuntime?.settleCanonicalEvent(event));
    unawaited(_reactionRuntime?.settleCanonicalEvent(event));
    unawaited(_forwardMessageRuntime?.settleCanonicalEvent(event));
    unawaited(_conversationMembershipRuntime?.settleCanonicalEvent(event));
    unawaited(_conversationCreationRuntime?.settleCanonicalEvent(event));
    unawaited(_conversationPreferenceRuntime?.settleCanonicalEvent(event));
    unawaited(_threadFollowRecoveryRuntime?.settleCanonicalEvent(event));
    unawaited(_conversationArchiveRecoveryRuntime?.settleCanonicalEvent(event));
    return reduction;
  }

  Future<EventCursor?> _hydrateRealtimeSnapshots(
    ChatRealtimeSnapshotHydrationInput input,
  ) async {
    _unreadMentionRefresh.pause();
    try {
      EventCursor? cursor;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          cursor = await _loadRealtimeSnapshots(input);
          break;
        } on _RealtimeSnapshotCursorMismatch {
          // Cross-client writes can advance the global cursor between reads.
          // Retry the uncommitted batch, preserving the live state and the
          // same cancellation authority. Never install mixed-cursor snapshots.
          if (attempt == 2) rethrow;
        }
      }
      _unreadMentionRefresh.recoveredState = normalizedState.state;
      return cursor;
    } finally {
      _unreadMentionRefresh.resume();
    }
  }

  Future<EventCursor?> _loadRealtimeSnapshots(
    ChatRealtimeSnapshotHydrationInput input,
  ) async {
    if (_disposed || input.isCancelled) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }
    await _awaitRealtimeStorageActivation();
    if (_disposed || input.isCancelled) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }
    final hydrationGeneration = _storageIdentityGeneration;
    final listSnapshots = <ConversationListSnapshot>[];
    final detailSnapshots = <ConversationDetailSnapshot>[];
    final timelinePages = <MessageTimelinePage>[];
    final replayCursors = <EventCursor>[];
    final reminderGeneration = _messageReminderRecoveryRuntime?.generation ??
        _immediateMessageReminderRuntime!.generation;
    final reminderCancellation = ChatCommandCancellationController();
    late final List<MessageReminderListSnapshot>? reminderPages;
    try {
      reminderPages = await _loadMessageReminderPages(
        reminderCancellation.signal,
      );
    } finally {
      reminderCancellation.cancel();
    }
    if (_disposed ||
        input.isCancelled ||
        hydrationGeneration != _storageIdentityGeneration ||
        reminderPages == null ||
        reminderGeneration !=
            (_messageReminderRecoveryRuntime?.generation ??
                _immediateMessageReminderRuntime!.generation)) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }

    for (final scope in normalizedState.recoveryConversationListScopes) {
      final result = await listConversations(
        ConversationListSnapshotInput(scope: scope, limit: 100),
      );
      if (_disposed || input.isCancelled ||
          hydrationGeneration != _storageIdentityGeneration) {
        throw const _RealtimeSnapshotHydrationCancelled();
      }
      listSnapshots.add(_requireSnapshotSuccess(result));
    }

    // A private user-stream event can concern an unopened thread. Recover its
    // resource as well as live subscriptions, rather than repeatedly restoring
    // only the parent channel. Re-read retains after every asynchronous read.
    final requiredConversations = <ConversationId>{
      if (input.diagnostic?.conversationId case final id?) id,
    };
    final visitedConversations = <ConversationId>{};
    while (true) {
      requiredConversations.addAll(input.retainedConversationIds);
      final pending = requiredConversations.difference(visitedConversations);
      if (pending.isEmpty) break;
      final conversationId = pending.first;
      visitedConversations.add(conversationId);
      final detailResult = await getConversation(
        ConversationDetailSnapshotInput(conversationId: conversationId),
      );
      if (_disposed || input.isCancelled ||
          hydrationGeneration != _storageIdentityGeneration) {
        throw const _RealtimeSnapshotHydrationCancelled();
      }
      if (_isRevokedSnapshotResult(detailResult)) {
        realtimeSession?.clearConversationSubscription(conversationId);
        continue;
      }
      final detail = _requireSnapshotSuccess(detailResult);
      detailSnapshots.add(detail);
      final conversation = detail.conversation.summary.conversation;
      if (conversation is ThreadConversation) {
        requiredConversations.add(conversation.parentConversationId);
      }

      final timelineResult = await getMessageTimeline(
        MessageTimelineRequest(
          conversationId: conversationId,
          direction: MessageTimelineDirection.backward,
          limit: messageTimelineMaximumLimit,
        ),
      );
      if (_disposed || input.isCancelled ||
          hydrationGeneration != _storageIdentityGeneration) {
        throw const _RealtimeSnapshotHydrationCancelled();
      }
      if (_isRevokedSnapshotResult(timelineResult)) {
        realtimeSession?.clearConversationSubscription(conversationId);
        detailSnapshots.removeLast();
        continue;
      }
      final timeline = _requireSnapshotSuccess(timelineResult);
      timelinePages.add(timeline);
      replayCursors.add(timeline.replay.resumeFrom);
    }

    if (_disposed || input.isCancelled ||
          hydrationGeneration != _storageIdentityGeneration) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }
    if (replayCursors.isEmpty) {
      // With no retained conversation stream there is no server snapshot
      // cursor to persist. Reconnect without a cursor after list hydration.
      normalizedState.installRecoveredSnapshots(
        conversationLists: listSnapshots,
        conversationDetails: detailSnapshots,
        messageTimelines: timelinePages,
        messageReminderPages: reminderPages,
        safeCursor: null,
      );
      return null;
    }
    final safeCursor = replayCursors.first;
    if (replayCursors.any(
      (cursor) => cursor.eventId != safeCursor.eventId,
    )) {
      throw const _RealtimeSnapshotCursorMismatch();
    }
    normalizedState.installRecoveredSnapshots(
      conversationLists: listSnapshots,
      conversationDetails: detailSnapshots,
      messageTimelines: timelinePages,
      messageReminderPages: reminderPages,
      safeCursor: safeCursor,
    );
    return safeCursor;
  }

  /// Rehydrates the authorized snapshots needed after realtime replay expires.
  ///
  /// This public boundary lets a host-created [ChatRealtimeSessionTransport]
  /// use the same recovery path as a session supplied in the constructor.
  Future<EventCursor?> hydrateRealtimeSnapshots(
    ChatRealtimeSnapshotHydrationInput input,
  ) =>
      _hydrateRealtimeSnapshots(input);

  /// Sends one authored message through the retry-safe command boundary.
  ///
  /// Generated client and idempotency identifiers are validated with the
  /// authored content before authentication or transport access. Successful
  /// applied and replayed outcomes reconcile the same authoritative message.
  Future<ChatCommandResult<SendMessageResult>> sendMessage(
    ChatSendMessageInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_disposed) {
      return const ChatCommandClosed<SendMessageResult>();
    }
    late final SendMessageRequest request;
    try {
      request = SendMessageRequest.fromJson(<String, Object?>{
        'operation': 'send',
        'conversationId': input.conversationId.toJson(),
        'content': input.content.toJson(),
        if (input.replyTo != null) 'replyTo': input.replyTo!.toJson(),
        'clientMessageId': _generateClientMessageId(),
        'idempotencyKey': _generateCommandIdempotencyKey(),
      });
    } catch (_) {
      return const ChatCommandValidationFailure<SendMessageResult>();
    }

    final queue = _offlineSendQueue;
    final session = realtimeSession;
    final isOffline = session != null &&
        (!session.network.isOnline ||
            session.state is ChatRealtimeOfflineState);
    if (isOffline && queue != null) {
      if (cancellationSignal?.isCancelled == true) {
        return const ChatCommandAborted<SendMessageResult>();
      }
      try {
        final queued = await queue.enqueue(request);
        return ChatCommandQueued<SendMessageResult>(
          commandId: queued.clientMessageId,
          idempotencyKey: queued.idempotencyKey,
          enqueueOrder: queued.enqueueOrder,
          enqueuedAt: queued.enqueuedAt,
        );
      } on FormatException {
        return const ChatCommandValidationFailure<SendMessageResult>();
      } on ArgumentError {
        return const ChatCommandValidationFailure<SendMessageResult>();
      } catch (_) {
        return const ChatCommandTransportFailure<SendMessageResult>();
      }
    }

    final sendIdentityGeneration = _storageIdentityGeneration;
    final result = await _commandDispatcher.dispatch(
      _sendMessageDescriptor,
      request.toJson(),
      options: ChatCommandDispatchOptions(
        idempotencyKey: request.idempotencyKey,
        cancellationSignal: cancellationSignal,
      ),
    );
    if (result case ChatCommandSuccess<SendMessageResult>(:final value)) {
      if (_disposed || sendIdentityGeneration != _storageIdentityGeneration) {
        return result;
      }
      normalizedState.reconcileMessage(value.message);
      if (normalizedState.state.conversationMetadata
              .containsKey(value.message.conversationId) &&
          !normalizedState.state.messages.containsKey(value.message.id)) {
        // The command carries canonical content, not the timeline's attachment
        // and reaction metadata. Recover that projection even if the realtime
        // echo is delayed or absent, without holding the composer open.
        unawaited(_hydrateSentMessage(value.message, sendIdentityGeneration));
      }
    }
    return result;
  }

  Future<void> _hydrateSentMessage(Message message, int identityGeneration) async {
    final result = await getMessageTimeline(MessageTimelineRequest(
      conversationId: message.conversationId,
      direction: MessageTimelineDirection.forward,
      cursor: MessageSequence(message.sequence.value - 1),
      limit: 1,
    ));
    if (_disposed ||
        identityGeneration != _storageIdentityGeneration ||
        !normalizedState.state.canonicalMessages.containsKey(message.id)) {
      return;
    }
    if (result case ChatSnapshotQuerySuccess<MessageTimelinePage>(:final value)) {
      try {
        normalizedState.hydrateMessageTimeline(value);
      } on NormalizedSnapshotConflict {
        // A later authoritative update may win while this read is in flight.
        // Sending already succeeded; ordinary timeline recovery remains usable.
      }
    }
  }

  /// Forwards one canonical source message into an explicit destination.
  ///
  /// Correlation and idempotency identities are generated once per logical
  /// command and remain stable across safe retries. Applied and replayed
  /// results use ordinary authoritative message reconciliation.
  Future<ChatCommandResult<ForwardMessageResult>> forwardMessage(
    ChatForwardMessageInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_disposed) {
      return const ChatCommandClosed<ForwardMessageResult>();
    }

    final durableRuntime = _forwardMessageRuntime;
    if (durableRuntime != null) {
      try {
        ForwardMessageRequest.fromJson(<String, Object?>{
          'operation': 'forward_message.v1',
          'sourceMessageId': input.sourceMessageId.toJson(),
          'destinationConversationId': input.destinationConversationId.toJson(),
          'clientCorrelationId': 'forward-validation',
          'idempotencyKey': 'forward-validation',
        });
      } catch (_) {
        return const ChatCommandValidationFailure<ForwardMessageResult>();
      }
      var identity = _storageActivationIdentity;
      if (identity == null) {
        final configured = _forwardIdentity;
        if (configured != null) {
          try {
            await _activateTrustedStorageIdentity(configured);
          } catch (_) {
            return const ChatCommandValidationFailure<ForwardMessageResult>();
          }
          identity = _storageActivationIdentity;
        }
      }
      if (identity == null) {
        return const ChatCommandValidationFailure<ForwardMessageResult>();
      }
      final generation = _storageIdentityGeneration;
      try {
        await _awaitCurrentStorageActivation();
      } catch (_) {
        return const ChatCommandValidationFailure<ForwardMessageResult>();
      }
      if (!_hasStorageIdentityAuthority(identity, generation)) {
        return const ChatCommandClosed<ForwardMessageResult>();
      }
      return durableRuntime.execute(
        input,
        cancellationSignal: cancellationSignal,
      );
    }

    late final ForwardMessageRequest request;
    try {
      request = ForwardMessageRequest.fromJson(<String, Object?>{
        'operation': 'forward_message.v1',
        'sourceMessageId': input.sourceMessageId.toJson(),
        'destinationConversationId': input.destinationConversationId.toJson(),
        'clientCorrelationId': _generateForwardMessageCorrelationId(),
        'idempotencyKey': _generateCommandIdempotencyKey(),
      });
    } catch (_) {
      return const ChatCommandValidationFailure<ForwardMessageResult>();
    }

    final pending = _PendingForwardMessageCorrelation(
      request.clientCorrelationId,
    );
    _pendingForwardMessageCorrelations.add(pending);
    try {
      final result = await _commandDispatcher.dispatch(
        _forwardMessageDescriptor(request),
        request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal: cancellationSignal,
        ),
      );
      if (result case ChatCommandSuccess<ForwardMessageResult>(:final value)) {
        if (_pendingForwardMessageCorrelations.remove(pending)) {
          normalizedState.reconcileMessage(value.message);
        }
      }
      return result;
    } finally {
      _pendingForwardMessageCorrelations.remove(pending);
    }
  }

  /// Replaces one canonical message's content through an optimistic,
  /// retry-safe edit transaction.
  ///
  /// The complete generated request and current canonical revision are
  /// validated before authentication or transport access. With application
  /// storage, durability also precedes the optimistic projection; without
  /// storage the projection remains synchronous for backward compatibility.
  Future<ChatCommandResult<EditMessageResult>> editMessage(
    ChatEditMessageInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(const ChatCommandClosed<EditMessageResult>());
    }

    late final EditMessageRequest request;
    try {
      final idempotencyKey =
          input.idempotencyKey ?? _generateCommandIdempotencyKey();
      request = EditMessageRequest.fromJson(<String, Object?>{
        'operation': 'edit',
        'messageId': input.messageId.toJson(),
        'expectedRevision': input.expectedRevision,
        'content': input.content.toJson(),
        'idempotencyKey': idempotencyKey,
      });
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<EditMessageResult>(),
      );
    }

    final durableRuntime = _messageEditRuntime;
    if (durableRuntime != null) {
      return _executeDurableMessageEdit(
        durableRuntime,
        request,
        cancellationSignal: cancellationSignal,
      );
    }

    try {
      normalizedState.beginOptimisticMessageEdit(request);
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<EditMessageResult>(),
      );
    }

    final dispatch = _commandDispatcher.dispatch(
      _editMessageDescriptor,
      request,
      options: ChatCommandDispatchOptions(
        idempotencyKey: request.idempotencyKey,
        cancellationSignal: cancellationSignal,
      ),
    );
    return dispatch.then((result) {
      if (result case ChatCommandSuccess<EditMessageResult>(:final value)) {
        normalizedState.reconcileOptimisticMessageEdit(
          request.idempotencyKey,
          value,
        );
      } else {
        normalizedState.rollbackOptimisticMessageEdit(
          request.messageId,
          request.idempotencyKey,
        );
      }
      return result;
    });
  }

  Future<ChatCommandResult<EditMessageResult>> _executeDurableMessageEdit(
    _MessageEditRecoveryRuntime runtime,
    EditMessageRequest request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    final identity = _storageActivationIdentity;
    final generation = _storageIdentityGeneration;
    if (identity == null) {
      return const ChatCommandValidationFailure<EditMessageResult>();
    }
    try {
      await _awaitCurrentStorageActivation();
    } catch (_) {
      return const ChatCommandValidationFailure<EditMessageResult>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return const ChatCommandClosed<EditMessageResult>();
    }
    return runtime.execute(
      request,
      cancellationSignal: cancellationSignal,
    );
  }

  /// Soft-deletes one canonical active message through an optimistic,
  /// retry-safe transaction.
  ///
  /// The complete generated request and current canonical revision are
  /// validated before authentication or transport access. A deletion shell is
  /// published synchronously until an authoritative result settles it.
  Future<ChatCommandResult<SoftDeleteMessageResult>> deleteMessage(
    ChatDeleteMessageInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_disposed) {
      return Future.value(
        const ChatCommandClosed<SoftDeleteMessageResult>(),
      );
    }

    late final SoftDeleteMessageRequest request;
    try {
      final idempotencyKey =
          input.idempotencyKey ?? _generateCommandIdempotencyKey();
      request = SoftDeleteMessageRequest.fromJson(<String, Object?>{
        'operation': 'soft_delete',
        'messageId': input.messageId.toJson(),
        'expectedRevision': input.expectedRevision,
        'idempotencyKey': idempotencyKey,
      });
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<SoftDeleteMessageResult>(),
      );
    }

    final durableRuntime = _messageDeleteRuntime;
    if (durableRuntime != null) {
      return _executeDurableMessageDelete(
        durableRuntime,
        request,
        cancellationSignal: cancellationSignal,
      );
    }

    try {
      normalizedState.beginOptimisticMessageDelete(request);
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<SoftDeleteMessageResult>(),
      );
    }

    final dispatch = _commandDispatcher.dispatch(
      _deleteMessageDescriptor,
      request,
      options: ChatCommandDispatchOptions(
        idempotencyKey: request.idempotencyKey,
        cancellationSignal: cancellationSignal,
      ),
    );
    return dispatch.then((result) {
      if (result
          case ChatCommandSuccess<SoftDeleteMessageResult>(
            :final value,
          )) {
        normalizedState.reconcileOptimisticMessageDelete(
          request.idempotencyKey,
          value,
        );
      } else {
        normalizedState.rollbackOptimisticMessageDelete(
          request.messageId,
          request.idempotencyKey,
        );
      }
      return result;
    });
  }

  Future<ChatCommandResult<SoftDeleteMessageResult>>
      _executeDurableMessageDelete(
    _MessageDeleteRecoveryRuntime runtime,
    SoftDeleteMessageRequest request, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    final identity = _storageActivationIdentity;
    final generation = _storageIdentityGeneration;
    if (identity == null) {
      return const ChatCommandValidationFailure<SoftDeleteMessageResult>();
    }
    try {
      await _awaitCurrentStorageActivation();
    } catch (_) {
      return const ChatCommandValidationFailure<SoftDeleteMessageResult>();
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) {
      return const ChatCommandClosed<SoftDeleteMessageResult>();
    }
    return runtime.execute(
      request,
      cancellationSignal: cancellationSignal,
    );
  }

  /// Sets the current user's explicit membership in one reaction aggregate.
  ///
  /// Intents for the same message and reaction key are dispatched in order,
  /// while unrelated aggregates remain independent. With application storage,
  /// the validated intent is durable before its desired state is projected or
  /// authentication begins, and its idempotency key survives recovery.
  Future<ChatCommandResult<ReactionMutationResult>> setReaction(
    ChatSetReactionInput input, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) async {
    if (_disposed) {
      return Future.value(
        const ChatCommandClosed<ReactionMutationResult>(),
      );
    }

    late final ReactionMutationInput request;
    try {
      final idempotencyKey =
          input.idempotencyKey ?? _generateCommandIdempotencyKey();
      request = ReactionMutationInput.fromJson(<String, Object?>{
        'operation': input.reactedByCurrentUser
            ? ReactionMutationOperation.addReaction.toJson()
            : ReactionMutationOperation.removeReaction.toJson(),
        'messageId': input.messageId.toJson(),
        'reactionKey': input.reactionKey,
        'idempotencyKey': idempotencyKey,
      });
    } catch (_) {
      return const ChatCommandValidationFailure<ReactionMutationResult>();
    }

    final durableRuntime = _reactionRuntime;
    if (durableRuntime != null) {
      final identity = _storageActivationIdentity;
      final generation = _storageIdentityGeneration;
      if (identity == null) {
        return const ChatCommandValidationFailure<ReactionMutationResult>();
      }
      try {
        await _awaitCurrentStorageActivation();
      } catch (_) {
        return const ChatCommandValidationFailure<ReactionMutationResult>();
      }
      if (!_hasStorageIdentityAuthority(identity, generation)) {
        return const ChatCommandClosed<ReactionMutationResult>();
      }
      return durableRuntime.execute(
        request,
        cancellationSignal: cancellationSignal,
      );
    }

    try {
      normalizedState.beginOptimisticReaction(request);
    } catch (_) {
      return const ChatCommandValidationFailure<ReactionMutationResult>();
    }
    if (cancellationSignal?.isCancelled == true) {
      _rollbackReactionIntent(request);
      return const ChatCommandAborted<ReactionMutationResult>();
    }

    final target = _reactionCommandTarget(
      request.messageId,
      request.reactionKey,
    );
    final intent = _ReactionCommandIntent(
      request: request,
      cancellationSignal: cancellationSignal,
    );
    final lane = _reactionCommandLanes.putIfAbsent(
      target,
      _ReactionCommandLane.new,
    );
    lane.intents.add(intent);
    if (cancellationSignal != null) {
      intent.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        if (identical(lane.active, intent) || intent.completer.isCompleted) {
          return;
        }
        if (!lane.intents.remove(intent)) return;
        _rollbackReactionIntent(intent.request);
        intent.completer.complete(
          const ChatCommandAborted<ReactionMutationResult>(),
        );
        unawaited(intent.cancellationSubscription?.cancel());
      });
    }
    if (!lane.draining) {
      lane.draining = true;
      late final Future<void> drain;
      drain = _drainReactionCommandLane(target, lane).whenComplete(() {
        _reactionCommandDrains.remove(drain);
      });
      _reactionCommandDrains.add(drain);
    }
    return intent.completer.future;
  }

  /// Fetches, validates, and negotiates `GET /_meta` server metadata.
  Future<ChatClientLifecycleState> initialize() {
    if (_disposed) {
      throw StateError('The Handrail chat client has been disposed.');
    }
    if (_state is ChatClientReadyState ||
        _state is ChatClientRefreshRequiredState) {
      return Future<ChatClientLifecycleState>.value(_state);
    }

    final active = _initialization;
    if (active != null) return active;

    late final Future<ChatClientLifecycleState> initialization;
    initialization = _initializeWithOfflineQueue().whenComplete(() {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
    });
    _initialization = initialization;
    return initialization;
  }

  Future<ChatClientLifecycleState> _initializeWithOfflineQueue() async {
    final identity = _forwardIdentity;
    if (_localStorage != null && identity != null) {
      await _activateTrustedStorageIdentity(identity);
      await _awaitCurrentStorageActivation();
    } else {
      await Future.wait<void>([
        if (_offlineSendQueue != null) _offlineSendQueue!.ensureLoaded(),
        _readCursorRuntime.ensureLoaded(),
      ]);
    }
    if (_disposed) return _state;
    final metadata = await _initialize();
    await replyStyles._initialize(metadata);
    return metadata;
  }

  Future<void> _activateRealtimeStorageIdentity(
    ChatRealtimeAcceptedIdentity identity,
  ) async {
    final storageIdentity = ApplicationChatStorageIdentity(
      tenantId: identity.tenantId,
      userId: identity.userId,
      deviceId: identity.deviceId,
    );
    try {
      await _activateTrustedStorageIdentity(storageIdentity);
      if (_forwardIdentity == storageIdentity && !_disposed) {
        _updateDurablePumpReadiness();
        if (realtimeSession?.state is ChatRealtimeConnectedState) {
          _unreadMentionRefresh.connected();
        }
      }
    } catch (_) {
      // Storage remains application-owned and must not destabilize realtime.
      _updateDurablePumpReadiness(realtimeIdentityReady: false);
    }
  }

  Future<void> _activateTrustedStorageIdentity(
    ApplicationChatStorageIdentity identity,
  ) {
    final replyIdentityChanged =
        replyStyles.state.identity?.tenantId != identity.tenantId ||
        replyStyles.state.identity?.userId != identity.userId;
    replyStyles._setIdentity(ChatReplyStyleIdentity(
        tenantId: identity.tenantId, userId: identity.userId));
    if (replyIdentityChanged && realtimeSession == null) {
      unawaited(replyStyles.refresh());
    }
    final active = _storageActivation;
    if (_storageActivationIdentity == identity && active != null) {
      return active;
    }

    _activateForwardIdentity(identity);
    threadLifecycles._invalidateIdentity();
    threadLists._invalidateIdentity();
    messageContexts._invalidateIdentity();
    final generation = ++_storageIdentityGeneration;
    _storageActivationIdentity = identity;
    _messageEditRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _forwardMessageRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _messageDeleteRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _reactionRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _conversationMembershipRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _conversationCreationRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _conversationPreferenceRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _threadFollowRecoveryRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _messageReminderRecoveryRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    _conversationArchiveRecoveryRuntime?.prepareActivation(
      identity,
      generation: generation,
    );
    huddles.prepareActivation(identity, generation: generation);
    unawaited(_draftRuntime.activate(
      identity,
      generation: generation,
      loadRetained: false,
    ));
    final previousCheckpointSubscription =
        _normalizedSnapshotCommitSubscription;
    _normalizedSnapshotCommitSubscription = null;
    _pendingNormalizedSnapshotCheckpoint = null;
    _normalizedSnapshotCheckpointBaseline = null;
    final checkpointSubscriptionCancellation =
        previousCheckpointSubscription?.cancel();
    if (realtimeSession != null) {
      _updateDurablePumpReadiness(realtimeIdentityReady: false);
    }
    if (_installedSnapshotIdentity case final installed?
        when installed.tenantId != identity.tenantId ||
            installed.userId != identity.userId ||
            (_localStorage != null && installed.deviceId != identity.deviceId)) {
      // The server's ephemeral device identity can change on reconnect. An
      // in-memory snapshot belongs to the authenticated actor; only persisted
      // snapshots additionally depend on the host's device storage boundary.
      try {
        normalizedState.installPersistedSnapshot(
          NormalizedSnapshotState.empty(),
        );
        _installedSnapshotIdentity = null;
      } on StateError {
        // An externally owned normalized store may already be closed.
      }
    }
    late final Future<void> operation;
    operation = _hydrateAndActivateStorageIdentity(
      identity,
      generation,
      checkpointSubscriptionCancellation,
    ).onError((Object error, StackTrace stackTrace) {
      if (_hasStorageIdentityAuthority(identity, generation) &&
          identical(_storageActivation, operation)) {
        _storageActivation = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    _storageActivation = operation;
    return operation;
  }

  Future<void> _hydrateAndActivateStorageIdentity(
    ApplicationChatStorageIdentity identity,
    int generation,
    Future<void>? checkpointSubscriptionCancellation,
  ) async {
    if (checkpointSubscriptionCancellation != null) {
      await checkpointSubscriptionCancellation;
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _hydrateNormalizedSnapshot(identity, generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    _installedSnapshotIdentity = identity;
    _subscribeToNormalizedSnapshotCommits(identity, generation);
    await _draftRuntime.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _forwardMessageRuntime?.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _messageEditRuntime?.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _messageDeleteRuntime?.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _reactionRuntime?.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _conversationMembershipRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _conversationCreationRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _conversationPreferenceRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _threadFollowRecoveryRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _messageReminderRecoveryRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _conversationArchiveRecoveryRuntime?.activate(
      identity,
      generation: generation,
    );
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await huddles.activate(identity, generation: generation);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _readCursorRuntime.activate(identity);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _offlineSendQueue?.activate(identity);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    await _pushTokenRuntime?.activate(identity);
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    _updateDurablePumpReadiness();
  }

  Future<void> _awaitCurrentStorageActivation() async {
    while (!_disposed) {
      final operation = _storageActivation;
      if (operation == null) return;
      await operation;
      if (identical(_storageActivation, operation)) return;
    }
  }

  Future<void> _hydrateNormalizedSnapshot(
    ApplicationChatStorageIdentity identity,
    int generation,
  ) async {
    final storage = _localStorage;
    if (storage == null) return;

    ApplicationChatStorageRecord? candidate;
    String? observedEncodedRecord;
    var atomicBaselineEstablished = false;
    try {
      if (storage is AtomicApplicationChatStorage) {
        observedEncodedRecord = await storage.readEncoded(
          identity,
          ApplicationChatStorageRecordKind.normalizedSnapshot,
        );
        if (!_hasStorageIdentityAuthority(identity, generation)) return;
        atomicBaselineEstablished = true;
        _normalizedSnapshotCheckpointBaseline =
            _NormalizedSnapshotCheckpointBaseline(
          identity: identity,
          generation: generation,
          encodedRecord: observedEncodedRecord,
        );
        if (observedEncodedRecord != null) {
          candidate = ApplicationChatStorageRecord.decode(
            observedEncodedRecord,
          );
        }
      } else {
        candidate = await storage.read(
          identity,
          ApplicationChatStorageRecordKind.normalizedSnapshot,
        );
      }
    } on FormatException {
      if (_hasStorageIdentityAuthority(identity, generation)) {
        _reportStorageDiagnostic(
          ChatClientDiagnosticCode.normalizedSnapshotRejected,
          'The stored normalized snapshot was rejected and quarantined.',
        );
        await _quarantineNormalizedSnapshot(
          storage,
          identity,
          generation,
          expectedEncodedRecord: observedEncodedRecord,
          atomicBaselineEstablished: atomicBaselineEstablished,
        );
      }
      return;
    } catch (_) {
      if (_hasStorageIdentityAuthority(identity, generation)) {
        _reportStorageDiagnostic(
          ChatClientDiagnosticCode.normalizedSnapshotReadFailed,
          'The normalized snapshot could not be read.',
        );
      }
      return;
    }

    if (!_hasStorageIdentityAuthority(identity, generation) ||
        candidate == null) {
      return;
    }
    try {
      if (candidate is! ApplicationChatNormalizedSnapshotRecord ||
          candidate.kind !=
              ApplicationChatStorageRecordKind.normalizedSnapshot ||
          candidate.identity != identity) {
        throw const FormatException(
          'Stored normalized snapshot does not match its storage scope.',
        );
      }
      normalizedState.installPersistedSnapshot(candidate.snapshot);
      _installedSnapshotIdentity = identity;
    } catch (error) {
      if (error is! FormatException &&
          error is! NormalizedSnapshotConflict &&
          error is! ArgumentError) {
        rethrow;
      }
      if (!_hasStorageIdentityAuthority(identity, generation)) return;
      _reportStorageDiagnostic(
        ChatClientDiagnosticCode.normalizedSnapshotRejected,
        'The stored normalized snapshot was rejected and quarantined.',
      );
      await _quarantineNormalizedSnapshot(
        storage,
        identity,
        generation,
        expectedEncodedRecord: observedEncodedRecord,
        atomicBaselineEstablished: atomicBaselineEstablished,
      );
    }
  }

  Future<void> _quarantineNormalizedSnapshot(
    ApplicationChatStorage storage,
    ApplicationChatStorageIdentity identity,
    int generation, {
    String? expectedEncodedRecord,
    bool atomicBaselineEstablished = false,
  }) async {
    try {
      if (storage is AtomicApplicationChatStorage) {
        if (!atomicBaselineEstablished) return;
        final removed = await storage.compareExchange(
          identity,
          ApplicationChatStorageRecordKind.normalizedSnapshot,
          expectedEncodedRecord,
          null,
        );
        if (removed && _hasStorageIdentityAuthority(identity, generation)) {
          _normalizedSnapshotCheckpointBaseline =
              _NormalizedSnapshotCheckpointBaseline(
            identity: identity,
            generation: generation,
            encodedRecord: null,
          );
        }
      } else {
        await storage.remove(
          identity,
          ApplicationChatStorageRecordKind.normalizedSnapshot,
        );
      }
    } catch (_) {
      if (_hasStorageIdentityAuthority(identity, generation)) {
        _reportStorageDiagnostic(
          ChatClientDiagnosticCode.normalizedSnapshotQuarantineFailed,
          'The rejected normalized snapshot could not be quarantined.',
        );
      }
    }
  }

  void _subscribeToNormalizedSnapshotCommits(
    ApplicationChatStorageIdentity identity,
    int generation,
  ) {
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    _normalizedSnapshotCommitSubscription =
        normalizedState.acceptedCommitChanges.listen((_) {
      _captureNormalizedSnapshotCheckpoint(identity, generation);
    });
  }

  void _captureNormalizedSnapshotCheckpoint(
    ApplicationChatStorageIdentity identity,
    int generation,
  ) {
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    late final ApplicationChatNormalizedSnapshotRecord record;
    late final String encodedRecord;
    try {
      record = ApplicationChatNormalizedSnapshotRecord(
        identity: identity,
        snapshot: normalizedState.canonicalPersistenceSnapshot(),
      );
      encodedRecord = record.encode();
    } catch (_) {
      if (_hasStorageIdentityAuthority(identity, generation)) {
        _reportStorageDiagnostic(
          ChatClientDiagnosticCode.normalizedSnapshotWriteFailed,
          'The normalized snapshot could not be checkpointed.',
        );
      }
      return;
    }
    if (!_hasStorageIdentityAuthority(identity, generation)) return;
    _pendingNormalizedSnapshotCheckpoint = _NormalizedSnapshotCheckpoint(
      identity: identity,
      generation: generation,
      record: record,
      encodedRecord: encodedRecord,
    );
    _ensureNormalizedSnapshotCheckpointDrain();
  }

  void _ensureNormalizedSnapshotCheckpointDrain() {
    if (_normalizedSnapshotCheckpointDraining || _disposed) return;
    _normalizedSnapshotCheckpointDraining = true;
    unawaited(_drainNormalizedSnapshotCheckpoints());
  }

  Future<void> _drainNormalizedSnapshotCheckpoints() async {
    try {
      while (!_disposed) {
        final checkpoint = _pendingNormalizedSnapshotCheckpoint;
        _pendingNormalizedSnapshotCheckpoint = null;
        if (checkpoint == null) return;
        if (!_hasStorageIdentityAuthority(
          checkpoint.identity,
          checkpoint.generation,
        )) {
          continue;
        }
        try {
          final storage = _localStorage!;
          if (storage is AtomicApplicationChatStorage) {
            final baseline = _normalizedSnapshotCheckpointBaseline;
            if (baseline == null ||
                baseline.identity != checkpoint.identity ||
                baseline.generation != checkpoint.generation) {
              throw StateError(
                'The normalized snapshot checkpoint baseline is unavailable.',
              );
            }
            final replaced = await storage.compareExchange(
              checkpoint.identity,
              ApplicationChatStorageRecordKind.normalizedSnapshot,
              baseline.encodedRecord,
              checkpoint.encodedRecord,
            );
            if (!replaced) {
              throw StateError(
                'The normalized snapshot checkpoint baseline is stale.',
              );
            }
            if (_hasStorageIdentityAuthority(
              checkpoint.identity,
              checkpoint.generation,
            )) {
              _normalizedSnapshotCheckpointBaseline =
                  _NormalizedSnapshotCheckpointBaseline(
                identity: checkpoint.identity,
                generation: checkpoint.generation,
                encodedRecord: checkpoint.encodedRecord,
              );
            }
          } else {
            await storage.replace(checkpoint.record);
          }
        } catch (_) {
          if (_hasStorageIdentityAuthority(
            checkpoint.identity,
            checkpoint.generation,
          )) {
            _reportStorageDiagnostic(
              ChatClientDiagnosticCode.normalizedSnapshotWriteFailed,
              'The normalized snapshot could not be checkpointed.',
            );
          }
        }
      }
    } finally {
      _normalizedSnapshotCheckpointDraining = false;
      if (_pendingNormalizedSnapshotCheckpoint != null && !_disposed) {
        _ensureNormalizedSnapshotCheckpointDrain();
      }
    }
  }

  bool _hasStorageIdentityAuthority(
    ApplicationChatStorageIdentity identity,
    int generation,
  ) =>
      !_disposed &&
      generation == _storageIdentityGeneration &&
      _storageActivationIdentity == identity &&
      _forwardIdentity == identity;

  void _reportStorageDiagnostic(String code, String message) {
    try {
      onStorageDiagnostic?.call(
        ChatClientDiagnostic(code: code, message: message),
      );
    } catch (_) {
      // Application diagnostics cannot alter storage or client reliability.
    }
  }

  Future<void> _awaitRealtimeStorageActivation() async {
    if (_localStorage == null) return;
    final state = realtimeSession?.state;
    if (state is! ChatRealtimeConnectedState) return;
    final identity = ApplicationChatStorageIdentity(
      tenantId: state.identity.tenantId,
      userId: state.identity.userId,
      deviceId: state.identity.deviceId,
    );
    final operation = _activateTrustedStorageIdentity(identity);
    await operation;
    final currentState = realtimeSession?.state;
    if (_disposed || currentState is! ChatRealtimeConnectedState) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }
    final current = currentState.identity;
    if (current.tenantId != identity.tenantId ||
        current.userId != identity.userId ||
        current.deviceId != identity.deviceId) {
      throw const _RealtimeSnapshotHydrationCancelled();
    }
  }

  Future<DurableEventReduction> _reduceRealtimeDurableEvent(
    KnownDurableEvent event,
  ) async {
    await _awaitRealtimeStorageActivation();
    return reduceDurableEvent(event);
  }

  void _activateForwardIdentity(ApplicationChatStorageIdentity identity) {
    if (_forwardIdentity == identity) return;
    _unreadMentionRefresh.invalidate();
    _immediateMessageReminderRuntime?.invalidateIdentity();
    _forwardIdentity = identity;
    _pendingForwardMessageCorrelations.clear();
  }

  Future<List<MessageReminderListSnapshot>?> _refreshMessageReminderAuthority(
    ChatCommandCancellationSignal cancellationSignal,
  ) =>
      _loadMessageReminderPages(cancellationSignal);

  Future<List<MessageReminderListSnapshot>?> _loadMessageReminderPages(
    ChatCommandCancellationSignal cancellationSignal,
  ) async {
    final pages = <MessageReminderListSnapshot>[];
    final seenCursors = <String>{};
    MessageReminderSnapshotCursor? cursor;
    for (var pageNumber = 0;
        pageNumber < _maximumMessageReminderRecoveryPages;
        pageNumber += 1) {
      if (_disposed || cancellationSignal.isCancelled) return null;
      final result = await _snapshotQueries.listMessageReminders(
        MessageReminderListSnapshotInput(
          limit: messageReminderSnapshotMaximumLimit,
          cursor: cursor,
        ),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: cancellationSignal,
        ),
      );
      if (_disposed || cancellationSignal.isCancelled) return null;
      if (result
          case ChatSnapshotQuerySuccess<MessageReminderListSnapshot>(
            :final value,
          )) {
        pages.add(value);
        final next = value.nextCursor;
        if (next == null) return List.unmodifiable(pages);
        if (!seenCursors.add(next.value)) return null;
        cursor = next;
        continue;
      }
      return null;
    }
    return null;
  }

  Future<_ConversationMembershipAuthorityRefreshResult>
      _refreshConversationMembershipAuthority(
    ConversationMembershipMutationInput request,
    ChatCommandCancellationSignal cancellationSignal,
  ) async {
    if (_disposed || cancellationSignal.isCancelled) {
      return _ConversationMembershipAuthorityRefreshResult.retry;
    }
    final result = await _snapshotQueries.getConversation(
      ConversationDetailSnapshotInput(
        conversationId: request.conversationId,
      ),
      options: ChatSnapshotQueryOptions(
        cancellationSignal: cancellationSignal,
      ),
    );
    if (_disposed || cancellationSignal.isCancelled) {
      return _ConversationMembershipAuthorityRefreshResult.retry;
    }
    if (_isRevokedSnapshotResult(result)) {
      realtimeSession?.clearConversationSubscription(request.conversationId);
      return _ConversationMembershipAuthorityRefreshResult.terminal;
    }
    if (result
        case ChatSnapshotQuerySuccess<ConversationDetailSnapshot>(
          :final value,
        )) {
      try {
        normalizedState.hydrateConversationDetail(value);
      } catch (_) {
        return _ConversationMembershipAuthorityRefreshResult.retry;
      }
      final snapshot = normalizedState.conversation(request.conversationId);
      return snapshot.conversation != null &&
              (snapshot.memberListRevision ?? -1) >=
                  request.expectedMemberListRevision
          ? _ConversationMembershipAuthorityRefreshResult.ready
          : _ConversationMembershipAuthorityRefreshResult.retry;
    }
    return _ConversationMembershipAuthorityRefreshResult.retry;
  }

  void _updateDurablePumpReadiness({
    bool realtimeIdentityReady = true,
  }) {
    final session = realtimeSession;
    final realtimeState = session?.state;
    final huddleRealtimeIdentityReady = realtimeState == null ||
        realtimeState is ChatRealtimeConnectedState &&
            _storageActivationIdentity?.tenantId ==
                realtimeState.identity.tenantId &&
            _storageActivationIdentity?.userId ==
                realtimeState.identity.userId &&
            _storageActivationIdentity?.deviceId ==
                realtimeState.identity.deviceId;
    _offlineSendPump?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline:
          _applicationForeground && session?.network.isOnline == true,
      realtimeConnected: _applicationForeground &&
          realtimeIdentityReady &&
          session?.state is ChatRealtimeConnectedState,
    );
    _readCursorRuntime.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _draftRuntime.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _messageEditRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _forwardMessageRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _messageDeleteRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _reactionRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _conversationMembershipRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _conversationCreationRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _conversationPreferenceRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _threadFollowRecoveryRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _messageReminderRecoveryRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    _conversationArchiveRecoveryRuntime?.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady &&
              session.state is ChatRealtimeConnectedState),
      applicationForeground: _applicationForeground,
    );
    huddles.updateReadiness(
      metadataReady: _state is ChatClientReadyState,
      connectivityOnline: session == null || session.network.isOnline,
      realtimeConnected: session == null ||
          (realtimeIdentityReady && huddleRealtimeIdentityReady),
      applicationForeground: _applicationForeground,
    );
  }

  bool _huddlesFeatureEnabled() {
    if (_disposed) return false;
    final lifecycle = _state;
    if (lifecycle is! ChatClientReadyState) return true;
    final capabilities = lifecycle.negotiatedCapabilities;
    if (capabilities['huddles'] != true) return false;
    return capabilities['media'] != false;
  }

  /// Closes active snapshot queries and releases lifecycle stream resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final replyStylesClose = replyStyles._dispose();
    final messageContextsClose = messageContexts.dispose();
    _unreadMentionRefresh.close();
    _commandDispatcher.closeActive();
    ++_storageIdentityGeneration;
    _storageActivationIdentity = null;
    _installedSnapshotIdentity = null;
    _storageActivation = null;
    _pendingNormalizedSnapshotCheckpoint = null;
    _normalizedSnapshotCheckpointBaseline = null;
    final normalizedSnapshotCheckpointClose =
        _normalizedSnapshotCommitSubscription?.cancel();
    _normalizedSnapshotCommitSubscription = null;
    _immediateMessageReminderRuntime?.invalidateIdentity();
    _pendingForwardMessageCorrelations.clear();
    _forwardIdentity = null;
    _realtimeDurableStateBindingRelease?.call();
    _realtimeDurableStateBindingRelease = null;
    reads.dispose();
    _readCursorRuntime.close();
    final draftClose = _draftRuntime.close();
    final forwardMessageClose = _forwardMessageRuntime?.close();
    final messageEditClose = _messageEditRuntime?.close();
    final messageDeleteClose = _messageDeleteRuntime?.close();
    final reactionClose = _reactionRuntime?.close();
    final conversationMembershipClose = _conversationMembershipRuntime?.close();
    final conversationCreationClose = _conversationCreationRuntime?.close();
    final conversationPreferenceClose = _conversationPreferenceRuntime?.close();
    final threadFollowRecoveryClose = _threadFollowRecoveryRuntime?.close();
    final messageReminderRecoveryClose =
        _messageReminderRecoveryRuntime?.close();
    final conversationArchiveRecoveryClose =
        _conversationArchiveRecoveryRuntime?.close();
    final attachmentClose = _attachmentUploadManager?.closeActive();
    final pushTokenClose = _pushTokenRuntime?.beginClose();
    final realtimeStorageIdentityClose =
        _realtimeStorageIdentitySubscription?.cancel();
    final realtimeCanonicalEventClose =
        _realtimeCanonicalEventSubscription?.cancel();
    final offlinePumpClose = _offlineSendPump?.close();
    await huddles.dispose();
    await threadLifecycles.dispose();
    await threadLists.dispose();
    await replyStylesClose;
    await messageContextsClose;
    await threads.dispose();
    await _immediateThreadFollowRuntime?.dispose();
    await _immediateMessageReminderRuntime?.dispose();
    _closeConversationArchiveCommands();
    _closeConversationMembershipCommands();
    _closeConversationPreferenceCommands();
    for (final lane in _reactionCommandLanes.values) {
      for (final intent in lane.intents.skip(lane.active == null ? 0 : 1)) {
        if (intent.completer.isCompleted) continue;
        _rollbackReactionIntent(intent.request);
        unawaited(intent.cancellationSubscription?.cancel());
        intent.completer.complete(
          const ChatCommandClosed<ReactionMutationResult>(),
        );
      }
      if (lane.active != null && lane.intents.length > 1) {
        lane.intents.removeRange(1, lane.intents.length);
      } else if (lane.active == null) {
        lane.intents.clear();
      }
    }
    if (attachmentClose != null) await attachmentClose;
    if (realtimeStorageIdentityClose != null) {
      await realtimeStorageIdentityClose;
    }
    if (realtimeCanonicalEventClose != null) {
      await realtimeCanonicalEventClose;
    }
    if (normalizedSnapshotCheckpointClose != null) {
      await normalizedSnapshotCheckpointClose;
    }
    if (offlinePumpClose != null) await offlinePumpClose;
    await _offlineSendQueue?.close();
    _snapshotQueries.close();
    await draftClose;
    if (forwardMessageClose != null) await forwardMessageClose;
    if (messageEditClose != null) await messageEditClose;
    if (messageDeleteClose != null) await messageDeleteClose;
    if (reactionClose != null) await reactionClose;
    if (conversationMembershipClose != null) {
      await conversationMembershipClose;
    }
    if (conversationCreationClose != null) await conversationCreationClose;
    if (conversationPreferenceClose != null) {
      await conversationPreferenceClose;
    }
    if (threadFollowRecoveryClose != null) await threadFollowRecoveryClose;
    if (messageReminderRecoveryClose != null) {
      await messageReminderRecoveryClose;
    }
    if (conversationArchiveRecoveryClose != null) {
      await conversationArchiveRecoveryClose;
    }
    if (pushTokenClose != null) await pushTokenClose;
    if (_reactionCommandDrains.isNotEmpty) {
      await Future.wait(_reactionCommandDrains.toList(growable: false));
    }
    if (_conversationMembershipCommandDrains.isNotEmpty) {
      await Future.wait(
        _conversationMembershipCommandDrains.toList(growable: false),
      );
    }
    if (_conversationArchiveCommandDrains.isNotEmpty) {
      await Future.wait(
        _conversationArchiveCommandDrains.toList(growable: false),
      );
    }
    if (_conversationPreferenceCommandDrains.isNotEmpty) {
      await Future.wait(
        _conversationPreferenceCommandDrains.toList(growable: false),
      );
    }
    if (_ownsNormalizedState) await normalizedState.close();
    if (_ownsEphemeralSignals) await ephemeralSignals.close();
    await _stateChanges.close();
  }

  Future<void> _drainReactionCommandLane(
    String target,
    _ReactionCommandLane lane,
  ) async {
    while (lane.intents.isNotEmpty) {
      if (_disposed) {
        for (final pending in lane.intents.toList(growable: false)) {
          _rollbackReactionIntent(pending.request);
          await pending.cancellationSubscription?.cancel();
          if (!pending.completer.isCompleted) {
            pending.completer.complete(
              const ChatCommandClosed<ReactionMutationResult>(),
            );
          }
        }
        lane.intents.clear();
        lane.active = null;
        break;
      }
      final intent = lane.intents.first;
      if (intent.completer.isCompleted) {
        lane.intents.removeAt(0);
        continue;
      }
      lane.active = intent;
      final request = intent.request;
      var result = await _commandDispatcher.dispatch(
        _reactionDescriptor,
        request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal: intent.cancellationSignal,
        ),
      );
      if (result
          case ChatCommandSuccess<ReactionMutationResult>(
            :final value,
          )) {
        if (!_reactionResultMatchesRequest(request, value)) {
          result = const ChatCommandMalformedResponse<ReactionMutationResult>();
          _rollbackReactionIntent(request);
        } else {
          _reconcileReactionIntent(request, value);
        }
      } else {
        _rollbackReactionIntent(request);
      }
      await intent.cancellationSubscription?.cancel();
      if (!intent.completer.isCompleted) intent.completer.complete(result);
      if (lane.intents.isNotEmpty && identical(lane.intents.first, intent)) {
        lane.intents.removeAt(0);
      } else {
        lane.intents.remove(intent);
      }
      lane.active = null;
    }
    lane.draining = false;
    if (identical(_reactionCommandLanes[target], lane)) {
      _reactionCommandLanes.remove(target);
    }
  }

  void _reconcileReactionIntent(
    ReactionMutationInput request,
    ReactionMutationResult result,
  ) {
    try {
      normalizedState.reconcileOptimisticReaction(
        request.idempotencyKey,
        result,
      );
    } on StateError {
      // An externally owned normalized store may close before the client.
    }
  }

  void _rollbackReactionIntent(ReactionMutationInput request) {
    try {
      normalizedState.rollbackOptimisticReaction(
        request.messageId,
        request.reactionKey,
        request.idempotencyKey,
      );
    } on StateError {
      // Closing a store already clears its optimistic reaction projections.
    }
  }

  Future<ChatClientLifecycleState> _initialize() async {
    _emit(const ChatClientInitializingState());

    late final String accessToken;
    try {
      accessToken = await tokenProvider();
      if (accessToken.trim().isEmpty) throw const FormatException();
    } catch (_) {
      return _emit(
        const ChatClientErrorState(
          diagnostic: ChatClientDiagnostic(
            code: ChatClientDiagnosticCode.accessTokenFailed,
            message: 'Chat credentials could not be obtained.',
          ),
        ),
      );
    }

    late final HandrailChatHttpResponse response;
    try {
      response = await transport.send(
        HandrailChatHttpRequest(
          method: 'GET',
          uri: _metadataUri(apiBaseUri),
          headers: <String, String>{
            'Accept': 'application/json',
            'Authorization': 'Bearer $accessToken',
          },
        ),
      );
    } catch (_) {
      return _emit(
        const ChatClientErrorState(
          diagnostic: ChatClientDiagnostic(
            code: ChatClientDiagnosticCode.metadataRequestFailed,
            message: 'Chat server metadata could not be requested.',
          ),
        ),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _emit(
        ChatClientErrorState(
          diagnostic: ChatClientDiagnostic(
            code: ChatClientDiagnosticCode.metadataRequestFailed,
            message: 'Chat server metadata could not be requested.',
            httpStatus: response.statusCode,
          ),
        ),
      );
    }

    late final ServerHandshakeMetadata metadata;
    try {
      metadata = _parseMetadata(jsonDecode(response.body));
    } catch (_) {
      return _emit(
        const ChatClientErrorState(
          diagnostic: ChatClientDiagnostic(
            code: ChatClientDiagnosticCode.malformedMetadata,
            message: 'The chat server returned invalid metadata.',
          ),
        ),
      );
    }

    if (!isProtocolSupported(
      handrailChatProtocolVersion,
      metadata.supportedProtocolRange,
    )) {
      return _emit(ChatClientRefreshRequiredState(metadata: metadata));
    }

    return _emit(
      ChatClientReadyState(
        metadata: metadata,
        negotiatedCapabilities: _negotiateCapabilities(
          requestedCapabilities,
          metadata.enabledFeatures.values,
        ),
      ),
    );
  }

  ChatClientLifecycleState _emit(ChatClientLifecycleState nextState) {
    _state = nextState;
    _stateChanges.add(nextState);
    _updateDurablePumpReadiness();
    return nextState;
  }

  Stream<ChatClientLifecycleState> _createStateStream() =>
      Stream<ChatClientLifecycleState>.multi(
        (events) {
          events.add(_state);
          final subscription = _stateChanges.stream.listen(
            events.add,
            onError: events.addError,
            onDone: events.close,
          );
          events.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  String toString() => 'HandrailChatClient(state: ${_state.state})';
}

final class _NormalizedSnapshotCheckpoint {
  const _NormalizedSnapshotCheckpoint({
    required this.identity,
    required this.generation,
    required this.record,
    required this.encodedRecord,
  });

  final ApplicationChatStorageIdentity identity;
  final int generation;
  final ApplicationChatNormalizedSnapshotRecord record;
  final String encodedRecord;
}

final class _NormalizedSnapshotCheckpointBaseline {
  const _NormalizedSnapshotCheckpointBaseline({
    required this.identity,
    required this.generation,
    required this.encodedRecord,
  });

  final ApplicationChatStorageIdentity identity;
  final int generation;
  final String? encodedRecord;
}

Value _requireSnapshotSuccess<Value>(
  ChatSnapshotQueryResult<Value> result,
) =>
    switch (result) {
      ChatSnapshotQuerySuccess<Value>(:final value) => value,
      _ => throw const _RealtimeSnapshotHydrationFailed(),
    };

bool _isRevokedSnapshotResult<Value>(
  ChatSnapshotQueryResult<Value> result,
) =>
    switch (result) {
      ChatSnapshotQueryAuthenticationFailure<Value>(httpStatus: 403) => true,
      ChatSnapshotQueryRejected<Value>(httpStatus: 403 || 404) => true,
      _ => false,
    };

final class _RealtimeSnapshotHydrationFailed implements Exception {
  const _RealtimeSnapshotHydrationFailed();
}

final class _RealtimeSnapshotCursorMismatch implements Exception {
  const _RealtimeSnapshotCursorMismatch();
}

final class _RealtimeSnapshotHydrationCancelled implements Exception {
  const _RealtimeSnapshotHydrationCancelled();
}

final Random _secureIdentifierRandom = Random.secure();

String _generateSecureClientMessageId() => _generateSecureIdentifier('message');

String _generateSecureCommandIdempotencyKey() =>
    _generateSecureIdentifier('command');

String _generateSecureForwardMessageCorrelationId() =>
    _generateSecureIdentifier('forward');

String _generateSecureConversationClientRequestId() =>
    _generateSecureIdentifier('conversation-request');

String _generateSecureDraftMutationId() => _generateSecureIdentifier('draft');

String _generateSecureIdentifier(String prefix) {
  final bytes = List<int>.generate(
    16,
    (_) => _secureIdentifierRandom.nextInt(256),
    growable: false,
  );
  final encoded =
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '$prefix:$encoded';
}

Map<String, bool> _copyRequestedCapabilities(Map<String, bool> capabilities) {
  if (capabilities.keys.any((name) => name.trim().isEmpty)) {
    throw ArgumentError.value(
      capabilities,
      'requestedCapabilities',
      'capability names must be non-empty',
    );
  }
  return Map<String, bool>.unmodifiable(capabilities);
}

Uri _metadataUri(Uri baseUri) {
  final pathSegments = baseUri.pathSegments.toList();
  while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
    pathSegments.removeLast();
  }
  pathSegments.add('_meta');
  return Uri(
    scheme: baseUri.scheme,
    userInfo: baseUri.userInfo,
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
    pathSegments: pathSegments,
  );
}

ServerHandshakeMetadata _parseMetadata(Object? json) {
  if (json is! Map<Object?, Object?> ||
      !_hasExactKeys(json, const <String>{
        'packageVersion',
        'protocolVersion',
        'schemaVersion',
        'enabledFeatures',
        'supportedProtocolRange',
      })) {
    throw const FormatException();
  }

  final rangeJson = json['supportedProtocolRange'];
  if (rangeJson is! Map<Object?, Object?> ||
      !_hasExactKeys(
        rangeJson,
        const <String>{'minimumVersion', 'maximumVersion'},
      )) {
    throw const FormatException();
  }

  final metadata = ServerHandshakeMetadata.fromJson(json);
  final range = metadata.supportedProtocolRange;
  if (metadata.packageVersion.trim().isEmpty ||
      metadata.protocolVersion < 1 ||
      metadata.schemaVersion < 0 ||
      range.minimumVersion < 1 ||
      range.maximumVersion < 1 ||
      range.minimumVersion > range.maximumVersion ||
      metadata.protocolVersion < range.minimumVersion ||
      metadata.protocolVersion > range.maximumVersion ||
      metadata.enabledFeatures.values.keys.any((name) => name.trim().isEmpty)) {
    throw const FormatException();
  }
  return metadata;
}

bool _hasExactKeys(
  Map<Object?, Object?> object,
  Set<String> expected,
) =>
    object.length == expected.length &&
    object.keys.every((key) => key is String && expected.contains(key));

Map<String, bool> _negotiateCapabilities(
  Map<String, bool> requested,
  Map<String, bool> server,
) {
  final names = <String>{...requested.keys, ...server.keys};
  return Map<String, bool>.unmodifiable(<String, bool>{
    for (final name in names)
      name: requested[name] == true && server[name] == true,
  });
}
