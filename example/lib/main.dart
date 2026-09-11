import 'dart:async';
import 'dart:convert';

import 'shared_storage_lab.dart';
import 'backend_lab.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:handrail_chat/testing.dart';

part 'reply_style_scenario.dart';

const _publicChannelId = ConversationId('flutter-public-channel');
const _privateChannelId = ConversationId('flutter-private-channel');
const _directConversationId = ConversationId('flutter-direct');
const _groupDirectConversationId = ConversationId('flutter-group-direct');
const _createdPublicChannelId =
    ConversationId('flutter-created-public-channel');
const _createdPrivateChannelId =
    ConversationId('flutter-created-private-channel');
const _createdDirectConversationId = ConversationId('flutter-created-direct');
const _createdGroupDirectConversationId =
    ConversationId('flutter-created-group-direct');
const _unavailableConversationId = ConversationId('flutter-unavailable');
const _seededThreadId = ConversationId('flutter-thread-seeded');
const _createdThreadId = ConversationId('flutter-thread-created');
const _seededThreadRootId = MessageId('message-sent');
const _zeroReplyThreadRootId = MessageId('message-zero-reply-root');
const _attachmentMessageId = MessageId('message-with-attachment');
const _forwardedMessageId = MessageId('message-forwarded-private');
const _conversationIds = <ConversationId>[
  _publicChannelId,
  _privateChannelId,
  _directConversationId,
  _groupDirectConversationId,
];
const _authorizedForwardDestinationIds = <ConversationId>[
  _privateChannelId,
];
const _tenantId = 'tenant-flutter-timeline-lab';
const _currentUserId = 'ada';
const _huddleSessionId = HuddleSessionId('flutter-huddle-session');
const _huddleHostUserId = UserId('ada');
const _huddleMemberUserId = UserId('grace');
const _huddleStartedAt = IsoTimestamp('2030-01-01T00:00:01.000Z');
const _huddleHostJoinedAt = IsoTimestamp('2030-01-01T00:00:02.000Z');
const _huddleMemberJoinedAt = IsoTimestamp('2030-01-01T00:00:03.000Z');
const _huddleLeftAt = IsoTimestamp('2030-01-01T00:00:04.000Z');
const _huddleEndedAt = IsoTimestamp('2030-01-01T00:00:05.000Z');
const _huddleMediaJoin = HuddleMediaJoinDescriptor(
  descriptor: 'opaque-flutter-preview-huddle-descriptor',
  expiresAt: IsoTimestamp('2030-01-01T00:04:00.000Z'),
);
const _initialPublicMemberListRevision = 7;
const _fixtureTime = '2026-08-28T19:30:00.000Z';
const _forwardedFixtureTime = '2026-08-28T19:35:00.000Z';
const _preferenceUpdatedAt = '2026-08-28T19:40:00.000Z';
const _timelineLabMuteUntil = IsoTimestamp('2030-02-03T04:05:06.000Z');
const _forwardedSourceText =
    'Canonical sent fixture — open Remind me to inspect the Flutter sheet.';
const _directSearchText = 'Direct conversation canonical rendezvous timeline';
const _inaccessiblePrivateSearchText =
    'Vaulted saffron note from an inaccessible private channel';
const _searchCursorPrefix = 'timeline-lab:';

/// Deterministic authenticated actors used by the preview huddle fixture.
enum TimelineLabHuddleActor {
  host(_huddleHostUserId),
  member(_huddleMemberUserId);

  const TimelineLabHuddleActor(this.userId);

  final UserId userId;
}

/// Deterministic send outcomes available to preview and widget-test harnesses.
enum TimelineLabSendResponse {
  applied,
  recoverableFailure,
  persistentFailure,
}

HuddleSessionId _sessionIdFor(ConversationId conversationId) =>
    conversationId == _publicChannelId
        ? _huddleSessionId
        : HuddleSessionId('flutter-huddle-${conversationId.value}');

IsoTimestamp _joinedAtFor(TimelineLabHuddleActor actor) =>
    actor == TimelineLabHuddleActor.host
        ? _huddleHostJoinedAt
        : _huddleMemberJoinedAt;

ActiveHuddleState _seededActiveHuddleState(
  TimelineLabHuddleActor currentActor,
) =>
    ActiveHuddleState(
      conversationId: _publicChannelId,
      huddleSessionId: _huddleSessionId,
      startedAt: _huddleStartedAt,
      participants: <HuddleParticipant>[
        if (currentActor != TimelineLabHuddleActor.host)
          const HuddleJoinedParticipant(
            userId: _huddleHostUserId,
            joinedAt: _huddleHostJoinedAt,
          ),
        if (currentActor != TimelineLabHuddleActor.member)
          const HuddleJoinedParticipant(
            userId: _huddleMemberUserId,
            joinedAt: _huddleMemberJoinedAt,
          ),
      ],
      screenShareOwnerUserId: null,
    );

const _timelineLabMediaDevices = <ChatMediaDevice>[
  ChatMediaDevice(
    id: 'timeline-built-in-microphone',
    kind: ChatMediaDeviceKind.audioInput,
    label: 'Built-in microphone',
    isDefault: true,
  ),
  ChatMediaDevice(
    id: 'timeline-usb-microphone',
    kind: ChatMediaDeviceKind.audioInput,
    label: 'Preview USB microphone',
  ),
  ChatMediaDevice(
    id: 'timeline-built-in-speaker',
    kind: ChatMediaDeviceKind.audioOutput,
    label: 'Built-in speaker',
    isDefault: true,
  ),
  ChatMediaDevice(
    id: 'timeline-headphones',
    kind: ChatMediaDeviceKind.audioOutput,
    label: 'Preview headphones',
  ),
];

/// Development-only, deterministic media edge for the Mobile Preview lab.
///
/// This delegate never initializes a WebRTC/native media provider and never
/// reads, logs, or retains the opaque join descriptor. It creates only local
/// in-memory sessions whose devices, permissions, speaker changes, and cleanup
/// are directly observable by focused example tests.
final class TimelineLabLocalMediaDelegate implements ChatMediaDelegate {
  TimelineLabLocalMediaDelegate({
    Map<ChatMediaPermission, ChatMediaPermissionDecision> permissionDecisions =
        const {},
  }) : _permissionDecisions = Map.unmodifiable(permissionDecisions);

  final Map<ChatMediaPermission, ChatMediaPermissionDecision>
      _permissionDecisions;
  final List<ChatMediaPermission> _permissionRequests = [];
  final List<TimelineLabLocalMediaProviderSession> _sessions = [];

  List<ChatMediaPermission> get permissionRequests =>
      List.unmodifiable(_permissionRequests);
  List<TimelineLabLocalMediaProviderSession> get sessions =>
      List.unmodifiable(_sessions);
  int get connectCount => _sessions.length;

  @override
  Future<ChatMediaPermissionDecision> requestPermission(
    ChatMediaPermission permission,
  ) async {
    _permissionRequests.add(permission);
    return _permissionDecisions[permission] ??
        ChatMediaPermissionDecision.granted;
  }

  @override
  Future<ChatMediaProviderSession> connect(
    HuddleMediaJoinDescriptor descriptor,
  ) async {
    // The descriptor is deliberately not inspected or retained. Its sole role
    // is to satisfy the same boundary a real host provider would implement.
    final session = TimelineLabLocalMediaProviderSession();
    _sessions.add(session);
    return session;
  }
}

/// One entirely local development session created by the preview delegate.
final class TimelineLabLocalMediaProviderSession
    implements ChatMediaProviderSession {
  TimelineLabLocalMediaProviderSession() {
    _deviceChanges = StreamController<ChatMediaDeviceState>.broadcast(
      sync: true,
      onListen: () => deviceSubscriptionCount += 1,
      onCancel: () => deviceSubscriptionCancelCount += 1,
    );
    _activeSpeakerChanges =
        StreamController<List<ChatMediaActiveSpeaker>>.broadcast(
      sync: true,
      onListen: () => activeSpeakerSubscriptionCount += 1,
      onCancel: () => activeSpeakerSubscriptionCancelCount += 1,
    );
  }

  late final StreamController<ChatMediaDeviceState> _deviceChanges;
  late final StreamController<List<ChatMediaActiveSpeaker>>
      _activeSpeakerChanges;
  final List<bool> microphoneChanges = [];
  final List<bool> screenShareChanges = [];
  final List<String?> selectedAudioInputs = [];
  final List<String?> selectedAudioOutputs = [];
  int deviceSubscriptionCount = 0;
  int deviceSubscriptionCancelCount = 0;
  int activeSpeakerSubscriptionCount = 0;
  int activeSpeakerSubscriptionCancelCount = 0;
  int mediaActivityCount = 0;
  int closeCount = 0;
  bool closed = false;
  bool microphoneTrackClosed = false;
  bool screenShareTrackClosed = false;
  bool remoteSubscriptionsClosed = false;
  bool deviceStreamClosed = false;
  bool activeSpeakerStreamClosed = false;

  @override
  ChatMediaProviderState get initialState => ChatMediaProviderState(
        devices: ChatMediaDeviceState(
          devices: _timelineLabMediaDevices,
          selectedAudioInputId: 'timeline-built-in-microphone',
          selectedAudioOutputId: 'timeline-built-in-speaker',
        ),
      );

  @override
  Stream<ChatMediaDeviceState> get deviceChanges => _deviceChanges.stream;

  @override
  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakerChanges =>
      _activeSpeakerChanges.stream;

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    _recordActivity();
    microphoneChanges.add(enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _recordActivity();
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    _recordActivity();
    screenShareChanges.add(enabled);
  }

  @override
  Future<void> selectAudioInput(String? deviceId) async {
    _recordActivity();
    selectedAudioInputs.add(deviceId);
  }

  @override
  Future<void> selectAudioOutput(String? deviceId) async {
    _recordActivity();
    selectedAudioOutputs.add(deviceId);
  }

  void emitActiveSpeakers(Iterable<ChatMediaActiveSpeaker> speakers) {
    _recordActivity();
    _activeSpeakerChanges.add(List.unmodifiable(speakers));
  }

  void emitDevices(ChatMediaDeviceState devices) {
    _recordActivity();
    _deviceChanges.add(devices);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeCount += 1;
    microphoneTrackClosed = true;
    screenShareTrackClosed = true;
    remoteSubscriptionsClosed = true;
    deviceStreamClosed = true;
    activeSpeakerStreamClosed = true;
    await _deviceChanges.close();
    await _activeSpeakerChanges.close();
  }

  void _recordActivity() {
    if (closed) {
      throw StateError('The local preview media session is closed.');
    }
    mediaActivityCount += 1;
  }
}

const _availableReactions = <HandrailReactionOption>[
  HandrailReactionOption(
    reactionKey: '👍',
    label: '👍',
    semanticLabel: 'Thumbs up',
  ),
  HandrailReactionOption(
    reactionKey: '❤️',
    label: '❤️',
    semanticLabel: 'Heart',
  ),
  HandrailReactionOption(
    reactionKey: '🎉',
    label: '🎉',
    semanticLabel: 'Celebrate',
  ),
];
const _seededReactionAggregates = <MessageReactionAggregate>[
  MessageReactionAggregate(
    reactionKey: '👍',
    count: 2,
    reactedByCurrentUser: false,
  ),
  MessageReactionAggregate(
    reactionKey: '❤️',
    count: 2,
    reactedByCurrentUser: true,
  ),
];

Future<IsoTimestamp?> _pickTimelineLabMuteUntil(
  BuildContext context,
  IsoTimestamp? currentMuteUntil,
) async =>
    _timelineLabMuteUntil;

List<CanonicalConversationMemberState> _seededCanonicalPublicMembers() => [
      CanonicalConversationMemberState(
        userId: const UserId('ada'),
        role: ConversationMembershipMemberRole.owner,
        state: ConversationMembershipMemberState.active,
        joinedAt: const IsoTimestamp(_fixtureTime),
        updatedAt: const IsoTimestamp(_fixtureTime),
      ),
      CanonicalConversationMemberState(
        userId: const UserId('grace'),
        role: ConversationMembershipMemberRole.moderator,
        state: ConversationMembershipMemberState.active,
        joinedAt: const IsoTimestamp(_fixtureTime),
        updatedAt: const IsoTimestamp(_fixtureTime),
      ),
      CanonicalConversationMemberState(
        userId: const UserId('margaret'),
        role: ConversationMembershipMemberRole.member,
        state: ConversationMembershipMemberState.active,
        joinedAt: const IsoTimestamp(_fixtureTime),
        updatedAt: const IsoTimestamp(_fixtureTime),
      ),
    ];

