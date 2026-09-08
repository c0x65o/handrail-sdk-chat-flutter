import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'handrail_chat_theme.dart';
import 'media_session.dart';

/// Optional, provider-neutral controls for one Handrail huddle.
///
/// The panel never owns or disposes [controller]. When [mediaSession] is
/// supplied, that session also remains caller-owned and is never closed by the
/// panel. Otherwise the panel creates a session from [mediaDelegate] and closes
/// it when the panel is removed or its controller/session source changes.
class HandrailHuddlePanel extends StatefulWidget {
  const HandrailHuddlePanel({
    required this.controller,
    this.mediaSession,
    this.mediaDelegate,
    this.compactBreakpoint = 600,
    super.key,
  }) : assert(
          mediaSession == null || mediaDelegate == null,
          'mediaDelegate is unused when mediaSession is supplied.',
        );

  final ChatHuddleController controller;

  /// An optional caller-owned session. The panel observes and commands it but
  /// never closes or disposes it.
  final ChatHuddleMediaSession? mediaSession;

  /// Used only when the panel creates and owns its media session.
  final ChatMediaDelegate? mediaDelegate;

  /// Width below which the compact, single-column presentation is used.
  final double compactBreakpoint;

  @override
  State<HandrailHuddlePanel> createState() => _HandrailHuddlePanelState();
}

class _HandrailHuddlePanelState extends State<HandrailHuddlePanel> {
  StreamSubscription<ChatHuddleState>? _controllerSubscription;
  StreamSubscription<ChatMediaSessionState>? _mediaSubscription;
  StreamSubscription<ChatMediaDeviceState>? _deviceSubscription;
  StreamSubscription<List<ChatMediaActiveSpeaker>>? _speakerSubscription;
  late ChatHuddleState _controllerState;
  late ChatMediaSessionState _mediaState;
  ChatHuddleMediaSession? _mediaSession;
  bool _ownsMediaSession = false;
  bool _disposed = false;
  int _bindingGeneration = 0;
  String? _actionFeedback;
  Object? _pendingPanelOperation;

  @override
  void initState() {
    super.initState();
    _bindSources();
  }

