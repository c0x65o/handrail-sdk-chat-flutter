import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'chat_scope.dart';
import 'handrail_chat_theme.dart';

/// Host-owned picker used by the header's explicit mute-until action.
typedef HandrailChannelMuteUntilPicker = Future<IsoTimestamp?> Function(
  BuildContext context,
  IsoTimestamp? currentMuteUntil,
);

/// Explicit host authorization for first-party conversation notifications.
///
/// Supplying this configuration does not grant access unless [authorized] is
/// true. Authorization is never inferred from membership or normalized state.
/// When [muteUntilPicker] is omitted, the header uses Material date and time
/// pickers.
@immutable
final class HandrailChannelNotificationControls {
  const HandrailChannelNotificationControls({
    this.authorized = false,
    this.muteUntilPicker,
  });

  final bool authorized;
  final HandrailChannelMuteUntilPicker? muteUntilPicker;
}

enum _MuteSelection { unmuted, indefinite, until }

/// A compact, controller-backed heading for one canonical conversation.
///
/// [leading] and [trailing] remain host-owned slots. The header does not assume
/// a router or provide search, membership, or huddle actions of its own.
/// Notification controls are rendered only when [notificationControls]
/// explicitly authorizes them and canonical private preference state exists.
///
/// Supply [controller] to observe a caller-owned controller. Otherwise the
/// widget resolves the client-owned controller from [client] or the nearest
/// [ChatScope]. In every case the widget owns only its stream subscription and
/// never disposes the conversation controller.
final class HandrailChannelHeader extends StatefulWidget {
  const HandrailChannelHeader({
    required this.conversationId,
    this.controller,
    this.client,
    this.leading,
    this.trailing,
    this.notificationControls,
    this.padding = const EdgeInsetsDirectional.only(start: 16),
    super.key,
  }) : assert(controller == null || client == null);

  final ConversationId conversationId;

  /// An optional caller-owned controller for [conversationId].
  final ChatConversationController? controller;

  /// An optional caller-owned client used when [controller] is omitted.
  final HandrailChatClient? client;

  /// A small host-owned slot before the conversation state or title.
  final Widget? leading;

  /// A small host-owned slot after the conversation state or title.
  final Widget? trailing;

  /// Optional explicit host authorization for notification preference UI.
  final HandrailChannelNotificationControls? notificationControls;

  /// Padding applied before the title or public state label.
  final EdgeInsetsGeometry padding;

  @override
  State<HandrailChannelHeader> createState() => HandrailChannelHeaderState();
}

/// Public state type for deterministic binding and teardown tests.
final class HandrailChannelHeaderState extends State<HandrailChannelHeader> {
  ChatConversationController? _controller;
  StreamSubscription<ChatConversationControllerState>? _subscription;
  ChatConversationController? _preferenceController;
  StreamSubscription<NormalizedConversationPreferenceState>?
      _preferenceSubscription;
  ChatConversationControllerState? _state;
  NormalizedConversationPreferenceState? _preferenceState;
  String? _preferenceFeedback;
  var _commandPending = false;
  var _bindingGeneration = 0;
  var _disposed = false;

