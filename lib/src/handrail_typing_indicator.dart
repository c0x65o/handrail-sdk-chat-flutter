import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'chat_scope.dart';
import 'handrail_chat_theme.dart';
import 'handrail_member_picker.dart';

/// Resolves presentation data for a user who is currently typing.
typedef HandrailTypingUserResolver = Future<HandrailMemberDirectoryRow?>
    Function(UserId userId);

/// A Slack-style, conversation-scoped typing status line.
///
/// Signals from multiple devices are collapsed to one person. The current
/// user and terminal `stop` signals are never shown. When [resolveUser] is
/// omitted or cannot resolve an identity, the copy falls back to a generic
/// person count without exposing raw user IDs.
class HandrailTypingIndicator extends StatefulWidget {
  const HandrailTypingIndicator({
    required this.conversationId,
    this.controller,
    this.currentUserId,
    this.resolveUser,
    super.key,
  });

  final ConversationId conversationId;

  /// Optional caller-owned controller. The widget never disposes it.
  final ChatConversationController? controller;

  /// Explicit current identity used when a conversation snapshot is not ready.
  final UserId? currentUserId;

  /// Optional host-directory lookup used only for transient display names.
  final HandrailTypingUserResolver? resolveUser;

  @override
  State<HandrailTypingIndicator> createState() =>
      _HandrailTypingIndicatorState();
}

