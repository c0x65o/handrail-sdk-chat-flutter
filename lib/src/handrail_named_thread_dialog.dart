import 'package:flutter/material.dart';

import '../core.dart';

// Shared by the action and submit-time check. Preference is deliberately absent.
bool namedThreadsAvailable(HandrailChatClient client) {
  final lifecycle = client.state;
  final realtime = client.realtimeSession?.state;
  final features = client.realtimeSession != null
      ? (realtime is ChatRealtimeConnectedState
          ? realtime.metadata.enabledFeatures.values
          : const <String, bool>{})
      : (lifecycle is ChatClientReadyState
          ? lifecycle.negotiatedCapabilities
          : const <String, bool>{});
  return features[ChatReplyThreadFeatures.namedThreads] == true;
}

/// Internal workspace dialog. A successful pop transfers one retain to its caller.
final class HandrailNamedThreadDialog extends StatefulWidget {
  const HandrailNamedThreadDialog({
    required this.client,
    required this.parentId,
    required this.rootId,
    super.key,
  });

  final HandrailChatClient client;
  final ConversationId parentId;
  final MessageId rootId;

  @override
  State<HandrailNamedThreadDialog> createState() =>
      _HandrailNamedThreadDialogState();
}

final class _HandrailNamedThreadDialogState
    extends State<HandrailNamedThreadDialog> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _pending = false;
  bool _attempted = false;
  String? _error;

  String? _validate(String? name) {
    try {
      validateThreadConversationName(name ?? '');
      return null;
    } catch (_) {
      return 'Use 1–100 Unicode characters, without surrounding whitespace.';
    }
  }

  Future<void> _submit() async {
    if (_pending) return;
    if (!_attempted && !_form.currentState!.validate()) return;
    final parent = widget.client.conversations.forConversation(widget.parentId);
    final timeline = widget.client.timelines.forConversation(widget.parentId);
    final root = timeline.state.messages
        .where((message) => message.id == widget.rootId)
        .firstOrNull;
    if (!namedThreadsAvailable(widget.client)) {
      setState(() => _error = 'Named threads are unavailable on this server.');
      return;
    }
    if (parent.state.status != ChatConversationControllerStatus.ready ||
        parent.state.conversation is ThreadConversation ||
        root == null ||
        root.message is DeletedMessage ||
        !timeline.isCanonicalMessage(widget.rootId) ||
        timeline.state.status == ChatTimelineControllerStatus.accessRevoked) {
      setState(() => _error = 'This thread root is no longer available.');
      return;
    }
    final retry = _attempted;
    setState(() {
      _pending = true;
      _attempted = true;
      _error = null;
    });
    final controller = widget.client.threads.forRoot(widget.rootId);
    final result = await (retry
        ? controller.retry()
        : controller.create(name: _name.text, initialFollow: true));
    // Cancellation closes only local UI. An in-flight command may still settle.
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      if (result case ChatThreadOpenSuccess(:final handle)) handle.release();
      return;
    }
    switch (result) {
      case ChatThreadOpenSuccess(:final handle):
        Navigator.of(context).pop(handle);
      case ChatThreadOpenFailure(:final error):
        setState(() {
          _pending = false;
          _error = error.message;
        });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Create Thread'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const ValueKey('handrail-thread-name'),
                  controller: _name,
                  autofocus: true,
                  readOnly: _attempted,
                  decoration: const InputDecoration(labelText: 'Thread name'),
                  validator: _validate,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_pending)
                  Semantics(
                    liveRegion: true,
                    child: const Text('Creating thread…'),
                  ),
                if (_error != null)
                  Semantics(liveRegion: true, child: Text(_error!)),
                if (_attempted && !_pending)
                  const Text(
                      'Retry uses the same name and request. Cancel to start a new request.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('handrail-thread-create-submit'),
            onPressed: _pending ? null : _submit,
            child: Text(_attempted ? 'Retry' : 'Create Thread'),
          ),
        ],
      );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}