  @visibleForTesting
  ChatConversationController? get debugController => _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant HandrailChannelHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.client, widget.client) ||
        oldWidget.conversationId != widget.conversationId ||
        !_sameNotificationControls(
          oldWidget.notificationControls,
          widget.notificationControls,
        )) {
      _bind(force: true);
    }
  }

  void _bind({bool force = false}) {
    final controller = widget.controller ??
        (widget.client ?? ChatScope.of(context).client)
            .conversations
            .forConversation(widget.conversationId);
    _validateIdentity(controller);
    if (!force && identical(controller, _controller)) return;

    final generation = ++_bindingGeneration;
    final previous = _subscription;
    _subscription = null;
    if (previous != null) unawaited(previous.cancel());
    _clearPreferenceBinding();

    _controller = controller;
    _state = controller.state;
    _syncPreferenceBinding(controller, controller.state, generation);
    _subscription = controller.states.listen((state) {
      if (_disposed ||
          generation != _bindingGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      _validateStateIdentity(state);
      if (state == _state) return;
      setState(() {
        _state = state;
        _syncPreferenceBinding(controller, state, generation);
      });
    });
    if (controller.state.isLoading || controller.state.isResolving) {
      unawaited(controller.refresh());
    }
  }

  void _syncPreferenceBinding(
    ChatConversationController controller,
    ChatConversationControllerState state,
    int generation,
  ) {
    final authorized = widget.notificationControls?.authorized == true;
    final canObserve = authorized &&
        state.status == ChatConversationControllerStatus.ready &&
        state.currentUserPreference != null;
    if (!canObserve) {
      _clearPreferenceBinding();
      return;
    }
    if (identical(controller, _preferenceController)) return;

    _clearPreferenceBinding();
    _preferenceController = controller;
    _preferenceState = controller.conversationPreferenceState;
    _preferenceSubscription =
        controller.conversationPreferenceStates.skip(1).listen((preference) {
      if (_disposed ||
          generation != _bindingGeneration ||
          !identical(controller, _preferenceController)) {
        return;
      }
      setState(() => _preferenceState = preference);
    });
  }

  void _clearPreferenceBinding() {
    final subscription = _preferenceSubscription;
    _preferenceSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _preferenceController = null;
    _preferenceState = null;
    _preferenceFeedback = null;
    _commandPending = false;
  }

  void _validateIdentity(ChatConversationController controller) {
    final requested = controller.requestedConversationId;
    final canonical = controller.conversationId;
    if ((requested != null && requested != widget.conversationId) ||
        (requested == null && canonical != widget.conversationId)) {
      throw FlutterError(
        'HandrailChannelHeader received a controller for '
        '${canonical?.value ?? requested?.value ?? 'an unresolved conversation'}, '
        'but conversationId is ${widget.conversationId.value}.',
      );
    }
  }

  void _validateStateIdentity(ChatConversationControllerState state) {
    final canonical = state.conversationId;
    if (canonical != null && canonical != widget.conversationId) {
      throw FlutterError(
        'HandrailChannelHeader observed state for ${canonical.value}, but '
        'conversationId is ${widget.conversationId.value}.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final controller = _controller;
    if (state == null || controller == null) return const SizedBox.shrink();

    return Material(
      key: const ValueKey<String>('handrail-channel-header'),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Keep host actions bounded so they can wrap below the identity
            // without competing with the title and notification controls.
            final compact = constraints.maxWidth < 600;
            final identity = Row(
              children: [
                if (widget.leading case final leading?) leading,
                Expanded(
                  child: Padding(
                    padding: widget.padding,
                    child: _buildState(context, state, controller),
                  ),
                ),
                if (!compact && widget.trailing != null) widget.trailing!,
              ],
            );
            if (!compact) return identity;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity,
                if (widget.trailing case final trailing?)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: trailing,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildState(
    BuildContext context,
    ChatConversationControllerState state,
    ChatConversationController controller,
  ) =>
      switch (state.status) {
        ChatConversationControllerStatus.resolving ||
        ChatConversationControllerStatus.loading =>
          Semantics(
            key: ValueKey<String>('handrail-channel-header-loading'),
            container: true,
            liveRegion: true,
            label: 'Loading conversation',
            child: const Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ChatConversationControllerStatus.ready =>
          _readyState(context, state, controller),
        ChatConversationControllerStatus.error => _retryableState(
            key: 'error',
            message: 'Unable to load conversation',
            controller: controller,
          ),
        ChatConversationControllerStatus.accessRevoked => _stateLabel(
            key:
                state.conversation == null ? 'access-denied' : 'access-revoked',
            message: state.conversation == null
                ? 'Conversation access denied'
                : 'Conversation access revoked',
          ),
        ChatConversationControllerStatus.notFound => _stateLabel(
            key: 'not-found',
            message: 'Conversation not found',
          ),
        ChatConversationControllerStatus.disposed => _stateLabel(
            key: 'unavailable',
            message: 'Conversation unavailable',
          ),
      };

  Widget _readyState(
    BuildContext context,
    ChatConversationControllerState state,
    ChatConversationController controller,
  ) {
    final preference = _preferenceState?.authoritativePreference;
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = _title(context, state);
        if (preference == null) return title;
        final controls = FocusTraversalOrder(
          order: const NumericFocusOrder(1.5),
          child: _notificationControls(controller, preference),
        );
        if (constraints.maxWidth < MediaQuery.textScalerOf(context).scale(320)) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, controls],
          );
        }
        return Row(children: [Expanded(child: title), controls]);
      },
    );
  }

  Widget _notificationControls(
    ChatConversationController controller,
    ConversationSnapshotPreference preference,
  ) {
    final preferenceState = _preferenceState!;
    final pending = _commandPending || preferenceState.isPending;
    final notification = ConversationNotificationPreference.fromJson(
      preference.notificationPreference,
      ConversationPreferenceParseErrorCode.malformedPreference,
    );
    final muteSelection = _muteSelection(preference.mute);
    final feedback = pending
        ? 'Updating conversation notification settings'
        : _preferenceFeedback;
    return Row(
      key: const ValueKey<String>(
        'handrail-channel-notification-controls',
      ),
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<ConversationNotificationPreference>(
          key: const ValueKey<String>(
            'handrail-channel-notification-level',
          ),
          enabled: !pending,
          tooltip: 'Notifications: ${_notificationLabel(notification)}',
          icon: const Icon(Icons.notifications_outlined),
          onSelected: (selected) {
            if (selected == notification) return;
            unawaited(_submitPreference(
              controller,
              notificationPreference: selected,
            ));
          },
          itemBuilder: (context) => [
            for (final option in ConversationNotificationPreference.values)
              CheckedPopupMenuItem<ConversationNotificationPreference>(
                key: ValueKey<String>(
                  'handrail-channel-notification-${option.wireValue}',
                ),
                value: option,
                checked: option == notification,
                child: Text(_notificationLabel(option)),
              ),
          ],
        ),
        PopupMenuButton<_MuteSelection>(
          key: const ValueKey<String>(
            'handrail-channel-notification-mute',
          ),
          enabled: !pending,
          tooltip: 'Mute: ${_muteLabel(muteSelection)}',
          icon: Icon(
            preference.mute.muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_active_outlined,
          ),
          onSelected: (selected) =>
              unawaited(_selectMute(controller, preference, selected)),
          itemBuilder: (context) => [
            for (final option in _MuteSelection.values)
              CheckedPopupMenuItem<_MuteSelection>(
                key: ValueKey<String>(
                  'handrail-channel-notification-mute-${option.name}',
                ),
                value: option,
                checked: option == muteSelection,
                child: Text(_muteLabel(option)),
              ),
          ],
        ),
        if (feedback != null)
          SizedBox.square(
            dimension: 1,
            child: Semantics(
              key: const ValueKey<String>(
                'handrail-channel-notification-feedback',
              ),
              container: true,
              liveRegion: true,
              label: feedback,
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }

  Future<void> _selectMute(
    ChatConversationController controller,
    ConversationSnapshotPreference preference,
    _MuteSelection selected,
  ) async {
    late final ConversationPreferenceMuteState mute;
    switch (selected) {
      case _MuteSelection.unmuted:
        mute = const UnmutedConversationPreference();
      case _MuteSelection.indefinite:
        mute = const IndefinitelyMutedConversationPreference();
      case _MuteSelection.until:
        final picker = widget.notificationControls?.muteUntilPicker ??
            _defaultMuteUntilPicker;
        final until = await picker(context, preference.mute.mutedUntil);
        if (!mounted || until == null) return;
        mute = MutedUntilConversationPreference(until);
    }
    await _submitPreference(
      controller,
      mute: mute,
    );
  }

  Future<IsoTimestamp?> _defaultMuteUntilPicker(
    BuildContext context,
    IsoTimestamp? currentMuteUntil,
  ) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(currentMuteUntil?.value ?? '');
    final initial = current != null && current.isAfter(now)
        ? current.toLocal()
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: DateUtils.dateOnly(initial),
      firstDate: DateUtils.dateOnly(now),
      lastDate: DateUtils.dateOnly(now.add(const Duration(days: 3650))),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return IsoTimestamp(
      DateTime(date.year, date.month, date.day, time.hour, time.minute)
          .toUtc()
          .toIso8601String(),
    );
  }

  Future<void> _submitPreference(
    ChatConversationController controller, {
    ConversationNotificationPreference? notificationPreference,
    ConversationPreferenceMuteState? mute,
  }) async {
    final preferenceState = _preferenceState;
    final authoritative = preferenceState?.authoritativePreference;
    if (_disposed ||
        _commandPending ||
        preferenceState == null ||
        preferenceState.isPending ||
        authoritative == null ||
        !identical(controller, _preferenceController)) {
      return;
    }
    final currentNotification = ConversationNotificationPreference.fromJson(
      authoritative.notificationPreference,
      ConversationPreferenceParseErrorCode.malformedPreference,
    );
    final currentMute = _commandMute(authoritative.mute);
    final nextNotification = notificationPreference ?? currentNotification;
    final nextMute = mute ?? currentMute;
    if (nextNotification == currentNotification &&
        _sameMute(nextMute, currentMute)) {
      return;
    }
    final generation = _bindingGeneration;
    setState(() {
      _commandPending = true;
      _preferenceFeedback = null;
    });
    final result = await controller.updatePreferences(
      notificationPreference: nextNotification,
      isStarred: authoritative.isStarred,
      mute: nextMute,
    );
    if (_disposed ||
        generation != _bindingGeneration ||
        !identical(controller, _preferenceController)) {
      return;
    }
    setState(() {
      _commandPending = false;
      if (result
          case ChatCommandSuccess<UpdateConversationPreferenceResult>(
            :final value,
          )) {
        _preferenceFeedback = value.reconciliationStatus ==
                ConversationPreferenceReconciliationStatus
                    .preferenceRevisionConflict
            ? 'Conversation notification settings changed elsewhere. '
                'Showing current settings.'
            : 'Conversation notification settings updated';
      } else if (result
          case ChatCommandFailure<UpdateConversationPreferenceResult>(
            :final message,
          )) {
        _preferenceFeedback =
            'Unable to update conversation notification settings. $message';
      } else {
        _preferenceFeedback = 'Conversation notification update queued';
      }
    });
  }

  static _MuteSelection _muteSelection(ConversationSnapshotMuteState mute) {
    if (!mute.muted) return _MuteSelection.unmuted;
    return mute.mutedUntil == null
        ? _MuteSelection.indefinite
        : _MuteSelection.until;
  }

  static ConversationPreferenceMuteState _commandMute(
    ConversationSnapshotMuteState mute,
  ) {
    if (!mute.muted) return const UnmutedConversationPreference();
    final until = mute.mutedUntil;
    return until == null
        ? const IndefinitelyMutedConversationPreference()
        : MutedUntilConversationPreference(until);
  }

  static bool _sameMute(
    ConversationPreferenceMuteState first,
    ConversationPreferenceMuteState second,
  ) =>
      first.muted == second.muted &&
      first.mutedUntil?.value == second.mutedUntil?.value;

  static String _notificationLabel(
    ConversationNotificationPreference preference,
  ) =>
      switch (preference) {
        ConversationNotificationPreference.all => 'All messages',
        ConversationNotificationPreference.mentions => 'Mentions',
        ConversationNotificationPreference.none => 'Nothing',
      };

  static String _muteLabel(_MuteSelection selection) => switch (selection) {
        _MuteSelection.unmuted => 'Unmuted',
        _MuteSelection.indefinite => 'Mute indefinitely',
        _MuteSelection.until => 'Mute until…',
      };

  Widget _title(
    BuildContext context,
    ChatConversationControllerState state,
  ) {
    final conversation = state.conversation;
    if (conversation == null) {
      return _stateLabel(
        key: 'unavailable',
        message: 'Conversation unavailable',
      );
    }
    final title = switch (conversation) {
      ChannelConversation(:final name) => name,
      DirectConversation() => 'Direct message',
      GroupDirectConversation() => 'Group conversation',
      ThreadConversation() => 'Thread',
    };
    return Semantics(
      key: const ValueKey<String>('handrail-channel-header-title-semantics'),
      container: true,
      header: true,
      label: title,
      child: ExcludeSemantics(
        child: Text(
          title,
          key: const ValueKey<String>('handrail-channel-header-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HandrailChatTheme.of(context).typography.conversationTitle,
        ),
      ),
    );
  }

  Widget _retryableState({
    required String key,
    required String message,
    required ChatConversationController controller,
  }) =>
      Semantics(
        key: ValueKey<String>('handrail-channel-header-$key'),
        container: true,
        liveRegion: true,
        label: message,
        child: Row(
          children: [
            Flexible(child: Text(message, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey<String>('handrail-channel-header-retry'),
              onPressed: () => unawaited(controller.refresh()),
              child: const Text('Try again'),
            ),
          ],
        ),
      );

  Widget _stateLabel({required String key, required String message}) =>
      Semantics(
        key: ValueKey<String>('handrail-channel-header-$key'),
        container: true,
        liveRegion: true,
        label: message,
        child: Text(
          message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );

  @override
  void dispose() {
    _disposed = true;
    _bindingGeneration += 1;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _clearPreferenceBinding();
    _controller = null;
    super.dispose();
  }
}

bool _sameNotificationControls(
  HandrailChannelNotificationControls? first,
  HandrailChannelNotificationControls? second,
) =>
    first?.authorized == second?.authorized &&
    identical(first?.muteUntilPicker, second?.muteUntilPicker);