ConversationMembershipMutationResult _seededPublicMembershipResult() =>
    ConversationMembershipMutationResult(
      intent: ConversationMembershipMutationIntent.addMember,
      reconciliationStatus:
          ConversationMembershipReconciliationStatus.alreadyRequestedState,
      conversationId: _publicChannelId,
      expectedMemberListRevision: _initialPublicMemberListRevision,
      memberListRevision: _initialPublicMemberListRevision,
      memberUserId: const UserId('margaret'),
      targetUserId: const UserId('margaret'),
      requestedRole: ConversationMembershipMemberRole.member,
      members: _seededCanonicalPublicMembers(),
    );

const _timelineLabDirectoryRows = <HandrailMemberDirectoryRow>[
  HandrailMemberDirectoryRow(
    userId: UserId('ada'),
    displayName: 'Ada Lovelace',
  ),
  HandrailMemberDirectoryRow(
    userId: UserId('grace'),
    displayName: 'Grace Hopper',
  ),
  HandrailMemberDirectoryRow(
    userId: UserId('margaret'),
    displayName: 'Margaret Hamilton',
  ),
  HandrailMemberDirectoryRow(
    userId: UserId('katherine'),
    displayName: 'Katherine Johnson',
  ),
];

/// Deterministic, example-owned directory shared by every workspace picker.
Future<HandrailMemberDirectoryPage> searchTimelineLabMemberDirectory(
  HandrailMemberDirectorySearchRequest request,
) async {
  final query = request.query.trim().toLowerCase();
  final matchingRows = _timelineLabDirectoryRows
      .where((row) => row.displayName.toLowerCase().contains(query))
      .toList(growable: false);
  final offset =
      request.pageToken == null ? 0 : int.tryParse(request.pageToken!);
  if (offset == null ||
      offset < 0 ||
      offset >= matchingRows.length ||
      request.pageSize <= 0) {
    return HandrailMemberDirectoryPage(rows: const []);
  }

  final requestedEnd = offset + request.pageSize;
  final end =
      requestedEnd < matchingRows.length ? requestedEnd : matchingRows.length;
  return HandrailMemberDirectoryPage(
    rows: matchingRows.sublist(offset, end),
    nextPageToken: end < matchingRows.length ? '$end' : null,
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Uri.base.queryParameters['sharedStorage'] == '1'
        ? const SharedStorageLab()
        : const bool.fromEnvironment('HANDRAIL_CHAT_LAB_BACKEND') &&
                Uri.base.queryParameters['fixture'] != '1'
            ? const BackendChatLab()
            : const HandrailTimelineLabPreview(),
  );
}

/// Browser-ready acceptance composition for the authoritative chat workspace.
class HandrailTimelineLabPreview extends StatefulWidget {
  const HandrailTimelineLabPreview({
    this.workspaceTitle = 'Flutter HandrailMessageTimeline Lab',
    super.key,
  });

  final String workspaceTitle;

  @override
  State<HandrailTimelineLabPreview> createState() =>
      _HandrailTimelineLabPreviewState();
}

class _HandrailTimelineLabPreviewState
    extends State<HandrailTimelineLabPreview> {
  late final SemanticsHandle _handle;

  @override
  void initState() {
    super.initState();
    // Browser QA inspects this fixture without an attached screen reader. Keep
    // the web semantics tree active so live-region updates are observable.
    _handle = SemanticsBinding.instance.ensureSemantics();
  }

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HandrailTimelineLabApp(
        workspaceTitle: widget.workspaceTitle,
      );
}

class HandrailTimelineLabApp extends StatefulWidget {
  const HandrailTimelineLabApp({
    this.workspaceTitle = 'Flutter HandrailMessageTimeline Lab',
    this.searchDirectory = searchTimelineLabMemberDirectory,
    this.canCreateChannels = true,
    this.canCreateDirectConversations = true,
    this.canCreateGroupDirectConversations = true,
    this.canManageMembers = true,
    this.canManageNotificationPreferences = true,
    this.directCreationReconciliationStatus =
        ConversationCreationReconciliationStatus.created,
    this.groupDirectCreationReconciliationStatus =
        ConversationCreationReconciliationStatus.created,
    this.huddleActor = TimelineLabHuddleActor.host,
    this.seedActiveHuddle = false,
    this.sendResponse = TimelineLabSendResponse.applied,
    this.huddleMediaDelegate,
    this.onTransportRequest,
    this.replyStyleScenario,
    this.replyActor = TimelineLabReplyActor.bob,
    this.realtimeSession,
    super.key,
  });

  /// Retain this fixture across keyed app recreations to retain shared history.
  /// Null preserves the original Timeline Lab scenario.
  final TimelineLabReplyStyleScenario? replyStyleScenario;
  final TimelineLabReplyActor replyActor;

  /// Optional existing SDK transport hook for deterministic offline recovery.
  final ChatRealtimeSessionTransport? realtimeSession;
  final String workspaceTitle;
  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final bool canCreateChannels;
  final bool canCreateDirectConversations;
  final bool canCreateGroupDirectConversations;
  final bool canManageMembers;
  final bool canManageNotificationPreferences;
  final ConversationCreationReconciliationStatus
      directCreationReconciliationStatus;
  final ConversationCreationReconciliationStatus
      groupDirectCreationReconciliationStatus;
  final TimelineLabHuddleActor huddleActor;
  final bool seedActiveHuddle;
  final TimelineLabSendResponse sendResponse;
  final ChatMediaDelegate? huddleMediaDelegate;
  final ValueChanged<HandrailChatHttpRequest>? onTransportRequest;

  @override
  State<HandrailTimelineLabApp> createState() => _HandrailTimelineLabAppState();
}

class _HandrailTimelineLabAppState extends State<HandrailTimelineLabApp> {
  late final _TimelineLabTransport _transport;
  late final HandrailChatClient _client;
  late final ChatWidgetBuilders _builders;
  late final ChatApplicationDelegates _delegates;
  late final ChatMediaDelegate _huddleMediaDelegate;
  final FocusNode _searchResultFocusNode = FocusNode(
    debugLabel: 'Timeline lab search result message',
  );
  bool _replyScenarioReady = false;
  final _configuredReplyContexts = <MessageId>{};
  ConversationId _selectedConversationId = _publicChannelId;
  MessageId? _focusedSearchMessageId;

