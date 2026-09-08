import 'package:flutter/material.dart';
import 'package:handrail_chat/flutter.dart';

/// A fully host-rendered timeline using only public controller/state APIs.
final class ErpCustomTimelineScreen extends StatefulWidget {
  const ErpCustomTimelineScreen({required this.conversationId, super.key});

  final ConversationId conversationId;

  @override
  State<ErpCustomTimelineScreen> createState() =>
      _ErpCustomTimelineScreenState();
}

final class _ErpCustomTimelineScreenState
    extends State<ErpCustomTimelineScreen> {
  final TextEditingController _composer = TextEditingController();
  ChatTimelineController? _timeline;
  bool _sending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timeline ??= ChatScope.of(context).client.timeline(widget.conversationId);
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeline = _timeline!;
    return Scaffold(
      key: const ValueKey<String>('erp-custom-timeline'),
      appBar: AppBar(title: const Text('Custom ERP timeline')),
      body: TimelineStateBuilder(
        controller: timeline,
        builder: (context, state) => Column(
          children: <Widget>[
            if (state.typingUserIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('${state.typingUserIds.length} typing…'),
              ),
            Expanded(child: _buildMessages(timeline, state)),
            _buildComposer(timeline),
          ],
        ),
      ),
    );
  }

  Widget _buildMessages(
    ChatTimelineController timeline,
    ChatTimelineControllerState state,
  ) {
    return switch (state.status) {
      ChatTimelineControllerStatus.loading => const Center(
        child: CircularProgressIndicator(
          key: ValueKey<String>('erp-custom-timeline-loading'),
        ),
      ),
      ChatTimelineControllerStatus.error => Center(
        child: FilledButton(
          onPressed: timeline.refresh,
          child: const Text('Retry timeline'),
        ),
      ),
      ChatTimelineControllerStatus.accessRevoked => const Center(
        child: Text('This conversation is no longer available.'),
      ),
      ChatTimelineControllerStatus.disposed => const SizedBox.shrink(),
      ChatTimelineControllerStatus.ready =>
        state.messages.isEmpty
            ? const Center(child: Text('No messages yet'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: state.messages.length + (state.hasEarlier ? 1 : 0),
                itemBuilder: (context, index) {
                  if (state.hasEarlier && index == 0) {
                    return TextButton(
                      onPressed: timeline.loadEarlier,
                      child: const Text('Load earlier'),
                    );
                  }
                  final message =
                      state.messages[index - (state.hasEarlier ? 1 : 0)];
                  return ListTile(
                    key: ValueKey<String>(
                      'erp-custom-message-${message.id.value}',
                    ),
                    title: Text(message.content?.text ?? 'Message removed'),
                    subtitle: Text('Sequence ${message.sequence.value}'),
                  );
                },
              ),
    };
  }

  Widget _buildComposer(ChatTimelineController timeline) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const ValueKey<String>('erp-custom-composer'),
              controller: _composer,
              decoration: const InputDecoration(
                labelText: 'Message',
                border: OutlineInputBorder(),
              ),
              onSubmitted: _sending ? null : (_) => _send(timeline),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const ValueKey<String>('erp-custom-send'),
            tooltip: 'Send message',
            onPressed: _sending ? null : () => _send(timeline),
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    ),
  );

  Future<void> _send(ChatTimelineController timeline) async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final result = await timeline.sendMessage(
        MessageContent(format: MessageContentFormat.markdown, text: text),
      );
      if (result is ChatCommandSuccess<SendMessageResult>) {
        _composer.clear();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}
