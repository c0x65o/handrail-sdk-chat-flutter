import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';

/// Embeddable settings for the client's saved tenant + user preference.
/// The client owns initialization, synchronization and runtime lifetime.
final class HandrailReplyStyleSettings extends StatefulWidget {
  const HandrailReplyStyleSettings({required this.client, super.key});

  final HandrailChatClient client;

  @override
  State<HandrailReplyStyleSettings> createState() =>
      _HandrailReplyStyleSettingsState();
}

final class _HandrailReplyStyleSettingsState
    extends State<HandrailReplyStyleSettings> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final client = widget.client;
    void changed(Object? _) {
      if (mounted && identical(client, widget.client)) setState(() {});
    }

    _subscriptions.add(client.replyStyles.states.listen(changed));
    _subscriptions.add(client.states.listen(changed));
    final session = client.realtimeSession;
    if (session != null) _subscriptions.add(session.states.listen(changed));
  }

  void _detach() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  void didUpdateWidget(covariant HandrailReplyStyleSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      _detach();
      _listen();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.client.replyStyles;
    final state = runtime.state;
    final confirmed = state.confirmed;
    final requested = state.requestedStyle;
    final lifecycle = widget.client.state;
    final realtime = widget.client.realtimeSession?.state;
    final features = widget.client.realtimeSession != null
        ? (realtime is ChatRealtimeConnectedState
            ? realtime.metadata.enabledFeatures.values
            : const <String, bool>{})
        : (lifecycle is ChatClientReadyState
            ? lifecycle.negotiatedCapabilities
            : const <String, bool>{});
    final capabilitiesKnown = widget.client.realtimeSession != null
        ? realtime is ChatRealtimeConnectedState
        : lifecycle is ChatClientReadyState;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('Reply and thread style',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 12),
        const Text('Current: Reply opens a separate thread. Discord-style: '
            'Reply stays in the current conversation with a reference.'),
        const SizedBox(height: 8),
        const Text('Create Thread / Open Thread is a separate action. '
            'Changing style affects future actions only. Drafts, open threads '
            'and queued sends keep their destination and reply context.'),
        const SizedBox(height: 8),
        const Text(
            'Saved for your account in this tenant, across conversations '
            'and devices. Other tenants have an independent choice.'),
        const SizedBox(height: 12),
        for (final style in ReplyStyle.values)
          RadioListTile<ReplyStyle>(
            key: ValueKey('handrail-reply-style-${style.wireValue}'),
            contentPadding: EdgeInsets.zero,
            title: Text(_label(style.wireValue)),
            value: style,
            // Retain the package's Flutter 3.19 minimum (before RadioGroup).
            // ignore: deprecated_member_use
            groupValue: requested ?? state.effectiveStyle,
            // ignore: deprecated_member_use
            onChanged: state.canEdit && requested == null
                ? (value) {
                    if (value != null) unawaited(runtime.select(value));
                  }
                : null,
          ),
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Effective style: ${_label(state.effectiveStyle.wireValue)} '
                  '— ${_origin(state.origin)}.'),
              if (!state.isResolved)
                const Text('Saved preference is not yet confirmed. '
                    'The displayed style is provisional.'),
              if (confirmed is AbsentReplyStylePreference)
                const Text('No saved choice.'),
              if (confirmed is SavedReplyStylePreference &&
                  (state.origin == ChatReplyStyleOrigin.hostOverride ||
                      confirmed.style != state.effectiveStyle.wireValue))
                Text('Saved choice: ${_label(confirmed.style)}.'),
              if (state.unsupportedValue)
                const Text('An unsupported style value is using Current.'),
              if (state.isLoading)
                const Text('Loading your saved reply style…'),
              if (state.editingUnavailableReason case final reason?)
                Text(reason),
              if (requested != null)
                Text(
                    '${state.isSaving ? 'Saving' : 'Requested choice (unconfirmed)'}: '
                    '${_label(requested.wireValue)}.'),
              if (state.errorMessage case final error?) Text(error),
            ],
          ),
        ),
        if (state.error == ChatReplyStyleError.read)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed:
                  state.isAvailable && !state.isLoading && !state.isSaving
                      ? () => unawaited(runtime.refresh())
                      : null,
              child: const Text('Retry loading reply style'),
            ),
          ),
        if (requested != null && !state.isSaving)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed:
                  state.canRetry ? () => unawaited(runtime.retry()) : null,
              child: const Text('Retry saving reply style'),
            ),
          ),
        const SizedBox(height: 12),
        if (state.capability == ChatReplyStyleCapability.unknown)
          const Text(
              'Checking whether this server supports saving reply style…'),
        if (!capabilitiesKnown)
          const Text('Checking inline reply and named-thread support…')
        else ...[
          if (features[ChatReplyThreadFeatures.inlineReplies] != true)
            const Text('Inline replies are unavailable on this server. '
                'Discord-style Reply cannot be used; it will not open a thread instead.'),
          if (features[ChatReplyThreadFeatures.namedThreads] != true)
            const Text('Named-thread creation is unavailable on this server. '
                'Existing authorized threads remain available.'),
        ],
      ],
    );
  }
}

String _label(String style) => switch (style) {
      'current' => 'Current',
      'discord' => 'Discord-style',
      _ => 'Unsupported choice',
    };

String _origin(ChatReplyStyleOrigin origin) => switch (origin) {
      ChatReplyStyleOrigin.hostOverride => 'enforced by this app',
      ChatReplyStyleOrigin.saved => 'saved preference',
      ChatReplyStyleOrigin.hostDefault => 'app default',
      ChatReplyStyleOrigin.fallback => 'SDK default',
    };