  @override
  void initState() {
    super.initState();
    _transport = _TimelineLabTransport(
      onRequest: widget.onTransportRequest,
      replyScenario: widget.replyStyleScenario,
      replyActor: widget.replyActor,
      directCreationReconciliationStatus:
          widget.directCreationReconciliationStatus,
      groupDirectCreationReconciliationStatus:
          widget.groupDirectCreationReconciliationStatus,
      huddleActor: widget.huddleActor,
      seedActiveHuddle: widget.seedActiveHuddle,
      sendResponse: widget.sendResponse,
    );
    _builders = ChatWidgetBuilders(message: _buildMessage);
    _delegates = ChatApplicationDelegates(
      openMessageSearchHit: _openMessageSearchHit,
    );
    _huddleMediaDelegate =
        widget.huddleMediaDelegate ?? TimelineLabLocalMediaDelegate();
    _client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://flutter-timeline-lab.invalid/api/chat'),
      tokenProvider: () async => 'flutter-timeline-lab-token',
      transport: _transport,
      localStorage: widget.replyStyleScenario?.storage,
      storageIdentity: widget.replyStyleScenario?.identity(widget.replyActor),
      realtimeSession: widget.realtimeSession,
      replyStyleIdentity: widget.replyStyleScenario == null
          ? null
          : ChatReplyStyleIdentity(
              tenantId: const TenantId(_tenantId),
              userId: widget.replyActor.userId,
            ),
      requestedCapabilities: <String, bool>{
        if (widget.replyStyleScenario != null) ..._replyScenarioFeatures,
        messageSearchFeature: true,
        'huddles': true,
      },
      generateClientMessageId: () =>
          widget.replyStyleScenario?.nextId('message') ??
          'flutter-timeline-client-message',
      generateIdempotencyKey: () =>
          widget.replyStyleScenario?.nextId('key') ??
          'flutter-timeline-idempotency-key',
      generateConversationClientRequestId: () =>
          'flutter-timeline-client-request',
      commandRetryOptions: const ChatCommandRetryOptions(maxAttempts: 1),
      huddleClock: () => DateTime.utc(2030),
      huddleTimerScheduler: (_, __) => () {},
    );
    if (widget.replyStyleScenario == null) {
      // This storage-free fixture has no session callback to activate identity.
      // Bind the same trusted actor as the transport before any controller is
      // created or hydrated. Reply scenarios retain their storage activation.
      _client.huddles.prepareActivation(
        ApplicationChatStorageIdentity(
          tenantId: const TenantId(_tenantId),
          userId: widget.huddleActor.userId,
          deviceId: DeviceId('huddle-lab-${widget.huddleActor.name}'),
        ),
        generation: 1,
      );
    }
    _transport.onDraftUpdated = (input, result) {
      final event = <String, Object?>{
        'eventId': 'reply-lab-draft-${input['deviceMutationId']}',
        'protocolVersion': handrailChatDurableEventProtocolVersion,
        'tenantId': _tenantId,
        'streamId': 'user:${widget.replyActor.userId.value}',
        'type': 'conversation.draft.updated',
        'occurredAt': _fixtureTime,
        'payload': {
          'actorUserId': widget.replyActor.userId.value,
          'input': input,
          'result': result,
        },
      };
      widget.replyStyleScenario?._draftEvents[(
        widget.replyActor,
        ConversationId(input['conversationId']! as String),
      )] = ConversationDraftUpdatedEvent.fromJson(
        event,
        expectedTenantId: const TenantId(_tenantId),
      );
      _client.reduceDurableEvent(
        KnownDurableEvent.fromJson(
          event,
          trustedIdentity: DurableEventTrustedIdentity(
            tenantId: const TenantId(_tenantId),
            userId: widget.replyActor.userId,
          ),
        ),
      );
    };
    _transport.onReplySent = (message, clientMessageId) {
      _client.reduceDurableEvent(
        KnownDurableEvent.fromJson(
          {
            'eventId': 'flutter-created-thread-reply-1',
            'protocolVersion': handrailChatDurableEventProtocolVersion,
            'tenantId': _tenantId,
            'streamId': _createdThreadId.value,
            'type': 'message.created',
            'occurredAt': _fixtureTime,
            'payload': {'message': message, 'clientMessageId': clientMessageId},
          },
          trustedIdentity: DurableEventTrustedIdentity(
            tenantId: const TenantId(_tenantId),
            userId: widget.replyStyleScenario == null
                ? const UserId(_currentUserId)
                : widget.replyActor.userId,
          ),
        ),
      );
    };
    _transport.onMessageSent = (conversationId, message, clientMessageId) {
      _configureReplyContexts();
      _client.reduceDurableEvent(
        KnownDurableEvent.fromJson(
          {
            'eventId': 'flutter-message-created-${message['id']}',
            'protocolVersion': handrailChatDurableEventProtocolVersion,
            'tenantId': _tenantId,
            'streamId': conversationId.value,
            'type': 'message.created',
            'occurredAt': _fixtureTime,
            'payload': {'message': message, 'clientMessageId': clientMessageId},
          },
          trustedIdentity: DurableEventTrustedIdentity(
            tenantId: const TenantId(_tenantId),
            userId: widget.replyStyleScenario == null
                ? const UserId(_currentUserId)
                : widget.replyActor.userId,
          ),
        ),
      );
    };
    if (widget.replyStyleScenario == null) {
      _client.normalizedState.hydrateConversationDetail(
        ConversationDetailSnapshot.fromJson(
          _conversationDetailFixtures[_publicChannelId]!,
        ),
      );
      _client.normalizedState.reconcileConversationMembership(
        _seededPublicMembershipResult(),
      );
      _client.normalizedState.hydrateMessageTimeline(
        MessageTimelinePage.fromJson(
          _timelineFixtures[_publicChannelId]!,
          request: const MessageTimelineRequest(
            conversationId: _publicChannelId,
            direction: MessageTimelineDirection.backward,
            limit: 50,
          ),
        ),
      );
      _client.normalizedState.beginOptimisticMessageSend(
        clientMessageId: 'client-message-optimistic',
        projection: MessageTimelineMessage.fromJson(
          _messageFixture(
            conversationId: _publicChannelId,
            id: 'message-optimistic',
            sequence: 5,
            authorId: _currentUserId,
            text: 'Optimistic unsent fixture',
          ),
        ),
      );
    }
    unawaited(
      _client.initialize().then((_) {
        if (!mounted || widget.replyStyleScenario == null) return;
        _client.normalizedState.hydrateConversationDetail(
          ConversationDetailSnapshot.fromJson(
            widget.replyStyleScenario!.detail(
              _publicChannelId,
              widget.replyActor,
            ),
          ),
        );
        _client.normalizedState.hydrateMessageTimeline(
          MessageTimelinePage.fromJson(
            widget.replyStyleScenario!.timeline(_publicChannelId),
            request: const MessageTimelineRequest(
              conversationId: _publicChannelId,
              direction: MessageTimelineDirection.backward,
              limit: 50,
            ),
          ),
        );
        // Replay the fixture's canonical private draft event through the public
        // runtime hook, as a host would after recreating its realtime binding.
        for (final entry in widget.replyStyleScenario!._draftEvents.entries) {
          if (entry.key.$1 == widget.replyActor) {
            _client.reconcileDraftEvent(entry.value);
          }
        }
        _configureReplyContexts();
        setState(() => _replyScenarioReady = true);
        for (final id in [
          TimelineLabReplyStyleScenario.discussionId,
          TimelineLabReplyStyleScenario.launchThreadId,
        ]) {
          final lifecycle = _client.threadLifecycles.forThread(id);
          lifecycle.setAuthority(
            ChatThreadLifecycleAuthority(
              tenantId: const TenantId(_tenantId),
              userId: widget.replyActor.userId,
              canRead: true,
              canSend: true,
              canManage: true,
            ),
          );
          if (widget.replyStyleScenario!._roots.containsKey(id)) {
            unawaited(lifecycle.load());
          }
        }
      }),
    );
  }

  void _configureReplyContexts() {
    final scenario = widget.replyStyleScenario;
    if (!mounted || scenario == null) return;
    for (final entry in scenario._messages.entries) {
      for (final message in entry.value) {
        final id = MessageId(message['id']! as String);
        if (!_configuredReplyContexts.add(id)) continue;
        final context = _client.messageContexts.forMessage(
          MessageContextRequest(conversationId: entry.key, messageId: id),
        );
        context.setAuthority(
          ChatMessageContextAuthority(
            tenantId: const TenantId(_tenantId),
            userId: widget.replyActor.userId,
            canRead: true,
          ),
        );
      }
    }
  }
  Widget _buildMessage(
    BuildContext context,
    ChatMessageBuilderInput input,
  ) {
    final message = defaultChatMessageBuilder(context, input);
    if (input.message.id != _focusedSearchMessageId) return message;
    if (!_searchResultFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            input.message.id == _focusedSearchMessageId &&
            _searchResultFocusNode.canRequestFocus) {
          _searchResultFocusNode.requestFocus();
        }
      });
    }
    return Focus(
      key: ValueKey<String>(
        'timeline-lab-search-focus-${input.message.id.value}',
      ),
      focusNode: _searchResultFocusNode,
      autofocus: true,
      child: message,
    );
  }

  Future<ChatApplicationDelegateResult> _openMessageSearchHit(
    HandrailMessageSearchHit hit,
  ) async {
    if (!mounted || !_conversationIds.contains(hit.conversationId)) {
      return ChatApplicationDelegateResult.unavailable;
    }
    setState(() {
      _selectedConversationId = hit.conversationId;
      _focusedSearchMessageId = switch (hit) {
        HandrailMessageSearchMessageHit(:final messageId) => messageId,
        HandrailMessageSearchConversationHit() => null,
      };
    });
    return ChatApplicationDelegateResult.handled;
  }

  ChatHuddleController _resolveHuddleController(
    HandrailChatClient client,
    ConversationId conversationId,
  ) {
    final controller = client.huddles.forConversation(conversationId);
    if (controller.state.hydrationStatus == ChatHuddleHydrationStatus.idle) {
      unawaited(controller.hydrate());
    }
    return controller;
  }

  @override
  void dispose() {
    _searchResultFocusNode.dispose();
    unawaited(_client.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widget.workspaceTitle,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff4f46e5)),
        useMaterial3: true,
      ),
      home: ChatScope(
        client: _client,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.workspaceTitle),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Card(
                margin: const EdgeInsets.all(16),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'HandrailChatWorkspace',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Public, private, direct, and group conversation fixtures',
                          ),
                          const SizedBox(height: 12),
                          _ReminderResponseControl(
                            transport: _transport,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: widget.replyStyleScenario != null && !_replyScenarioReady
                          ? const Center(child: CircularProgressIndicator())
                          : HandrailChatWorkspace(
                        initialConversationId: _selectedConversationId,
                        canCreateChannels: widget.canCreateChannels,
                        huddleController: _resolveHuddleController,
                        huddleMediaDelegate: _huddleMediaDelegate,
                        builders: _builders,
                        delegates: _delegates,
                        availableReactions: _availableReactions,
                        notificationControls:
                            HandrailChannelNotificationControls(
                          authorized: widget.canManageNotificationPreferences,
                          muteUntilPicker: _pickTimelineLabMuteUntil,
                        ),
                        members: widget.canManageMembers
                            ? HandrailWorkspaceMemberConfiguration(
                                searchDirectory: widget.searchDirectory,
                                authorization:
                                    const HandrailMemberPickerAuthorization(
                                  canAddMembers: true,
                                  canRemoveMembers: true,
                                  canChangeMemberRoles: true,
                                ),
                                defaultAddRole:
                                    ConversationMembershipMemberRole.member,
                                roleOptions: const [
                                  ConversationMembershipMemberRole.owner,
                                  ConversationMembershipMemberRole.moderator,
                                  ConversationMembershipMemberRole.member,
                                ],
                              )
                            : null,
                        directCreation:
                            HandrailWorkspaceDirectCreationConfiguration(
                          authorized: widget.canCreateDirectConversations,
                          searchDirectory: widget.searchDirectory,
                        ),
                        groupDirectCreation:
                            HandrailWorkspaceGroupDirectCreationConfiguration(
                          authorized: widget.canCreateGroupDirectConversations,
                          searchDirectory: widget.searchDirectory,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _TimelineLabReminderResponse {
  applied('Apply normally'),
  sanitizedError('Return sanitized error'),
  revisionConflict('Return revision conflict');

  const _TimelineLabReminderResponse(this.label);

  final String label;
}

class _ReminderResponseControl extends StatefulWidget {
  const _ReminderResponseControl({
    required this.transport,
  });

  final _TimelineLabTransport transport;

  @override
  State<_ReminderResponseControl> createState() =>
      _ReminderResponseControlState();
}

class _ReminderResponseControlState extends State<_ReminderResponseControl> {
  late _TimelineLabReminderResponse _value;

  @override
  void initState() {
    super.initState();
    _value = widget.transport.reminderResponse;
  }

  @override
  void didUpdateWidget(covariant _ReminderResponseControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.transport, widget.transport)) {
      _value = widget.transport.reminderResponse;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<_TimelineLabReminderResponse>(
      key: const ValueKey<String>('timeline-lab-reminder-response'),
      isExpanded: true,
      // Keep the lab compatible with Flutter 3.19.
      // ignore: deprecated_member_use
      value: _value,
      decoration: const InputDecoration(
        labelText: 'Next reminder response',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final response in _TimelineLabReminderResponse.values)
          DropdownMenuItem(value: response, child: Text(response.label)),
      ],
      onChanged: (response) {
        if (response == null) return;
        setState(() {
          _value = response;
          widget.transport.reminderResponse = response;
        });
      },
    );
  }
}

final class _TimelineLabTransport implements HandrailChatHttpTransport {
  _TimelineLabTransport({
    this.onRequest,
    this.replyScenario,
    this.replyActor = TimelineLabReplyActor.bob,
    this.directCreationReconciliationStatus =
        ConversationCreationReconciliationStatus.created,
    this.groupDirectCreationReconciliationStatus =
        ConversationCreationReconciliationStatus.created,
    this.huddleActor = TimelineLabHuddleActor.host,
    this.seedActiveHuddle = false,
    this.sendResponse = TimelineLabSendResponse.applied,
  })  : _publicMembers = _seededCanonicalPublicMembers(),
        _huddleStates = <ConversationId, HuddleSessionState>{
          _publicChannelId: seedActiveHuddle
              ? _seededActiveHuddleState(huddleActor)
              : const InactiveHuddleState(
                  conversationId: _publicChannelId,
                ),
        } {
    if (seedActiveHuddle) {
      _huddleHosts[_publicChannelId] = _huddleHostUserId;
    }
  }

  final TimelineLabReplyStyleScenario? replyScenario;
  final TimelineLabReplyActor replyActor;
  final ValueChanged<HandrailChatHttpRequest>? onRequest;
  final ConversationCreationReconciliationStatus
      directCreationReconciliationStatus;
  final ConversationCreationReconciliationStatus
      groupDirectCreationReconciliationStatus;
  final TimelineLabHuddleActor huddleActor;
  final bool seedActiveHuddle;
  final TimelineLabSendResponse sendResponse;
  final Map<ConversationId, HuddleSessionState> _huddleStates;
  final Map<ConversationId, UserId> _huddleHosts = {};
  final Map<String, MessageReactionAggregate> _reactionAggregates = {
    for (final aggregate in _seededReactionAggregates)
      aggregate.reactionKey: aggregate,
  };
  final Map<ConversationId, Map<String, Object?>>
      _createdConversationSummaries = {};
  final Map<ConversationId, Map<String, Object?>> _createdConversationDetails =
      {};
  final Map<ConversationId, Map<String, Object?>> _createdTimelines = {};
  final Map<ConversationId, List<Map<String, Object?>>> _sentMessages = {};
  final Map<ConversationId, CanonicalConversationPreferenceState>
      _conversationPreferences = {};
  final Map<ConversationId, int> _preferenceRevisions = {};
  List<CanonicalConversationMemberState> _publicMembers;
  var _publicMemberListRevision = _initialPublicMemberListRevision;
  void Function(Map<String, Object?> message, String clientMessageId)?
      onReplySent;
  void Function(
    ConversationId conversationId,
    Map<String, Object?> message,
    String clientMessageId,
  )? onMessageSent;
  void Function(Map<String, Object?> input, Map<String, Object?> result)? onDraftUpdated;
  bool _createdThreadExists = false;
  Map<String, Object?>? _createdThreadReply;
  Map<String, Object?>? _forwardedPrivateMessage;
  ConversationReadState _publicReadState = ConversationReadState(
    conversationId: _publicChannelId,
    userId: const UserId(_currentUserId),
    lastReadSequence: const MessageSequence(4),
    manualUnreadFromSequence: const MessageSequence(1),
    updatedAt: const IsoTimestamp(_fixtureTime),
  );
  var _readCursorMutationRevision = 0;
  var _reminderRevision = 0;
  var _recoverableSendFailureReturned = false;
  var reminderResponse = _TimelineLabReminderResponse.applied;

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    onRequest?.call(request);
    if (replyScenario != null) {
      final response = replyScenario!._respond(request, replyActor, this);
      if (response != null) return response;
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return _jsonResponse(ServerHandshakeMetadata.fromJson(<String, Object?>{
        'packageVersion': handrailChatPackageVersion,
        'protocolVersion': handrailChatProtocolVersion,
        'schemaVersion': 9,
        'enabledFeatures': <String, bool>{
          messageSearchFeature: true,
          'huddles': true,
          if (replyScenario != null) ..._replyScenarioFeatures,
        },
        'supportedProtocolRange': <String, Object?>{
          'minimumVersion': handrailChatProtocolVersion,
          'maximumVersion': handrailChatProtocolVersion,
        },
      }).toJson());
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/huddle')) {
      final segments = request.uri.pathSegments;
      final conversationId = ConversationId(segments[segments.length - 2]);
      final state = _huddleStates.putIfAbsent(
        conversationId,
        () => InactiveHuddleState(conversationId: conversationId),
      );
      return _jsonResponse(state.toJson());
    }
    if ((request.method == 'POST' || request.method == 'PATCH') &&
        request.body != null &&
        (request.uri.path.endsWith('/huddles') ||
            request.uri.pathSegments.contains('huddles'))) {
      return _handleHuddleCommand(request);
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/search')) {
      return _searchMessages(request);
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/messages')) {
      final segments = request.uri.pathSegments;
      final conversationId = ConversationId(segments[segments.length - 2]);
      final fixture = _timelineFor(conversationId);
      return fixture == null
          ? _jsonResponse(const {'error': 'unknown conversation'}, 404)
          : _jsonResponse(fixture);
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/messages/forward')) {
      return _forwardMessage(request);
    }
    if (request.method == 'POST' && request.uri.pathSegments.last == 'thread') {
      return _openThread(request);
    }
    if (request.method == 'POST' &&
        request.uri.path
            .endsWith('/conversations/${_createdThreadId.value}/messages')) {
      return _sendCreatedThreadReply(request);
    }
    if (request.method == 'POST' && request.uri.path.endsWith('/messages')) {
      return _sendMessage(request);
    }
    if (request.method == 'PATCH' &&
        request.uri.pathSegments.length >= 4 &&
        request.uri.pathSegments[request.uri.pathSegments.length - 4] ==
            'messages' &&
        request.uri.pathSegments[request.uri.pathSegments.length - 2] ==
            'reactions') {
      return _mutateReaction(request);
    }
    if (request.method == readCursorMutationMethod &&
        request.uri.path.endsWith('/read-cursor')) {
      return _mutateReadCursor(request);
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/conversations')) {
      return _createConversation(request);
    }
    if (request.method == 'PATCH' && request.uri.path.endsWith('/membership')) {
      return _mutateConversationMembership(request);
    }
    if (request.method == 'PATCH' && request.uri.path.endsWith('/preference')) {
      return _updateConversationPreference(request);
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/conversations')) {
      return _jsonResponse(_conversationListResponse());
    }
    if (request.method == 'GET' &&
        request.uri.pathSegments.contains('conversations')) {
      final conversationId = ConversationId(request.uri.pathSegments.last);
      final fixture = switch (conversationId) {
        _seededThreadId => _threadConversationDetailFixture(
            threadId: _seededThreadId,
            rootMessageId: _seededThreadRootId,
            latestSequence: 1,
          ),
        _createdThreadId when _createdThreadExists =>
          _threadConversationDetailFixture(
            threadId: _createdThreadId,
            rootMessageId: _zeroReplyThreadRootId,
            latestSequence: _createdThreadReply == null ? 0 : 1,
          ),
        _publicChannelId => _publicConversationDetailResponse(),
        _ => _createdConversationDetails[conversationId] ??
            _conversationDetailFixtures[conversationId],
      };
      return fixture == null
          ? _jsonResponse(const {'error': 'unknown conversation'}, 404)
          : _jsonResponse(
              _conversationDetailResponse(conversationId, fixture),
            );
    }
    if (request.method == 'PATCH' && request.uri.path.endsWith('/draft')) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      return _jsonResponse(_draftMutationResult(body));
    }
    if (request.method == 'PUT' && request.uri.path.endsWith('/reminder')) {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      final intent = body['intent']! as String;
      // Keep pending feedback visible long enough for a browser harness to
      // assert disabled controls and prove rapid submissions do not overlap.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (reminderResponse == _TimelineLabReminderResponse.sanitizedError) {
        return _jsonResponse(
          const {
            'error': {
              'code': 'UPSTREAM_FIXTURE_FAILURE',
              'message': 'private upstream reminder fixture detail',
            },
          },
          422,
        );
      }
      final expectedRevision = body['expectedReminderRevision']! as int;
      final isConflict =
          reminderResponse == _TimelineLabReminderResponse.revisionConflict;
      _reminderRevision = expectedRevision + (isConflict ? 2 : 1);
      return _jsonResponse({
        'operation': 'message_reminder.v1',
        'intent': intent,
        'reconciliationStatus': isConflict ? 'revision-conflict' : 'applied',
        'conversationId': body['conversationId'],
        'messageId': body['messageId'],
        'expectedReminderRevision': body['expectedReminderRevision'],
        'idempotencyKey': body['idempotencyKey'],
        'reminderRevision': _reminderRevision,
        'reminder': isConflict
            ? const <String, Object?>{
                'privacy': 'affected_authenticated_actor',
                'state': 'scheduled',
                'dueAt': '2030-03-12T18:00:00.000Z',
              }
            : intent == 'cancel'
                ? const <String, Object?>{
                    'privacy': 'affected_authenticated_actor',
                    'state': 'cancelled',
                  }
                : <String, Object?>{
                    'privacy': 'affected_authenticated_actor',
                    'state': 'scheduled',
                    'dueAt': body['dueAt'],
                  },
      });
    }
    return _jsonResponse(const {'error': 'unsupported fixture request'}, 400);
  }

  HandrailChatHttpResponse _handleHuddleCommand(
    HandrailChatHttpRequest request,
  ) {
    late final HuddleCommandInput input;
    try {
      input = HuddleCommandInput.fromJson(jsonDecode(request.body!));
    } on FormatException {
      return _jsonResponse(const {'error': 'invalid huddle command'}, 400);
    }

    if (input is StartHuddleInput) {
      final startInput = input;
      final segments = request.uri.pathSegments;
      final pathConversationId = ConversationId(segments[segments.length - 2]);
      final previous = _huddleStates.putIfAbsent(
        startInput.conversationId,
        () => InactiveHuddleState(conversationId: startInput.conversationId),
      );
      if (request.method != 'POST' ||
          pathConversationId != startInput.conversationId ||
          previous is! InactiveHuddleState) {
        return _jsonResponse(const {'error': 'invalid huddle start'}, 409);
      }
      if (huddleActor != TimelineLabHuddleActor.host) {
        return _deniedHuddleResponse();
      }
      final state = StartingHuddleState(
        conversationId: startInput.conversationId,
        huddleSessionId: _sessionIdFor(startInput.conversationId),
        startedAt: _huddleStartedAt,
        participants: const <HuddleParticipant>[],
        screenShareOwnerUserId: null,
      );
      _huddleStates[startInput.conversationId] = state;
      _huddleHosts[startInput.conversationId] = huddleActor.userId;
      return _jsonResponse(
        StartHuddleResult(
          reconciliationStatus: HuddleReconciliationStatus.applied,
          state: state,
          mediaJoin: _huddleMediaJoin,
        ).toJson(),
      );
    }

    final sessionInput = input as SessionHuddleInput;
    final conversationId = _conversationForSession(
      sessionInput.huddleSessionId,
    );
    if (conversationId == null ||
        request.uri.pathSegments[request.uri.pathSegments.length - 2] !=
            sessionInput.huddleSessionId.value) {
      return _jsonResponse(const {'error': 'unknown huddle session'}, 404);
    }
    final previous = _huddleStates[conversationId]!;
    if (input is JoinHuddleInput && previous is LiveHuddleState) {
      final actor = _participant(previous.participants, huddleActor.userId);
      if (actor is HuddleJoinedParticipant) {
        return _jsonResponse(const {'error': 'actor already joined'}, 409);
      }
      final state = ActiveHuddleState(
        conversationId: conversationId,
        huddleSessionId: previous.huddleSessionId,
        startedAt: previous.startedAt,
        participants: <HuddleParticipant>[
          for (final participant in previous.participants)
            if (participant.userId == huddleActor.userId)
              HuddleJoinedParticipant(
                userId: huddleActor.userId,
                joinedAt: _joinedAtFor(huddleActor),
              )
            else
              participant,
          if (actor == null)
            HuddleJoinedParticipant(
              userId: huddleActor.userId,
              joinedAt: _joinedAtFor(huddleActor),
            ),
        ],
        screenShareOwnerUserId: previous.screenShareOwnerUserId,
      );
      _huddleStates[conversationId] = state;
      return _jsonResponse(
        JoinHuddleResult(
          reconciliationStatus: HuddleReconciliationStatus.applied,
          state: state,
          mediaJoin: _huddleMediaJoin,
        ).toJson(),
      );
    }
    if (input is LeaveHuddleInput && previous is ActiveHuddleState) {
      final actor = _participant(previous.participants, huddleActor.userId);
      if (actor is! HuddleJoinedParticipant) {
        return _jsonResponse(const {'error': 'actor is not joined'}, 409);
      }
      final state = ActiveHuddleState(
        conversationId: conversationId,
        huddleSessionId: previous.huddleSessionId,
        startedAt: previous.startedAt,
        participants: [
          for (final participant in previous.participants)
            if (participant.userId == huddleActor.userId)
              HuddleLeftParticipant(
                userId: participant.userId,
                joinedAt: participant.joinedAt,
                leftAt: _huddleLeftAt,
              )
            else
              participant,
        ],
        screenShareOwnerUserId:
            previous.screenShareOwnerUserId == huddleActor.userId
                ? null
                : previous.screenShareOwnerUserId,
      );
      _huddleStates[conversationId] = state;
      return _jsonResponse(
        LeaveHuddleResult(
          reconciliationStatus: HuddleReconciliationStatus.applied,
          state: state,
        ).toJson(),
      );
    }
    if (input is SetHuddleScreenShareInput && previous is ActiveHuddleState) {
      final actor = _participant(previous.participants, huddleActor.userId);
      if (actor is! HuddleJoinedParticipant) {
        return _jsonResponse(const {'error': 'actor is not joined'}, 409);
      }
      final state = ActiveHuddleState(
        conversationId: conversationId,
        huddleSessionId: previous.huddleSessionId,
        startedAt: previous.startedAt,
        participants: previous.participants,
        screenShareOwnerUserId: input.intent == HuddleScreenShareIntent.set
            ? huddleActor.userId
            : null,
      );
      _huddleStates[conversationId] = state;
      return _jsonResponse(
        SetHuddleScreenShareResult(
          reconciliationStatus: HuddleReconciliationStatus.applied,
          state: state,
        ).toJson(),
      );
    }
    if (input is EndHuddleInput && previous is LiveHuddleState) {
      if (_huddleHosts[conversationId] != huddleActor.userId) {
        return _deniedHuddleResponse();
      }
      final state = EndedHuddleState(
        conversationId: conversationId,
        huddleSessionId: previous.huddleSessionId,
        startedAt: previous.startedAt,
        endedAt: _huddleEndedAt,
        endedByUserId: huddleActor.userId,
        participants: [
          for (final participant in previous.participants)
            participant is HuddleLeftParticipant
                ? participant
                : HuddleLeftParticipant(
                    userId: participant.userId,
                    joinedAt: participant.joinedAt,
                    leftAt: _huddleEndedAt,
                  ),
        ],
      );
      _huddleStates[conversationId] = state;
      return _jsonResponse(
        EndHuddleResult(
          reconciliationStatus: HuddleReconciliationStatus.applied,
          state: state,
        ).toJson(),
      );
    }

    return _jsonResponse(const {'error': 'invalid huddle transition'}, 409);
  }

  HandrailChatHttpResponse _deniedHuddleResponse() => _jsonResponse(
        const {
          'error': {
            'code': 'HUDDLE_HOST_REQUIRED',
            'message': 'private huddle authorization fixture detail',
          },
        },
        403,
      );

  ConversationId? _conversationForSession(HuddleSessionId sessionId) {
    for (final entry in _huddleStates.entries) {
      final state = entry.value;
      if (state is LiveHuddleState && state.huddleSessionId == sessionId ||
          state is EndedHuddleState && state.huddleSessionId == sessionId) {
        return entry.key;
      }
    }
    return null;
  }

  HuddleParticipant? _participant(
    Iterable<HuddleParticipant> participants,
    UserId userId,
  ) {
    for (final participant in participants) {
      if (participant.userId == userId) return participant;
    }
    return null;
  }

  HandrailChatHttpResponse _mutateConversationMembership(
    HandrailChatHttpRequest request,
  ) {
    late final ConversationMembershipMutationInput input;
    try {
      input = ConversationMembershipMutationInput.fromJson(
        jsonDecode(request.body ?? ''),
      );
    } on FormatException {
      return _jsonResponse(
        const {'error': 'invalid conversation membership mutation'},
        400,
      );
    }

    final pathConversationId = ConversationId(
      request.uri.pathSegments[request.uri.pathSegments.length - 2],
    );
    if (input.conversationId != _publicChannelId ||
        pathConversationId != input.conversationId ||
        input.targetUserId == null ||
        (input.intent != ConversationMembershipMutationIntent.addMember &&
            input.intent != ConversationMembershipMutationIntent.removeMember &&
            input.intent !=
                ConversationMembershipMutationIntent.changeMemberRole)) {
      return _jsonResponse(
        const {'error': 'unsupported conversation membership mutation'},
        400,
      );
    }

    if (input.expectedMemberListRevision != _publicMemberListRevision) {
      return _jsonResponse(
        _publicMembershipResult(
          input,
          ConversationMembershipReconciliationStatus.memberListConflict,
        ).toJson(),
        409,
      );
    }

    final targetUserId = input.targetUserId!;
    final existing = _publicMember(targetUserId);
    switch (input.intent) {
      case ConversationMembershipMutationIntent.addMember:
        final requestedRole = input.requestedRole!;
        if (existing?.state == ConversationMembershipMemberState.active &&
            existing?.role == requestedRole) {
          return _jsonResponse(
            _publicMembershipResult(
              input,
              ConversationMembershipReconciliationStatus.alreadyRequestedState,
            ).toJson(),
          );
        }
        _upsertPublicMember(
          userId: targetUserId,
          role: requestedRole,
          state: ConversationMembershipMemberState.active,
          joinedAt: existing?.joinedAt ?? const IsoTimestamp(_fixtureTime),
        );
      case ConversationMembershipMutationIntent.removeMember:
        if (existing == null) {
          return _jsonResponse(const {'error': 'unknown member'}, 404);
        }
        if (existing.state == ConversationMembershipMemberState.removed) {
          return _jsonResponse(
            _publicMembershipResult(
              input,
              ConversationMembershipReconciliationStatus.alreadyRequestedState,
            ).toJson(),
          );
        }
        if (existing.state != ConversationMembershipMemberState.active) {
          return _jsonResponse(const {'error': 'inactive member'}, 409);
        }
        if (_wouldEliminateLastOwner(existing, null)) {
          return _lastOwnerSafetyResponse(input);
        }
        _upsertPublicMember(
          userId: targetUserId,
          role: existing.role,
          state: ConversationMembershipMemberState.removed,
          joinedAt: existing.joinedAt,
        );
      case ConversationMembershipMutationIntent.changeMemberRole:
        final requestedRole = input.requestedRole!;
        if (existing == null ||
            existing.state != ConversationMembershipMemberState.active) {
          return _jsonResponse(const {'error': 'inactive member'}, 409);
        }
        if (existing.role == requestedRole) {
          return _jsonResponse(
            _publicMembershipResult(
              input,
              ConversationMembershipReconciliationStatus.alreadyRequestedState,
            ).toJson(),
          );
        }
        if (_wouldEliminateLastOwner(existing, requestedRole)) {
          return _lastOwnerSafetyResponse(input);
        }
        _upsertPublicMember(
          userId: targetUserId,
          role: requestedRole,
          state: existing.state,
          joinedAt: existing.joinedAt,
        );
      case ConversationMembershipMutationIntent.join ||
            ConversationMembershipMutationIntent.leave:
        return _jsonResponse(
          const {'error': 'unsupported conversation membership mutation'},
          400,
        );
    }

    _publicMemberListRevision += 1;
    return _jsonResponse(
      _publicMembershipResult(
        input,
        ConversationMembershipReconciliationStatus.applied,
      ).toJson(),
    );
  }

  HandrailChatHttpResponse _updateConversationPreference(
    HandrailChatHttpRequest request,
  ) {
    late final UpdateConversationPreferenceInput input;
    try {
      input = UpdateConversationPreferenceInput.fromJson(
        jsonDecode(request.body ?? ''),
      );
    } on FormatException {
      return _jsonResponse(
        const {'error': 'invalid conversation preference update'},
        400,
      );
    }

    final pathConversationId = ConversationId(
      request.uri.pathSegments[request.uri.pathSegments.length - 2],
    );
    if (pathConversationId != input.conversationId ||
        !_hasConversation(input.conversationId)) {
      return _jsonResponse(
        const {'error': 'unknown conversation preference'},
        404,
      );
    }

    final revision = _preferenceRevisions[input.conversationId] ?? 0;
    final canonical = _canonicalPreference(input.conversationId);
    if (input.expectedPreferenceRevision != revision) {
      return _jsonResponse(
        _preferenceResult(
          input,
          ConversationPreferenceReconciliationStatus.preferenceRevisionConflict,
          preferenceRevision: revision,
          preference: canonical,
        ).toJson(),
        409,
      );
    }

    if (_samePreference(input.preference, canonical.preference)) {
      return _jsonResponse(
        _preferenceResult(
          input,
          ConversationPreferenceReconciliationStatus.alreadyRequestedState,
          preferenceRevision: revision,
          preference: canonical,
        ).toJson(),
      );
    }

    final nextPreference = CanonicalConversationPreferenceState(
      preference: input.preference,
      updatedAt: const IsoTimestamp(_preferenceUpdatedAt),
    );
    final nextRevision = revision + 1;
    _conversationPreferences[input.conversationId] = nextPreference;
    _preferenceRevisions[input.conversationId] = nextRevision;
    return _jsonResponse(
      _preferenceResult(
        input,
        ConversationPreferenceReconciliationStatus.applied,
        preferenceRevision: nextRevision,
        preference: nextPreference,
      ).toJson(),
    );
  }

  bool _hasConversation(ConversationId conversationId) =>
      _conversationIds.contains(conversationId) ||
      _createdConversationDetails.containsKey(conversationId) ||
      conversationId == _seededThreadId ||
      (conversationId == _createdThreadId && _createdThreadExists);

  CanonicalConversationPreferenceState _canonicalPreference(
    ConversationId conversationId,
  ) =>
      _conversationPreferences.putIfAbsent(
        conversationId,
        () => CanonicalConversationPreferenceState(
          preference: const ConversationPreferenceDesiredState(
            notificationPreference: ConversationNotificationPreference.all,
            mute: UnmutedConversationPreference(),
            isStarred: false,
          ),
          updatedAt: const IsoTimestamp(_fixtureTime),
        ),
      );

  UpdateConversationPreferenceResult _preferenceResult(
    UpdateConversationPreferenceInput input,
    ConversationPreferenceReconciliationStatus status, {
    required int preferenceRevision,
    required CanonicalConversationPreferenceState preference,
  }) =>
      UpdateConversationPreferenceResult(
        reconciliationStatus: status,
        conversationId: input.conversationId,
        expectedPreferenceRevision: input.expectedPreferenceRevision,
        idempotencyKey: input.idempotencyKey,
        requestedPreference: input.preference,
        preferenceRevision: preferenceRevision,
        preference: preference,
      );

  bool _samePreference(
    ConversationPreferenceDesiredState left,
    ConversationPreferenceDesiredState right,
  ) =>
      left.notificationPreference == right.notificationPreference &&
      left.mute.muted == right.mute.muted &&
      left.mute.mutedUntil?.value == right.mute.mutedUntil?.value;

  CanonicalConversationMemberState? _publicMember(UserId userId) {
    for (final member in _publicMembers) {
      if (member.userId == userId) return member;
    }
    return null;
  }

  void _upsertPublicMember({
    required UserId userId,
    required ConversationMembershipMemberRole role,
    required ConversationMembershipMemberState state,
    required IsoTimestamp joinedAt,
  }) {
    _publicMembers = [
      for (final member in _publicMembers)
        if (member.userId != userId) member,
      CanonicalConversationMemberState(
        userId: userId,
        role: role,
        state: state,
        joinedAt: joinedAt,
        updatedAt: const IsoTimestamp(_fixtureTime),
      ),
    ]..sort((left, right) => left.userId.value.compareTo(right.userId.value));
  }

  bool _wouldEliminateLastOwner(
    CanonicalConversationMemberState member,
    ConversationMembershipMemberRole? requestedRole,
  ) =>
      member.role == ConversationMembershipMemberRole.owner &&
      requestedRole != ConversationMembershipMemberRole.owner &&
      _publicMembers
              .where(
                (candidate) =>
                    candidate.state ==
                        ConversationMembershipMemberState.active &&
                    candidate.role == ConversationMembershipMemberRole.owner,
              )
              .length ==
          1;

  HandrailChatHttpResponse _lastOwnerSafetyResponse(
    ConversationMembershipMutationInput input,
  ) =>
      _jsonResponse(
        _publicMembershipResult(
          input,
          ConversationMembershipReconciliationStatus.safetyRejected,
          safetyError: ConversationMembershipSafetyError(
            code: ConversationMembershipSafetyErrorCode.lastOwner,
            message: 'A conversation must retain an owner.',
          ),
        ).toJson(),
        409,
      );

  ConversationMembershipMutationResult _publicMembershipResult(
    ConversationMembershipMutationInput input,
    ConversationMembershipReconciliationStatus status, {
    ConversationMembershipSafetyError? safetyError,
  }) =>
      ConversationMembershipMutationResult(
        intent: input.intent,
        reconciliationStatus: status,
        conversationId: input.conversationId,
        expectedMemberListRevision: input.expectedMemberListRevision,
        memberListRevision: _publicMemberListRevision,
        memberUserId: input.targetUserId!,
        targetUserId: input.targetUserId,
        requestedRole: input.requestedRole,
        members: _publicMembers,
        safetyError: safetyError,
      );

  Map<String, Object?> _publicConversationDetailResponse() {
    final fixture = _conversationDetailFixtures[_publicChannelId]!;
    final conversation = fixture['conversation']! as Map<String, Object?>;
    return <String, Object?>{
      ...fixture,
      'conversation': <String, Object?>{
        ...conversation,
        'activeMemberUserIds': [
          for (final member in _publicMembers)
            if (member.state == ConversationMembershipMemberState.active)
              member.userId.value,
        ],
        'memberUserIds': [
          for (final member in _publicMembers)
            if (member.state == ConversationMembershipMemberState.active)
              member.userId.value,
        ],
        'memberListRevision': _publicMemberListRevision,
      },
    };
  }

  Map<String, Object?> _conversationDetailResponse(
    ConversationId conversationId,
    Map<String, Object?> fixture,
  ) {
    final conversation = fixture['conversation']! as Map<String, Object?>;
    final preference = _canonicalPreference(conversationId);
    return <String, Object?>{
      ...fixture,
      'conversation': <String, Object?>{
        ...conversation,
        'currentPreference': <String, Object?>{
          'conversationId': conversationId.value,
          'userId': _currentUserId,
          ...preference.toJson(),
        },
      },
    };
  }

  HandrailChatHttpResponse _createConversation(
    HandrailChatHttpRequest request,
  ) {
    late final ConversationCreationInput input;
    try {
      input = ConversationCreationInput.fromJson(
        jsonDecode(request.body ?? ''),
      );
    } on FormatException {
      return _jsonResponse(
        const {'error': 'invalid conversation creation'},
        400,
      );
    }

    return switch (input) {
      CreateChannelConversationInput() => _createChannel(input),
      CreateDirectConversationInput() => _createDirect(input),
      CreateGroupDirectConversationInput() => _createGroupDirect(input),
    };
  }

  HandrailChatHttpResponse _createChannel(
    CreateChannelConversationInput input,
  ) {
    final conversationId = switch (input.visibility) {
      ConversationVisibility.public => _createdPublicChannelId,
      ConversationVisibility.private => _createdPrivateChannelId,
    };
    final summary = _createdChannelSummaryFixture(
      conversationId: conversationId,
      name: input.name,
      visibility: input.visibility,
    );
    final detail = _createdChannelDetailFixture(
      conversationId: conversationId,
      summary: summary,
    );
    _createdConversationSummaries[conversationId] = summary;
    _createdConversationDetails[conversationId] = detail;
    _createdTimelines[conversationId] = _timelineFixture(
      conversationId,
      messages: const [],
    );

    return _jsonResponse(
      <String, Object?>{
        'operation': 'create_conversation',
        'type': 'channel',
        'reconciliationStatus': 'created',
        'clientRequestId': input.clientRequestId,
        'conversation': detail,
      },
      201,
    );
  }

  HandrailChatHttpResponse _createDirect(
    CreateDirectConversationInput input,
  ) {
    if (input.intendedMemberUserIds.length != 1) {
      return _jsonResponse(const {'error': 'invalid direct creation'}, 400);
    }

    late final CanonicalParticipantIdentity participantIdentity;
    try {
      participantIdentity = deriveCanonicalParticipantIdentity(
        const UserId(_currentUserId),
        input.intendedMemberUserIds,
      );
    } on FormatException {
      return _jsonResponse(const {'error': 'invalid direct creation'}, 400);
    }

    final conversationId = switch (directCreationReconciliationStatus) {
      ConversationCreationReconciliationStatus.created =>
        _createdDirectConversationId,
      ConversationCreationReconciliationStatus.existingEquivalent =>
        _directConversationId,
      ConversationCreationReconciliationStatus.replayed =>
        _createdDirectConversationId,
    };
    final intendedMemberUserId = input.intendedMemberUserIds.single;
    late final Map<String, Object?> detail;
    if (conversationId == _directConversationId) {
      detail = _conversationDetailFixtures[_directConversationId]!;
    } else {
      final summary = _createdDirectSummaryFixture(
        conversationId: conversationId,
        participantUserIds: participantIdentity.participantUserIds,
      );
      detail = _createdDirectDetailFixture(
        conversationId: conversationId,
        summary: summary,
        intendedMemberUserId: intendedMemberUserId,
      );
      _createdConversationSummaries[conversationId] = summary;
      _createdConversationDetails[conversationId] = detail;
      _createdTimelines[conversationId] = _timelineFixture(
        conversationId,
        messages: const [],
      );
    }

    return _jsonResponse(
      <String, Object?>{
        'operation': 'create_conversation',
        'type': 'direct',
        'reconciliationStatus': directCreationReconciliationStatus.toJson(),
        'clientRequestId': input.clientRequestId,
        'conversation': detail,
        'participantIdentity': participantIdentity.toJson(),
      },
      directCreationReconciliationStatus ==
              ConversationCreationReconciliationStatus.created
          ? 201
          : 200,
    );
  }

  HandrailChatHttpResponse _createGroupDirect(
    CreateGroupDirectConversationInput input,
  ) {
    if (input.intendedMemberUserIds.length < 2) {
      return _jsonResponse(
        const {'error': 'invalid group-direct creation'},
        400,
      );
    }

    late final CanonicalParticipantIdentity participantIdentity;
    try {
      participantIdentity = deriveCanonicalParticipantIdentity(
        const UserId(_currentUserId),
        input.intendedMemberUserIds,
      );
    } on FormatException {
      return _jsonResponse(
        const {'error': 'invalid group-direct creation'},
        400,
      );
    }

    final conversationId = switch (groupDirectCreationReconciliationStatus) {
      ConversationCreationReconciliationStatus.created =>
        _createdGroupDirectConversationId,
      ConversationCreationReconciliationStatus.existingEquivalent =>
        _groupDirectConversationId,
      ConversationCreationReconciliationStatus.replayed =>
        _createdGroupDirectConversationId,
    };
    late final Map<String, Object?> detail;
    if (conversationId == _groupDirectConversationId) {
      detail = _conversationDetailFixtures[_groupDirectConversationId]!;
    } else {
      final summary = _createdGroupDirectSummaryFixture(
        conversationId: conversationId,
        participantUserIds: participantIdentity.participantUserIds,
      );
      detail = _createdGroupDirectDetailFixture(
        conversationId: conversationId,
        summary: summary,
        participantUserIds: participantIdentity.participantUserIds,
      );
      _createdConversationSummaries[conversationId] = summary;
      _createdConversationDetails[conversationId] = detail;
      _createdTimelines[conversationId] = _timelineFixture(
        conversationId,
        messages: const [],
      );
    }

    return _jsonResponse(
      <String, Object?>{
        'operation': 'create_conversation',
        'type': 'group_direct',
        'reconciliationStatus':
            groupDirectCreationReconciliationStatus.toJson(),
        'clientRequestId': input.clientRequestId,
        'conversation': detail,
        'participantIdentity': participantIdentity.toJson(),
      },
      groupDirectCreationReconciliationStatus ==
              ConversationCreationReconciliationStatus.created
          ? 201
          : 200,
    );
  }

  Map<String, Object?> _conversationListResponse() => <String, Object?>{
        ..._conversationListFixture,
        'items': <Object?>[
          ...(_conversationListFixture['items']! as List<Object?>),
          ..._createdConversationSummaries.values,
        ],
      };

  HandrailChatHttpResponse _openThread(HandrailChatHttpRequest request) {
    final segments = request.uri.pathSegments;
    final rootMessageId = MessageId(segments[segments.length - 2]);
    if (rootMessageId != _seededThreadRootId &&
        rootMessageId != _zeroReplyThreadRootId) {
      return _jsonResponse(const {'error': 'unknown thread root'}, 404);
    }
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    if (body['operation'] != 'create_thread' ||
        body['parentConversationId'] != _publicChannelId.value ||
        body['rootMessageId'] != rootMessageId.value) {
      return _jsonResponse(const {'error': 'invalid thread request'}, 400);
    }

    final seeded = rootMessageId == _seededThreadRootId;
    final alreadyExisted = seeded || _createdThreadExists;
    if (!seeded) _createdThreadExists = true;
    final threadId = seeded ? _seededThreadId : _createdThreadId;
    final replyCount = seeded ? 1 : (_createdThreadReply == null ? 0 : 1);
    return _jsonResponse(
      _threadCreationResultFixture(
        rootMessageId: rootMessageId,
        threadId: threadId,
        reconciliationStatus: alreadyExisted ? 'existing_for_root' : 'created',
        replyCount: replyCount,
      ),
      alreadyExisted ? 200 : 201,
    );
  }

  HandrailChatHttpResponse _sendCreatedThreadReply(
    HandrailChatHttpRequest request,
  ) {
    if (!_createdThreadExists) {
      return _jsonResponse(const {'error': 'thread not created'}, 404);
    }
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    if (body['operation'] != 'send' ||
        body['conversationId'] != _createdThreadId.value) {
      return _jsonResponse(const {'error': 'invalid thread reply'}, 400);
    }
    final content = body['content'];
    if (content is! Map<String, Object?>) {
      return _jsonResponse(const {'error': 'invalid reply content'}, 400);
    }
    _createdThreadReply ??= _messageFixture(
      conversationId: _createdThreadId,
      id: 'message-created-thread-reply',
      sequence: 1,
      authorId: _currentUserId,
      text: content['text']! as String,
    );
    onReplySent?.call(
      _canonicalMessageFixture(_createdThreadReply!),
      body['clientMessageId']! as String,
    );
    return _jsonResponse({
      'operation': 'send',
      'reconciliationStatus': 'applied',
      'clientMessageId': body['clientMessageId'],
      'message': _canonicalMessageFixture(_createdThreadReply!),
      'canonicalRevision': 1,
    });
  }

  Future<HandrailChatHttpResponse> _sendMessage(
    HandrailChatHttpRequest request,
  ) async {
    // Keep the running state observable to browser and widget harnesses.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (sendResponse == TimelineLabSendResponse.persistentFailure ||
        (sendResponse == TimelineLabSendResponse.recoverableFailure &&
            !_recoverableSendFailureReturned)) {
      _recoverableSendFailureReturned = true;
      return const HandrailChatHttpResponse(statusCode: 503, body: '');
    }

    late final SendMessageRequest input;
    try {
      input = SendMessageRequest.fromJson(jsonDecode(request.body ?? ''));
    } on FormatException {
      return _jsonResponse(
        const {
          'error': {
            'code': 'INVALID_SEND_MESSAGE',
            'message': 'The send message request is invalid.',
          },
        },
        400,
      );
    }
    final segments = request.uri.pathSegments;
    if (segments.length < 2 ||
        segments[segments.length - 2] != input.conversationId.value) {
      return _jsonResponse(
        const {
          'error': {
            'code': 'INVALID_SEND_MESSAGE',
            'message': 'The send message request is invalid.',
          },
        },
        400,
      );
    }

    final timeline = _timelineFor(input.conversationId);
    if (timeline == null) {
      return _jsonResponse(
        const {
          'error': {
            'code': 'CONVERSATION_NOT_FOUND',
            'message': 'The conversation is unavailable.',
          },
        },
        404,
      );
    }
    final messages = _sentMessages.putIfAbsent(input.conversationId, () => []);
    final existing = messages
        .where((message) => message['clientMessageId'] == input.clientMessageId)
        .firstOrNull;
    final reconciliationStatus = existing == null ? 'applied' : 'replayed';
    final canonical = existing ??
        <String, Object?>{
          'id': 'message-${input.clientMessageId}',
          'tenantId': _tenantId,
          'conversationId': input.conversationId.value,
          'author': const {'type': 'user', 'userId': _currentUserId},
          'sequence': (timeline['messages']! as List<Object?>).length + 1,
          'createdAt': _fixtureTime,
          'updatedAt': _fixtureTime,
          'revision': const {'revision': 1},
          'content': input.content.toJson(),
          'clientMessageId': input.clientMessageId,
        };
    if (existing == null) messages.add(canonical);
    final message = Map<String, Object?>.from(canonical)
      ..remove('clientMessageId');
    onMessageSent?.call(
      input.conversationId,
      message,
      input.clientMessageId,
    );
    return _jsonResponse({
      'operation': 'send',
      'reconciliationStatus': reconciliationStatus,
      'clientMessageId': input.clientMessageId,
      'message': message,
      'canonicalRevision': 1,
    });
  }

  Map<String, Object?>? _timelineFor(ConversationId conversationId) {
    final fixture = switch (conversationId) {
      _publicChannelId => _publicTimelineFixture(
          _canonicalReactionJson(),
          createdThreadReplyCount: _createdThreadExists
              ? (_createdThreadReply == null ? 0 : 1)
              : null,
        ),
      _seededThreadId => _seededThreadTimelineFixture,
      _createdThreadId when _createdThreadExists => _timelineFixture(
          _createdThreadId,
          messages: [
            if (_createdThreadReply case final reply?) reply,
          ],
        ),
      _privateChannelId => _privateTimelineFixture(
          forwardedMessage: _forwardedPrivateMessage,
        ),
      _ =>
        _createdTimelines[conversationId] ?? _timelineFixtures[conversationId],
    };
    if (fixture == null) return null;
    final sent = _sentMessages[conversationId];
    if (sent == null || sent.isEmpty) return fixture;
    return Map<String, Object?>.from(fixture)
      ..['messages'] = <Object?>[
        ...(fixture['messages']! as List<Object?>),
        for (final message in sent)
          Map<String, Object?>.from(message)..remove('clientMessageId'),
      ];
  }

  HandrailChatHttpResponse _mutateReaction(
    HandrailChatHttpRequest request,
  ) {
    final segments = request.uri.pathSegments;
    final messageId = segments[segments.length - 3];
    final reactionKey = segments.last;
    final body = jsonDecode(request.body!) as Map<String, Object?>;
    final operation = body['operation'];
    if (messageId != 'message-sent' ||
        body['messageId'] != messageId ||
        body['reactionKey'] != reactionKey ||
        (operation != 'add_reaction' && operation != 'remove_reaction')) {
      return _jsonResponse(const {'error': 'invalid reaction mutation'}, 400);
    }

    final previous = _reactionAggregates[reactionKey] ??
        MessageReactionAggregate(
          reactionKey: reactionKey,
          count: 0,
          reactedByCurrentUser: false,
        );
    final adding = operation == 'add_reaction';
    final count = adding
        ? previous.count + (previous.reactedByCurrentUser ? 0 : 1)
        : previous.count - (previous.reactedByCurrentUser ? 1 : 0);
    final canonical = MessageReactionAggregate(
      reactionKey: reactionKey,
      count: count < 0 ? 0 : count,
      reactedByCurrentUser: adding,
    );
    _reactionAggregates[reactionKey] = canonical;
    return _jsonResponse({
      'operation': operation,
      'reconciliationStatus': 'applied',
      'messageId': messageId,
      'reactionKey': reactionKey,
      'count': canonical.count,
      'reactedByCurrentUser': canonical.reactedByCurrentUser,
    });
  }

  HandrailChatHttpResponse _mutateReadCursor(
    HandrailChatHttpRequest request,
  ) {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2) throw const FormatException();
      final pathConversationId = ConversationId(segments[segments.length - 2]);
      final input = ReadCursorMutationInput.fromJson(
        jsonDecode(request.body ?? ''),
      );
      if (input is! MarkUnreadInput ||
          input.conversationId != pathConversationId ||
          input.conversationId != _publicChannelId) {
        throw const FormatException();
      }
      input.validateAgainst(
        currentReadState: _publicReadState,
        latestSequence: const MessageSequence(4),
      );
      _readCursorMutationRevision += 1;
      _publicReadState = ConversationReadState(
        conversationId: _publicChannelId,
        userId: const UserId(_currentUserId),
        lastReadSequence: const MessageSequence(4),
        manualUnreadFromSequence: input.fromSequence,
        updatedAt: IsoTimestamp(
          DateTime.parse(_fixtureTime)
              .add(Duration(minutes: _readCursorMutationRevision))
              .toIso8601String(),
        ),
      );
      return _jsonResponse(
        ReadCursorMutationResult(
          operation: ReadCursorMutationOperation.markUnread,
          reconciliationStatus: ReadCursorReconciliationStatus.applied,
          idempotencyKey: input.idempotencyKey,
          conversationId: _publicChannelId,
          readState: _publicReadState,
          latestSequence: const MessageSequence(4),
          unreadCount: 5 - input.fromSequence.value,
        ).toJson(),
      );
    } on FormatException {
      return _jsonResponse(
          const {'error': 'invalid read cursor mutation'}, 400);
    }
  }

  HandrailChatHttpResponse _forwardMessage(
    HandrailChatHttpRequest request,
  ) {
    late final ForwardMessageRequest input;
    try {
      input = ForwardMessageRequest.fromJson(jsonDecode(request.body ?? ''));
    } on FormatException {
      return _jsonResponse(const {'error': 'invalid forward request'}, 400);
    }
    if (input.sourceMessageId != _seededThreadRootId ||
        input.destinationConversationId == _unavailableConversationId ||
        !_authorizedForwardDestinationIds
            .contains(input.destinationConversationId)) {
      return _jsonResponse(const {'error': 'forward unavailable'}, 404);
    }

    _forwardedPrivateMessage ??= _forwardedMessageFixture();
    return _jsonResponse({
      'operation': 'forward_message.v1',
      'reconciliationStatus': 'applied',
      'clientCorrelationId': input.clientCorrelationId,
      'destinationConversationId': input.destinationConversationId.value,
      'message': _canonicalMessageFixture(_forwardedPrivateMessage!),
      'canonicalRevision': 1,
    });
  }

  HandrailChatHttpResponse _searchMessages(
    HandrailChatHttpRequest request,
  ) {
    late final MessageSearchRequest input;
    try {
      input = MessageSearchRequest.fromJson(jsonDecode(request.body ?? ''));
    } on FormatException {
      return _jsonResponse(const {'error': 'invalid message search'}, 400);
    }

    final filters = input.filters;
    final normalizedQuery = input.query.toLowerCase();
    final matches = _timelineLabSearchDocuments.where((document) {
      if (!_conversationIds.contains(document.conversationId)) return false;
      if (!document.searchableText.contains(normalizedQuery)) return false;
      if (filters?.conversationIds case final conversationIds?) {
        if (!conversationIds.contains(document.conversationId)) return false;
      }
      if (filters?.authorUserIds case final authorUserIds?) {
        if (!authorUserIds.contains(document.authorUserId)) return false;
      }
      if (filters?.sentAfter case final sentAfter?) {
        if (!document.sentAt.isAfter(DateTime.parse(sentAfter.value))) {
          return false;
        }
      }
      if (filters?.sentBefore case final sentBefore?) {
        if (!document.sentAt.isBefore(DateTime.parse(sentBefore.value))) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);

    final offset = _searchOffset(input.cursor);
    if (offset == null) {
      return _jsonResponse(const {'error': 'invalid search cursor'}, 400);
    }
    final end = (offset + input.pageSize).clamp(0, matches.length);
    final page = offset >= matches.length
        ? const <_TimelineLabSearchDocument>[]
        : matches.sublist(offset, end);
    final response = MessageSearchResponse.fromJson(<String, Object?>{
      'hits': [for (final document in page) document.toHitJson()],
      if (end < matches.length) 'nextCursor': '$_searchCursorPrefix$end',
    });
    return _jsonResponse(response.toJson());
  }

  int? _searchOffset(MessageSearchCursor? cursor) {
    if (cursor == null) return 0;
    if (!cursor.value.startsWith(_searchCursorPrefix)) return null;
    final offset =
        int.tryParse(cursor.value.substring(_searchCursorPrefix.length));
    return offset == null || offset < 0 ? null : offset;
  }

  List<Map<String, Object?>> _canonicalReactionJson() => [
        for (final aggregate in _reactionAggregates.values)
          if (aggregate.count > 0) aggregate.toJson(),
      ];
}

HandrailChatHttpResponse _jsonResponse(Object body, [int statusCode = 200]) =>
    HandrailChatHttpResponse(statusCode: statusCode, body: jsonEncode(body));

final _timelineFixtures = <ConversationId, Map<String, Object?>>{
  _publicChannelId: _publicTimelineFixture(
    [for (final aggregate in _seededReactionAggregates) aggregate.toJson()],
  ),
  _directConversationId: _timelineFixture(
    _directConversationId,
    messages: [
      _messageFixture(
        conversationId: _directConversationId,
        id: 'message-direct',
        sequence: 1,
        authorId: 'grace',
        text: _directSearchText,
      ),
    ],
  ),
  _groupDirectConversationId: _timelineFixture(
    _groupDirectConversationId,
    messages: [
      _messageFixture(
        conversationId: _groupDirectConversationId,
        id: 'message-group-direct',
        sequence: 1,
        authorId: 'margaret',
        text: 'Group direct conversation canonical timeline',
      ),
    ],
  ),
};

final class _TimelineLabSearchDocument {
  const _TimelineLabSearchDocument({
    required this.conversationId,
    required this.messageId,
    required this.title,
    required this.text,
    required this.authorUserId,
    required this.authorDisplayName,
    required this.sentAt,
  });

  final ConversationId conversationId;
  final MessageId messageId;
  final String title;
  final String text;
  final UserId authorUserId;
  final String authorDisplayName;
  final DateTime sentAt;

  String get searchableText => '$title $text $authorDisplayName'.toLowerCase();

  Map<String, Object?> toHitJson() => <String, Object?>{
        'type': 'message',
        'conversationId': conversationId.value,
        'messageId': messageId.value,
        'title': title,
        'snippet': text,
        'authorUserId': authorUserId.value,
        'authorDisplayName': authorDisplayName,
        'sentAt': sentAt.toUtc().toIso8601String(),
      };
}

final _timelineLabSearchDocuments = <_TimelineLabSearchDocument>[
  _TimelineLabSearchDocument(
    conversationId: _publicChannelId,
    messageId: _seededThreadRootId,
    title: 'Public channel',
    text: _forwardedSourceText,
    authorUserId: const UserId('grace'),
    authorDisplayName: 'Grace Hopper',
    sentAt: DateTime.parse(_fixtureTime),
  ),
  _TimelineLabSearchDocument(
    conversationId: _privateChannelId,
    messageId: const MessageId('message-private'),
    title: 'Private channel',
    text: 'Private channel canonical timeline',
    authorUserId: const UserId('grace'),
    authorDisplayName: 'Grace Hopper',
    sentAt: DateTime.parse(_fixtureTime),
  ),
  _TimelineLabSearchDocument(
    conversationId: _directConversationId,
    messageId: const MessageId('message-direct'),
    title: 'Direct message',
    text: _directSearchText,
    authorUserId: const UserId('grace'),
    authorDisplayName: 'Grace Hopper',
    sentAt: DateTime.parse(_fixtureTime),
  ),
  _TimelineLabSearchDocument(
    conversationId: _groupDirectConversationId,
    messageId: const MessageId('message-group-direct'),
    title: 'Group conversation',
    text: 'Group direct conversation canonical timeline',
    authorUserId: const UserId('margaret'),
    authorDisplayName: 'Margaret Hamilton',
    sentAt: DateTime.parse(_fixtureTime),
  ),
  // This record proves that transport authorization is enforced before query
  // matching. It is deliberately excluded by [_conversationIds].
  _TimelineLabSearchDocument(
    conversationId: _unavailableConversationId,
    messageId: const MessageId('message-unavailable-private'),
    title: 'Inaccessible private channel',
    text: _inaccessiblePrivateSearchText,
    authorUserId: const UserId('mallory'),
    authorDisplayName: 'Mallory',
    sentAt: DateTime.parse(_fixtureTime),
  ),
];

Map<String, Object?> _publicTimelineFixture(
  List<Map<String, Object?>> reactions, {
  int? createdThreadReplyCount,
}) =>
    _timelineFixture(
      _publicChannelId,
      messages: [
        _messageFixture(
          conversationId: _publicChannelId,
          id: 'message-sent',
          sequence: 1,
          authorId: 'grace',
          text: _forwardedSourceText,
          reactions: reactions,
          threadSummary: _threadSummaryFixture(
            threadId: _seededThreadId,
            replyCount: 1,
            participantIds: const ['grace'],
          ),
        ),
        _messageFixture(
          conversationId: _publicChannelId,
          id: 'message-deleted',
          sequence: 2,
          authorId: 'grace',
          deleted: true,
        ),
        _messageFixture(
          conversationId: _publicChannelId,
          id: _zeroReplyThreadRootId.value,
          sequence: 3,
          authorId: 'margaret',
          text: 'Canonical zero-reply thread root',
          threadSummary: createdThreadReplyCount == null
              ? null
              : _threadSummaryFixture(
                  threadId: _createdThreadId,
                  replyCount: createdThreadReplyCount,
                  participantIds:
                      createdThreadReplyCount == 0 ? const [] : const ['ada'],
                ),
        ),
        _messageFixture(
          conversationId: _publicChannelId,
          id: _attachmentMessageId.value,
          sequence: 4,
          authorId: 'grace',
          text: 'Canonical attachment fixture',
          attachmentReferences: const [
            {'attachmentId': 'attachment-forward-ineligible'},
          ],
          attachmentMetadata: const [
            {
              'attachmentId': 'attachment-forward-ineligible',
              'fileName': 'forwarding-notes.pdf',
              'contentType': 'application/pdf',
              'sizeBytes': 2048,
              'downloadUrl':
                  'https://flutter-timeline-lab.invalid/forwarding-notes.pdf',
            },
          ],
        ),
      ],
    );

Map<String, Object?> _privateTimelineFixture({
  Map<String, Object?>? forwardedMessage,
}) =>
    _timelineFixture(
      _privateChannelId,
      messages: [
        _messageFixture(
          conversationId: _privateChannelId,
          id: 'message-private',
          sequence: 1,
          authorId: 'grace',
          text: 'Private channel canonical timeline',
        ),
        if (forwardedMessage != null) forwardedMessage,
      ],
    );

Map<String, Object?> _forwardedMessageFixture() => _messageFixture(
      conversationId: _privateChannelId,
      id: _forwardedMessageId.value,
      sequence: 2,
      authorId: _currentUserId,
      text: _forwardedSourceText,
      createdAt: _forwardedFixtureTime,
      forwarded: const {
        'sourceMessageId': 'message-sent',
        'originalAuthor': {
          'userId': 'grace',
          'displayName': 'Grace Hopper',
        },
        'originalCreatedAt': _fixtureTime,
      },
    );

final _seededThreadTimelineFixture = _timelineFixture(
  _seededThreadId,
  messages: [
    _messageFixture(
      conversationId: _seededThreadId,
      id: 'message-seeded-thread-reply',
      sequence: 1,
      authorId: 'grace',
      text: 'Seeded existing thread reply',
    ),
  ],
);

Map<String, Object?> _timelineFixture(
  ConversationId conversationId, {
  required List<Map<String, Object?>> messages,
}) =>
    {
      'conversationId': conversationId.value,
      'messages': messages,
      'pagination': {
        'older': {'available': false},
        'newer': {'available': false},
      },
      'replay': {
        'resumeFrom': {
          'eventId': 'flutter-timeline-lab-${conversationId.value}',
        },
      },
    };

Map<String, Object?> _messageFixture({
  required ConversationId conversationId,
  required String id,
  required int sequence,
  required String authorId,
  String? text,
  String createdAt = _fixtureTime,
  bool deleted = false,
  List<Object?> reactions = const <Object?>[],
  List<Object?> attachmentReferences = const <Object?>[],
  List<Object?> attachmentMetadata = const <Object?>[],
  Map<String, Object?>? forwarded,
  Map<String, Object?>? threadSummary,
}) =>
    {
      'id': id,
      'tenantId': _tenantId,
      'conversationId': conversationId.value,
      'author': {'type': 'user', 'userId': authorId},
      'sequence': sequence,
      'createdAt': createdAt,
      'updatedAt': createdAt,
      'revision': {'revision': 1},
      if (!deleted)
        'content': {
          'format': 'plain',
          'text': text,
          if (attachmentReferences.isNotEmpty)
            'attachments': attachmentReferences,
          if (forwarded != null) 'forwarded': forwarded,
        },
      if (deleted) ...{
        'content': null,
        'deletedAt': _fixtureTime,
        'deletedByUserId': _currentUserId,
      },
      if (threadSummary != null) 'threadSummary': threadSummary,
      'isThreadRoot': threadSummary != null,
      'reactions': reactions,
      'attachmentMetadata': attachmentMetadata,
    };

Map<String, Object?> _canonicalMessageFixture(
  Map<String, Object?> timelineMessage,
) =>
    Map<String, Object?>.from(timelineMessage)
      ..remove('isThreadRoot')
      ..remove('reactions')
      ..remove('attachmentMetadata');

Map<String, Object?> _threadSummaryFixture({
  required ConversationId threadId,
  required int replyCount,
  required List<String> participantIds,
}) =>
    {
      'threadId': threadId.value,
      'replyCount': replyCount,
      'participantIds': participantIds,
      'unreadCount': 0,
      if (replyCount > 0) 'lastReplyAt': _fixtureTime,
    };

Map<String, Object?> _threadCreationResultFixture({
  required MessageId rootMessageId,
  required ConversationId threadId,
  required String reconciliationStatus,
  required int replyCount,
}) =>
    {
      'operation': 'create_thread',
      'reconciliationStatus': reconciliationStatus,
      'parentConversationId': _publicChannelId.value,
      'rootMessageId': rootMessageId.value,
      'conversation': _threadConversationDetailFixture(
        threadId: threadId,
        rootMessageId: rootMessageId,
        latestSequence: replyCount,
      ),
      'rootThreadSummary': _threadSummaryFixture(
        threadId: threadId,
        replyCount: replyCount,
        participantIds: replyCount == 0
            ? const []
            : rootMessageId == _seededThreadRootId
                ? const ['grace']
                : const [_currentUserId],
      ),
    };

Map<String, Object?> _threadConversationDetailFixture({
  required ConversationId threadId,
  required MessageId rootMessageId,
  required int latestSequence,
}) =>
    {
      'kind': 'conversation_detail',
      'conversation': {
        ..._conversationSummaryStateFixture(
          threadId,
          const [_currentUserId, 'grace'],
        ),
        'id': threadId.value,
        'tenantId': _tenantId,
        'type': 'thread',
        'visibility': 'private',
        'parentConversationId': _publicChannelId.value,
        'rootMessageId': rootMessageId.value,
        'createdAt': _fixtureTime,
        'updatedAt': _fixtureTime,
        'latestSequence': latestSequence,
        'activityAt': _fixtureTime,
        'currentMember': {
          'tenantId': _tenantId,
          'conversationId': threadId.value,
          'userId': _currentUserId,
          'role': 'member',
          'state': 'active',
          'joinedAt': _fixtureTime,
          'updatedAt': _fixtureTime,
        },
        'currentReadState': {
          'conversationId': threadId.value,
          'userId': _currentUserId,
          'lastReadSequence': 0,
          'updatedAt': _fixtureTime,
        },
        'memberUserIds': const [_currentUserId, 'grace'],
      },
      '_meta': _conversationMetadata,
    };

Map<String, Object?> _draftMutationResult(Map<String, Object?> input) => {
      'operation': 'synchronize_draft',
      'intent': input['intent'],
      'reconciliationStatus': 'applied',
      'conversationId': input['conversationId'],
      'baseRevision': input['baseRevision'],
      'deviceMutationId': input['deviceMutationId'],
      'idempotencyKey': input['idempotencyKey'],
      'canonicalRevision': (input['baseRevision']! as int) + 1,
      'canonicalUpdatedAt': _fixtureTime,
      'draft': input['intent'] == 'replace'
          ? <String, Object?>{
              'kind': 'replaced',
              'content': input['content'],
            }
          : const <String, Object?>{
              'kind': 'clear_tombstone',
              'content': null,
            },
    };

final _conversationListFixture = <String, Object?>{
  'kind': 'conversation_list',
  'scope': const {'type': 'organization'},
  'items': [
    for (final conversationId in _conversationIds)
      _conversationSummaryFixture(conversationId),
  ],
  'page': const <String, Object?>{},
  '_meta': _conversationMetadata,
};

final _conversationDetailFixtures = <ConversationId, Map<String, Object?>>{
  for (final conversationId in _conversationIds)
    conversationId: {
      'kind': 'conversation_detail',
      'conversation': {
        ..._conversationSummaryFixture(conversationId),
        'memberUserIds': _conversationMemberUserIds(conversationId),
        // The complete membership result installs its revision after hydration.
      },
      '_meta': _conversationMetadata,
    },
};

// Summary projections are required by both list and detail snapshot decoders.
Map<String, Object?> _conversationSummaryStateFixture(
  ConversationId conversationId,
  List<String> activeMemberUserIds,
) =>
    {
      'unreadMentionCount': 0,
      'activeMemberUserIds': activeMemberUserIds,
      'currentPreference': {
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'notificationPreference': 'all',
        'mute': {'muted': false},
        'isStarred': false,
        'updatedAt': _fixtureTime,
      },
    };

List<String> _conversationMemberUserIds(ConversationId conversationId) =>
    switch (conversationId) {
      _publicChannelId || _groupDirectConversationId =>
        const [_currentUserId, 'grace', 'margaret'],
      _ => const [_currentUserId, 'grace'],
    };

Map<String, Object?> _conversationSummaryFixture(
  ConversationId conversationId,
) {
  final (type, name, visibility, latestSequence) = switch (conversationId) {
    _publicChannelId => ('channel', 'Public channel', 'public', 4),
    _privateChannelId => ('channel', 'Private channel', 'private', 1),
    _directConversationId => ('direct', null, 'private', 1),
    _groupDirectConversationId => ('group_direct', null, 'private', 1),
    _ => throw ArgumentError.value(conversationId),
  };
  return {
    ..._conversationSummaryStateFixture(
      conversationId,
      _conversationMemberUserIds(conversationId),
    ),
    'id': conversationId.value,
    'tenantId': _tenantId,
    'type': type,
    if (name != null) 'name': name,
    'visibility': visibility,
    'createdAt': _fixtureTime,
    'updatedAt': _fixtureTime,
    'latestSequence': latestSequence,
    'activityAt': _fixtureTime,
    'currentMember': {
      'tenantId': _tenantId,
      'conversationId': conversationId.value,
      'userId': _currentUserId,
      'role': conversationId == _publicChannelId ? 'owner' : 'member',
      'state': 'active',
      'joinedAt': _fixtureTime,
      'updatedAt': _fixtureTime,
    },
    'currentReadState': {
      'conversationId': conversationId.value,
      'userId': _currentUserId,
      'lastReadSequence': latestSequence,
      if (conversationId == _publicChannelId) 'manualUnreadFromSequence': 1,
      'updatedAt': _fixtureTime,
    },
  };
}

Map<String, Object?> _createdChannelSummaryFixture({
  required ConversationId conversationId,
  required String name,
  required ConversationVisibility visibility,
}) =>
    <String, Object?>{
      'id': conversationId.value,
      'tenantId': _tenantId,
      ..._conversationSummaryStateFixture(
        conversationId,
        const [_currentUserId],
      ),
      'type': 'channel',
      'name': name,
      'visibility': visibility.toJson(),
      'createdAt': _fixtureTime,
      'updatedAt': _fixtureTime,
      'latestSequence': 0,
      'activityAt': _fixtureTime,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _fixtureTime,
        'updatedAt': _fixtureTime,
      },
      'currentReadState': {
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'lastReadSequence': 0,
        'updatedAt': _fixtureTime,
      },
    };

