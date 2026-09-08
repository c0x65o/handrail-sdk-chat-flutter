import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';

/// Authorized channel discovery. Opening a row never creates or follows a thread.
///
/// Hosts must supply current trusted authority and replace it on access/identity
/// changes. A supplied controller stays caller-owned; otherwise this widget
/// creates and disposes its own controller through [client.threadLists].
final class HandrailThreadList extends StatefulWidget {
  const HandrailThreadList({
    required this.client,
    required this.parentConversationId,
    required this.authority,
    required this.onSelected,
    this.controller,
    this.opening = false,
    this.pageSize = 50,
    super.key,
  }) : assert(pageSize >= 1 && pageSize <= 100);

  final HandrailChatClient client;
  final ConversationId parentConversationId;
  final ChatThreadListAuthority? authority;
  final ValueChanged<ConversationId> onSelected;
  final ChatThreadListController? controller;
  final bool opening;
  final int pageSize;

  @override
  State<HandrailThreadList> createState() => _HandrailThreadListState();
}

final class _HandrailThreadListState extends State<HandrailThreadList> {
  late ChatThreadListController _controller;
  late ChatThreadListState _state;
  StreamSubscription<ChatThreadListState>? _subscription;
  bool _ownsController = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant HandrailThreadList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client) ||
        !identical(oldWidget.controller, widget.controller) ||
        oldWidget.pageSize != widget.pageSize) {
      _unbind();
      _bind();
    } else if (oldWidget.parentConversationId != widget.parentConversationId ||
        oldWidget.authority?.tenantId != widget.authority?.tenantId ||
        oldWidget.authority?.userId != widget.authority?.userId ||
        oldWidget.authority?.canRead != widget.authority?.canRead) {
      _controller.setScope(widget.parentConversationId,
          authority: widget.authority);
      _observe();
      unawaited(_controller.refresh());
    }
  }

  void _bind() {
    _ownsController = widget.controller == null;
    _controller = widget.controller ??
        widget.client.threadLists
            .forParent(widget.parentConversationId, pageSize: widget.pageSize);
    _controller.setScope(widget.parentConversationId,
        authority: widget.authority);
    _observe();
    unawaited(_controller.refresh());
  }

  void _observe() {
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _state = _controller.state;
    _subscription = _controller.states.listen((state) {
      if (!mounted ||
          generation != _generation ||
          state.parentConversationId != widget.parentConversationId) {
        return;
      }
      setState(() => _state = state);
    });
  }

  void _unbind() {
    ++_generation;
    unawaited(_subscription?.cancel());
    if (_ownsController) unawaited(_controller.dispose());
  }

  void _view(String view) {
    _controller.setScope(widget.parentConversationId,
        authority: widget.authority, view: view);
    _observe();
    unawaited(_controller.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final denied = state.status == ChatThreadListStatus.accessDenied ||
        state.status == ChatThreadListStatus.disposed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (state.lifecycleSupported && !denied)
                for (final view in ['active', 'all'])
                  ChoiceChip(
                    label: Text(view == 'active' ? 'Active' : 'All'),
                    selected: state.view == view,
                    onSelected: state.isBusy ? null : (_) => _view(view),
                  ),
              IconButton(
                tooltip: 'Refresh threads',
                onPressed: denied || state.isBusy
                    ? null
                    : () => unawaited(_controller.refresh()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (state.isBusy || widget.opening)
          const LinearProgressIndicator(semanticsLabel: 'Loading threads'),
        if (state.canRetry)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Semantics(
                liveRegion: true,
                child: const Text('Could not load threads. Please try again.'),
              ),
              TextButton(
                onPressed:
                    state.isBusy ? null : () => unawaited(_controller.retry()),
                child: const Text('Retry threads'),
              ),
            ]),
          ),
        Expanded(
          child: denied
              ? const Center(child: Text('Thread discovery is unavailable.'))
              : state.isEmpty
                  ? const Center(child: Text('No threads found.'))
                  : ListView(
                      children: [
                        for (final item in state.items)
                          ListTile(
                            key: ValueKey(
                                'handrail-thread-list-${item.threadId.value}'),
                            autofocus: item == state.items.first,
                            title: Text(item.conversation.name ?? 'Thread'),
                            subtitle: Text(
                              '${item.currentThreadFollow.follow?.isFollowing == true ? 'Following' : 'Not following'} · ${item.unreadCount} unread',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: widget.opening
                                ? null
                                : () => widget.onSelected(item.threadId),
                          ),
                        if (state.hasMore)
                          TextButton(
                            onPressed: state.isBusy
                                ? null
                                : () => unawaited(_controller.loadMore()),
                            child: const Text('Load more threads'),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }
}