  @override
  void didUpdateWidget(covariant HandrailHuddlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.mediaSession != widget.mediaSession ||
        oldWidget.mediaDelegate != widget.mediaDelegate) {
      _unbindSources();
      _actionFeedback = null;
      _pendingPanelOperation = null;
      _bindSources();
    }
  }

  void _bindSources() {
    final generation = ++_bindingGeneration;
    _controllerState = widget.controller.state;
    final suppliedSession = widget.mediaSession;
    final session = suppliedSession ??
        ChatHuddleMediaSession(
          controller: widget.controller,
          delegate: widget.mediaDelegate,
        );
    _mediaSession = session;
    _ownsMediaSession = suppliedSession == null;
    _mediaState = session.state;

    _controllerSubscription = widget.controller.states.listen(
      (state) {
        if (!_isCurrent(generation)) return;
        setState(() => _controllerState = state);
      },
      onError: (_, __) {
        if (!_isCurrent(generation)) return;
        setState(() => _actionFeedback = 'Huddle updates are unavailable.');
      },
    );
    _mediaSubscription = session.states.listen(
      (state) {
        if (!_isCurrent(generation)) return;
        setState(() => _mediaState = state);
      },
      onError: (_, __) {
        if (!_isCurrent(generation)) return;
        setState(() => _actionFeedback = 'Media updates are unavailable.');
      },
    );
    _deviceSubscription = session.deviceStates.listen((_) {
      if (!_isCurrent(generation)) return;
      setState(() => _mediaState = session.state);
    });
    _speakerSubscription = session.activeSpeakers.listen((_) {
      if (!_isCurrent(generation)) return;
      setState(() => _mediaState = session.state);
    });
    _connectWhenReady(generation);
  }

  bool _isCurrent(int generation) =>
      !_disposed && mounted && generation == _bindingGeneration;

  void _connectWhenReady(int generation) {
    final media = _controllerState.media;
    final canonical = _controllerState.canonicalState;
    final status = _mediaState.status;
    if (canonical is! ActiveHuddleState ||
        media is! ChatHuddleMediaReadyState ||
        status == ChatMediaSessionStatus.connected ||
        status == ChatMediaSessionStatus.connecting ||
        status == ChatMediaSessionStatus.unavailable ||
        status == ChatMediaSessionStatus.closing ||
        status == ChatMediaSessionStatus.closed) {
      return;
    }
    unawaited(_connectMedia(generation));
  }

  Future<void> _connectMedia(int generation) async {
    try {
      await _mediaSession?.connect();
    } catch (_) {
      // ChatHuddleMediaSession publishes only stable, renderer-safe failures.
    }
    if (_isCurrent(generation)) {
      setState(() => _mediaState = _mediaSession!.state);
    }
  }

  void _unbindSources() {
    _bindingGeneration += 1;
    final controllerSubscription = _controllerSubscription;
    final mediaSubscription = _mediaSubscription;
    final deviceSubscription = _deviceSubscription;
    final speakerSubscription = _speakerSubscription;
    _controllerSubscription = null;
    _mediaSubscription = null;
    _deviceSubscription = null;
    _speakerSubscription = null;
    unawaited(controllerSubscription?.cancel());
    unawaited(mediaSubscription?.cancel());
    unawaited(deviceSubscription?.cancel());
    unawaited(speakerSubscription?.cancel());

    final session = _mediaSession;
    final owned = _ownsMediaSession;
    _mediaSession = null;
    _ownsMediaSession = false;
    if (owned && session != null) {
      unawaited(session.dispose().catchError((_) {}));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _unbindSources();
    super.dispose();
  }

  bool get _isPending =>
      _pendingPanelOperation != null ||
      _controllerState.pendingOperation != null;

  bool get _isUnavailable =>
      _controllerState.media is ChatHuddleMediaUnavailableState ||
      _mediaState.status == ChatMediaSessionStatus.unavailable;

  Future<void> _runHuddleAction(
    Object operation,
    Future<ChatHuddleActionResult> Function() action, {
    bool connectAfterSuccess = false,
  }) async {
    if (_isPending || _isUnavailable) return;
    final generation = _bindingGeneration;
    setState(() {
      _pendingPanelOperation = operation;
      _actionFeedback = null;
    });
    try {
      final result = await action();
      if (!_isCurrent(generation)) return;
      if (result is ChatHuddleActionFailure) {
        _actionFeedback = _huddleFailureMessage(result.code);
      } else if (result is ChatHuddleActionFeatureDisabled) {
        _actionFeedback = null;
      } else if (connectAfterSuccess) {
        await _connectMedia(generation);
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        _actionFeedback = 'Huddle action could not be completed.';
      }
    } finally {
      if (_isCurrent(generation)) {
        setState(() => _pendingPanelOperation = null);
      }
    }
  }

  Future<void> _runMediaAction(
    ChatMediaOperation operation,
    Future<void> Function(ChatHuddleMediaSession session) action,
  ) async {
    if (_isPending || _isUnavailable) return;
    final session = _mediaSession;
    if (session == null) return;
    final generation = _bindingGeneration;
    setState(() {
      _pendingPanelOperation = operation;
      _actionFeedback = null;
    });
    try {
      await action(session);
    } catch (_) {
      // The session state contains a stable failure; provider text is ignored.
    } finally {
      if (_isCurrent(generation)) {
        setState(() {
          _mediaState = session.state;
          _pendingPanelOperation = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final material = Theme.of(context);
    final chatTheme = HandrailChatTheme.of(context);
    final feedback = _feedbackMessage();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < widget.compactBreakpoint;
        final body = compact
            ? _buildCompact(context, chatTheme)
            : _buildExpanded(context, chatTheme);
        return Semantics(
          container: true,
          label: 'Handrail huddle panel',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: material.colorScheme.surface,
              border: Border.all(color: material.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(chatTheme.radii.large),
            ),
            child: Padding(
              padding: EdgeInsets.all(chatTheme.spacing.large),
              child: Column(
                key: ValueKey(
                  compact
                      ? 'handrail-huddle-compact'
                      : 'handrail-huddle-expanded',
                ),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  body,
                  if (feedback != null) ...[
                    SizedBox(height: chatTheme.spacing.medium),
                    Semantics(
                      liveRegion: true,
                      label: feedback,
                      child: Text(
                        feedback,
                        key: const ValueKey('handrail-huddle-feedback'),
                        style: chatTheme.typography.metadata.copyWith(
                          color: _isUnavailable
                              ? material.colorScheme.onSurfaceVariant
                              : material.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompact(
    BuildContext context,
    HandrailChatThemeData chatTheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(context, chatTheme),
        SizedBox(height: chatTheme.spacing.medium),
        _buildLifecycleControls(),
        if (_participants.isNotEmpty) ...[
          SizedBox(height: chatTheme.spacing.large),
          _buildParticipants(context, chatTheme),
        ],
        if (_showMediaControls) ...[
          SizedBox(height: chatTheme.spacing.large),
          _buildMediaControls(context, chatTheme, compact: true),
        ],
      ],
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    HandrailChatThemeData chatTheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildHeader(context, chatTheme)),
            SizedBox(width: chatTheme.spacing.large),
            _buildLifecycleControls(),
          ],
        ),
        if (_participants.isNotEmpty || _showMediaControls) ...[
          SizedBox(height: chatTheme.spacing.large),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_participants.isNotEmpty)
                Expanded(child: _buildParticipants(context, chatTheme)),
              if (_participants.isNotEmpty && _showMediaControls)
                SizedBox(width: chatTheme.spacing.extraLarge),
              if (_showMediaControls)
                Expanded(
                  child: _buildMediaControls(
                    context,
                    chatTheme,
                    compact: false,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    HandrailChatThemeData chatTheme,
  ) {
    final status = _statusLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Huddle', style: chatTheme.typography.conversationTitle),
        SizedBox(height: chatTheme.spacing.extraSmall),
        Semantics(
          liveRegion: true,
          label: 'Huddle status: $status',
          child: Text(
            status,
            key: const ValueKey('handrail-huddle-status'),
            style: chatTheme.typography.metadata.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLifecycleControls() {
    final canonical = _controllerState.canonicalState;
    final disabled = _isPending || _isUnavailable;
    final children = <Widget>[];
    if (canonical is InactiveHuddleState) {
      children.add(_actionButton(
        keyName: 'start',
        label: 'Start huddle',
        icon: Icons.headset_mic,
        onPressed: disabled
            ? null
            : () => _runHuddleAction(
                  ChatHuddleActionOperation.start,
                  widget.controller.start,
                ),
      ));
    } else if (canonical is LiveHuddleState) {
      final participation = widget.controller.currentActorParticipation;
      final needsJoin = canonical is StartingHuddleState ||
          participation == ChatHuddleActorParticipation.absent ||
          participation == ChatHuddleActorParticipation.left ||
          _controllerState.media is ChatHuddleMediaRejoinRequiredState;
      if (needsJoin) {
        children.add(_actionButton(
          keyName: 'join',
          label: 'Join huddle',
          icon: Icons.call,
          onPressed: disabled
              ? null
              : () => _runHuddleAction(
                    ChatHuddleActionOperation.join,
                    widget.controller.join,
                    connectAfterSuccess: true,
                  ),
        ));
      } else {
        children.add(_actionButton(
          keyName: 'leave',
          label: 'Leave huddle',
          icon: Icons.call_end,
          onPressed: disabled
              ? null
              : () => _runHuddleAction(
                    ChatHuddleActionOperation.leave,
                    widget.controller.leave,
                  ),
        ));
      }
      children.add(_actionButton(
        keyName: 'end',
        label: 'End huddle',
        icon: Icons.stop_circle_outlined,
        destructive: true,
        onPressed: disabled
            ? null
            : () => _runHuddleAction(
                  ChatHuddleActionOperation.end,
                  widget.controller.end,
                ),
      ));
    }
    if (_isPending) {
      children.add(const SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(
          key: ValueKey('handrail-huddle-pending'),
          strokeWidth: 2,
          semanticsLabel: 'Huddle action in progress',
        ),
      ));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }

  Widget _actionButton({
    required String keyName,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool destructive = false,
  }) {
    final buttonKey = ValueKey('handrail-huddle-$keyName');
    if (destructive) {
      return OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }

  Widget _buildParticipants(
    BuildContext context,
    HandrailChatThemeData chatTheme,
  ) {
    final speakingIds = _mediaState.activeSpeakers
        .where((speaker) => speaker.isSpeaking)
        .map((speaker) => speaker.participantId)
        .toSet();
    return Semantics(
      container: true,
      label: 'Huddle participants',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Participants', style: chatTheme.typography.conversationTitle),
          SizedBox(height: chatTheme.spacing.small),
          for (final participant in _participants)
            _participantRow(
              context,
              chatTheme,
              participant,
              speakingIds.contains(participant.userId.value),
            ),
        ],
      ),
    );
  }

  Widget _participantRow(
    BuildContext context,
    HandrailChatThemeData chatTheme,
    HuddleParticipant participant,
    bool speaking,
  ) {
    final joined = participant.status == HuddleParticipantStatus.joined;
    final status = joined ? 'Joined' : 'Departed';
    final semantics = '${participant.userId.value}, $status'
        '${speaking ? ', active speaker' : ''}';
    return Semantics(
      label: semantics,
      child: Padding(
        key: ValueKey(
          'handrail-huddle-participant-${participant.userId.value}',
        ),
        padding: EdgeInsets.symmetric(vertical: chatTheme.spacing.extraSmall),
        child: Row(
          children: [
            Icon(
              speaking ? Icons.graphic_eq : Icons.person_outline,
              size: 20,
              color: speaking
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: chatTheme.spacing.small),
            Expanded(
              child: Text(
                participant.userId.value,
                style: chatTheme.typography.message,
              ),
            ),
            Text(
              speaking ? 'Speaking' : status,
              style: chatTheme.typography.metadata.copyWith(
                color: joined
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaControls(
    BuildContext context,
    HandrailChatThemeData chatTheme, {
    required bool compact,
  }) {
    final connected = _mediaState.status == ChatMediaSessionStatus.connected;
    final enabled = connected && !_isPending && !_isUnavailable;
    final inputDevices = _mediaState.devices.devices
        .where((device) => device.kind == ChatMediaDeviceKind.audioInput)
        .toList(growable: false);
    final outputDevices = _mediaState.devices.devices
        .where((device) => device.kind == ChatMediaDeviceKind.audioOutput)
        .toList(growable: false);
    final selectors = <Widget>[
      if (inputDevices.isNotEmpty)
        _deviceSelector(
          keyName: 'audio-input',
          label: 'Audio input',
          devices: inputDevices,
          selectedId: _selectedDeviceId(
            inputDevices,
            _mediaState.devices.selectedAudioInputId,
          ),
          enabled: enabled,
          onChanged: (deviceId) => _runMediaAction(
            ChatMediaOperation.audioInput,
            (session) => session.selectAudioInput(deviceId),
          ),
        ),
      if (outputDevices.isNotEmpty)
        _deviceSelector(
          keyName: 'audio-output',
          label: 'Audio output',
          devices: outputDevices,
          selectedId: _selectedDeviceId(
            outputDevices,
            _mediaState.devices.selectedAudioOutputId,
          ),
          enabled: enabled,
          onChanged: (deviceId) => _runMediaAction(
            ChatMediaOperation.audioOutput,
            (session) => session.selectAudioOutput(deviceId),
          ),
        ),
    ];
    return Semantics(
      container: true,
      label: 'Huddle media controls',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Media', style: chatTheme.typography.conversationTitle),
          SizedBox(height: chatTheme.spacing.small),
          Wrap(
            spacing: chatTheme.spacing.small,
            runSpacing: chatTheme.spacing.small,
            children: [
              _toggleButton(
                keyName: 'microphone',
                label: _mediaState.microphoneEnabled
                    ? 'Mute microphone'
                    : 'Unmute microphone',
                icon: _mediaState.microphoneEnabled ? Icons.mic : Icons.mic_off,
                selected: _mediaState.microphoneEnabled,
                enabled: enabled,
                onPressed: () => _runMediaAction(
                  ChatMediaOperation.microphone,
                  (session) => session.setMicrophoneEnabled(
                    !_mediaState.microphoneEnabled,
                  ),
                ),
              ),
              _toggleButton(
                keyName: 'screen-share',
                label: _mediaState.screenShareEnabled
                    ? 'Stop screen sharing'
                    : 'Start screen sharing',
                icon: _mediaState.screenShareEnabled
                    ? Icons.stop_screen_share_outlined
                    : Icons.screen_share_outlined,
                selected: _mediaState.screenShareEnabled,
                enabled: enabled,
                onPressed: () => _runMediaAction(
                  ChatMediaOperation.screenShare,
                  (session) => session.setScreenShareEnabled(
                    !_mediaState.screenShareEnabled,
                  ),
                ),
              ),
            ],
          ),
          if (selectors.isNotEmpty) ...[
            SizedBox(height: chatTheme.spacing.medium),
            if (compact)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < selectors.length; index++) ...[
                    if (index > 0) SizedBox(height: chatTheme.spacing.medium),
                    selectors[index],
                  ],
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < selectors.length; index++) ...[
                    if (index > 0) SizedBox(width: chatTheme.spacing.medium),
                    Expanded(child: selectors[index]),
                  ],
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _toggleButton({
    required String keyName,
    required String label,
    required IconData icon,
    required bool selected,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      toggled: selected,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: IconButton.filledTonal(
            key: ValueKey('handrail-huddle-$keyName'),
            onPressed: enabled ? onPressed : null,
            isSelected: selected,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }

  Widget _deviceSelector({
    required String keyName,
    required String label,
    required List<ChatMediaDevice> devices,
    required String? selectedId,
    required bool enabled,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey('handrail-huddle-$keyName'),
      initialValue: selectedId,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        for (final device in devices)
          DropdownMenuItem(value: device.id, child: Text(device.label)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }

  String? _selectedDeviceId(
    List<ChatMediaDevice> devices,
    String? selectedId,
  ) =>
      devices.any((device) => device.id == selectedId) ? selectedId : null;

  List<HuddleParticipant> get _participants {
    final canonical = _controllerState.canonicalState;
    if (canonical is LiveHuddleState) return canonical.participants;
    if (canonical is EndedHuddleState) return canonical.participants;
    return const <HuddleParticipant>[];
  }

  bool get _showMediaControls {
    final participation = widget.controller.currentActorParticipation;
    return _controllerState.canonicalState is ActiveHuddleState &&
        participation != ChatHuddleActorParticipation.absent &&
        participation != ChatHuddleActorParticipation.left &&
        _controllerState.media is! ChatHuddleMediaRejoinRequiredState &&
        !_isUnavailable;
  }

  String get _statusLabel => switch (_controllerState.canonicalState.status) {
        HuddleSessionStatus.inactive => 'Inactive',
        HuddleSessionStatus.starting => 'Starting',
        HuddleSessionStatus.active => 'Active',
        HuddleSessionStatus.ended => 'Huddle ended',
      };

  String? _feedbackMessage() {
    if (_isUnavailable) return 'Huddles are unavailable for this conversation.';
    final actionFeedback = _actionFeedback;
    if (actionFeedback != null) return actionFeedback;
    final mediaFailure = _mediaState.lastFailure;
    if (mediaFailure != null) return _mediaFailureMessage(mediaFailure);
    final controllerMedia = _controllerState.media;
    if (controllerMedia is ChatHuddleMediaErrorState) {
      return _huddleFailureMessage(controllerMedia.code);
    }
    return null;
  }

  String _huddleFailureMessage(ChatHuddleErrorCode code) => switch (code) {
        ChatHuddleErrorCode.authentication =>
          'Huddle access could not be verified.',
        ChatHuddleErrorCode.featureDisabled ||
        ChatHuddleErrorCode.unsupported =>
          'Huddles are unavailable for this conversation.',
        ChatHuddleErrorCode.aborted => 'The huddle action was cancelled.',
        ChatHuddleErrorCode.closed =>
          'Huddle controls are no longer available.',
        _ => 'Huddle action could not be completed.',
      };

  String _mediaFailureMessage(ChatMediaFailure failure) {
    if (failure.code == ChatMediaErrorCode.permissionDenied) {
      return switch (failure.operation) {
        ChatMediaOperation.microphone => 'Microphone permission was denied.',
        ChatMediaOperation.screenShare =>
          'Screen sharing permission was denied.',
        ChatMediaOperation.camera => 'Camera permission was denied.',
        _ => 'Media permission was denied.',
      };
    }
    if (failure.code == ChatMediaErrorCode.providerUnavailable) {
      return 'Media controls are unavailable.';
    }
    return 'Media operation could not be completed.';
  }
}