Map<String, Object?> _createdChannelDetailFixture({
  required ConversationId conversationId,
  required Map<String, Object?> summary,
}) =>
    <String, Object?>{
      'kind': 'conversation_detail',
      'conversation': <String, Object?>{
        ...summary,
        'memberUserIds': const [_currentUserId],
      },
      '_meta': _conversationMetadata,
    };

Map<String, Object?> _createdDirectSummaryFixture({
  required ConversationId conversationId,
  required List<UserId> participantUserIds,
}) =>
    <String, Object?>{
      'id': conversationId.value,
      'tenantId': _tenantId,
      ..._conversationSummaryStateFixture(
        conversationId,
        participantUserIds.map((userId) => userId.value).toList(),
      ),
      'type': 'direct',
      'visibility': 'private',
      'createdAt': _fixtureTime,
      'updatedAt': _fixtureTime,
      'latestSequence': 0,
      'activityAt': _fixtureTime,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _fixtureTime,
        'updatedAt': _fixtureTime,
      },
      'currentReadState': {
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'lastReadSequence': 0,
        'updatedAt': _fixtureTime,
      },
    };

Map<String, Object?> _createdDirectDetailFixture({
  required ConversationId conversationId,
  required Map<String, Object?> summary,
  required UserId intendedMemberUserId,
}) =>
    <String, Object?>{
      'kind': 'conversation_detail',
      'conversation': <String, Object?>{
        ...summary,
        'memberUserIds': [
          _currentUserId,
          intendedMemberUserId.value,
        ],
      },
      '_meta': _conversationMetadata,
    };