class _HandrailTypingIndicatorState extends State<HandrailTypingIndicator> {
  ChatConversationController? _conversation;
  StreamSubscription<ChatConversationControllerState>? _subscription;
  StreamSubscription<TypingSignalSnapshot>? _typingSubscription;
  HandrailChatClient? _client;
  ChatConversationControllerState? _conversationState;
  List<UserId> _typingUserIds = const <UserId>[];
  Map<UserId, String> _displayNames = const <UserId, String>{};
  UserId? _scopeUserId;
  int _bindingGeneration = 0;
  int _resolutionGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant HandrailTypingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        !identical(oldWidget.controller, widget.controller) ||
        oldWidget.currentUserId != widget.currentUserId) {
      _bind(force: true);
      return;
    }
    if (!identical(oldWidget.resolveUser, widget.resolveUser)) {
      _displayNames = const <UserId, String>{};
      _resolveDisplayNames();
    }
  }

  void _bind({bool force = false}) {
    final binding = ChatScope.of(context);
    final controller = widget.controller ??
        binding.client.conversations.forId(widget.conversationId);
    final realtimeState = binding.realtimeState;
    final scopeUserId = realtimeState is ChatRealtimeConnectedState
        ? realtimeState.identity.userId
        : null;
    if (!force &&
        identical(controller, _conversation) &&
        scopeUserId == _scopeUserId) {
      return;
    }

    _bindingGeneration += 1;
    _resolutionGeneration += 1;
    final prior = _subscription;
    _subscription = null;
    if (prior != null) unawaited(prior.cancel());
    final priorTyping = _typingSubscription;
    _typingSubscription = null;
    if (priorTyping != null) unawaited(priorTyping.cancel());
    _client = binding.client;
    _conversation = controller;
    _conversationState = controller.state;
    _scopeUserId = scopeUserId;
    _typingUserIds = const <UserId>[];
    _displayNames = const <UserId, String>{};

    final generation = _bindingGeneration;
    _subscription = controller.states.listen((state) {
      if (!mounted || generation != _bindingGeneration) return;
      _applyConversationState(state);
    });
    _typingSubscription =
        binding.client.ephemeralSignals.typingSnapshots.listen((snapshot) {
      if (!mounted || generation != _bindingGeneration) return;
      _applyTypingSnapshot(snapshot);
    });
    _applyTypingSnapshot(binding.client.ephemeralSignals.snapshot.typing);
  }

  void _applyConversationState(ChatConversationControllerState state) {
    _conversationState = state;
    final client = _client;
    if (client != null) {
      _applyTypingSnapshot(client.ephemeralSignals.snapshot.typing);
    }
  }

  void _applyTypingSnapshot(TypingSignalSnapshot snapshot) {
    final state = _conversationState;
    final tenantId = state?.conversation?.tenantId;
    if (state == null || tenantId == null) {
      if (_typingUserIds.isNotEmpty) {
        _resolutionGeneration += 1;
        setState(() {
          _typingUserIds = const <UserId>[];
          _displayNames = const <UserId, String>{};
        });
      }
      return;
    }
    final currentUserId = widget.currentUserId ??
        state.currentUserReadState?.userId ??
        _scopeUserId;
    final userIds = <UserId>[];
    final seen = <UserId>{};
    for (final event in snapshot.entries.values) {
      final userId = event.payload.actorUserId;
      if (event.tenantId != tenantId ||
          event.payload.scope.conversationId != widget.conversationId ||
          event.payload.state != TypingSignalState.start ||
          userId == currentUserId ||
          !seen.add(userId)) {
        continue;
      }
      userIds.add(userId);
    }
    if (_sameUserIds(_typingUserIds, userIds)) return;

    final activeIds = userIds.toSet();
    setState(() {
      _typingUserIds = List<UserId>.unmodifiable(userIds);
      _displayNames = Map<UserId, String>.unmodifiable(
        Map<UserId, String>.of(_displayNames)
          ..removeWhere((userId, _) => !activeIds.contains(userId)),
      );
    });
    _resolveDisplayNames();
  }

  void _resolveDisplayNames() {
    final resolver = widget.resolveUser;
    if (resolver == null || _typingUserIds.isEmpty) return;
    final unresolved = _typingUserIds
        .where((userId) => !_displayNames.containsKey(userId))
        .toList(growable: false);
    if (unresolved.isEmpty) return;
    final generation = ++_resolutionGeneration;
    Future<MapEntry<UserId, String>?> resolve(UserId userId) async {
      try {
        final row = await resolver(userId);
        if (row?.userId != userId || row!.displayName.trim().isEmpty) {
          return null;
        }
        return MapEntry<UserId, String>(userId, row.displayName.trim());
      } catch (_) {
        return null;
      }
    }

    unawaited(Future.wait(unresolved.map(resolve)).then((entries) {
      if (!mounted || generation != _resolutionGeneration) return;
      final activeIds = _typingUserIds.toSet();
      final next = Map<UserId, String>.of(_displayNames);
      for (final entry in entries) {
        if (entry != null && activeIds.contains(entry.key)) {
          next[entry.key] = entry.value;
        }
      }
      if (_sameDisplayNames(_displayNames, next)) return;
      setState(() => _displayNames = Map<UserId, String>.unmodifiable(next));
    }));
  }

  @override
  Widget build(BuildContext context) {
    final status = _typingStatusCopy(_typingUserIds, _displayNames);
    final theme = HandrailChatTheme.of(context);
    return Semantics(
      key: const ValueKey<String>('handrail-typing-indicator'),
      container: true,
      liveRegion: true,
      label: status.isEmpty ? null : status,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: theme.typography.metadata.fontSize == null
                ? 20
                : theme.typography.metadata.fontSize! * 1.67,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.symmetric(
              horizontal: theme.spacing.large,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                status,
                key: const ValueKey<String>('handrail-typing-indicator-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.metadata.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _bindingGeneration += 1;
    _resolutionGeneration += 1;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final typingSubscription = _typingSubscription;
    _typingSubscription = null;
    if (typingSubscription != null) unawaited(typingSubscription.cancel());
    _client = null;
    _conversation = null;
    _conversationState = null;
    _displayNames = const <UserId, String>{};
    super.dispose();
  }
}

String _typingStatusCopy(
  List<UserId> userIds,
  Map<UserId, String> displayNames,
) {
  if (userIds.isEmpty) return '';
  final resolved = userIds
      .map((userId) => displayNames[userId])
      .whereType<String>()
      .toList(growable: false);
  if (userIds.length == 1) {
    return '${resolved.isEmpty ? 'Someone' : resolved.first} is typing…';
  }
  if (userIds.length == 2) {
    return switch (resolved.length) {
      2 => '${resolved[0]} and ${resolved[1]} are typing…',
      1 => '${resolved[0]} and someone else are typing…',
      _ => '2 people are typing…',
    };
  }
  if (resolved.length >= 2) {
    final otherCount = userIds.length - 2;
    return '${resolved[0]}, ${resolved[1]}, and $otherCount '
        '${otherCount == 1 ? 'other' : 'others'} are typing…';
  }
  if (resolved.length == 1) {
    final otherCount = userIds.length - 1;
    return '${resolved[0]} and $otherCount others are typing…';
  }
  return '${userIds.length} people are typing…';
}

bool _sameUserIds(List<UserId> left, List<UserId> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameDisplayNames(Map<UserId, String> left, Map<UserId, String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