Map<String, Object?> _createdGroupDirectSummaryFixture({
  required ConversationId conversationId,
  required List<UserId> participantUserIds,
}) =>
    <String, Object?>{
      'id': conversationId.value,
      'tenantId': _tenantId,
      ..._conversationSummaryStateFixture(
        conversationId,
        participantUserIds.map((userId) => userId.value).toList(),
      ),
      'type': 'group_direct',
      'visibility': 'private',
      'createdAt': _fixtureTime,
      'updatedAt': _fixtureTime,
      'latestSequence': 0,
      'activityAt': _fixtureTime,
      'currentMember': {
        'tenantId': _tenantId,
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'role': 'member',
        'state': 'active',
        'joinedAt': _fixtureTime,
        'updatedAt': _fixtureTime,
      },
      'currentReadState': {
        'conversationId': conversationId.value,
        'userId': _currentUserId,
        'lastReadSequence': 0,
        'updatedAt': _fixtureTime,
      },
    };

Map<String, Object?> _createdGroupDirectDetailFixture({
  required ConversationId conversationId,
  required Map<String, Object?> summary,
  required List<UserId> participantUserIds,
}) =>
    <String, Object?>{
      'kind': 'conversation_detail',
      'conversation': <String, Object?>{
        ...summary,
        'memberUserIds': participantUserIds
            .map((userId) => userId.value)
            .toList(growable: false),
      },
      '_meta': _conversationMetadata,
    };

const _conversationMetadata = <String, Object?>{
  'packageVersion': handrailChatPackageVersion,
  'protocolVersion': 4,
  'schemaVersion': 9,
  'enabledFeatures': {conversationSnapshotFeature: true},
  'supportedProtocolRange': {
    'minimumVersion': 3,
    'maximumVersion': 4,
  },
  'feature': {
    'name': conversationSnapshotFeature,
    'version': conversationSnapshotVersion,
  },
};
