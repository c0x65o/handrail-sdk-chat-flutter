import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import 'chat_scope.dart';
import 'chat_widget_builders.dart';
import 'handrail_chat_theme.dart';

typedef HandrailChannelSelected = void Function(ConversationId conversationId);
typedef HandrailChannelCreateRequested = void Function();

/// A controller-backed channel list that leaves routing to its host.
///
/// Supply [controller] to retain controller ownership in the caller. Otherwise
/// the widget creates and disposes a scoped controller from [client] or the
/// nearest [ChatScope].
class HandrailChannelList extends StatefulWidget {
  const HandrailChannelList({
    required this.onSelected,
    this.scope = const OrganizationConversationSnapshotScope(),
    this.selectedConversationId,
    this.controller,
    this.client,
    this.builders = const ChatWidgetBuilders(),
    this.canCreateChannels = false,
    this.onCreateChannel,
    this.pageSize = 50,
    this.autofocus = false,
    super.key,
  })  : assert(controller == null || client == null),
        assert(!canCreateChannels || onCreateChannel != null),
        assert(pageSize >= 1 && pageSize <= 100);

  HandrailChannelList.forEntity({
    required HostEntityReference entity,
    required this.onSelected,
    this.selectedConversationId,
    this.controller,
    this.client,
    this.builders = const ChatWidgetBuilders(),
    this.canCreateChannels = false,
    this.onCreateChannel,
    this.pageSize = 50,
    this.autofocus = false,
    super.key,
  })  : assert(controller == null || client == null),
        assert(!canCreateChannels || onCreateChannel != null),
        assert(pageSize >= 1 && pageSize <= 100),
        scope = EntityConversationSnapshotScope(entity: entity);

  final ConversationSnapshotScope scope;
  final ConversationId? selectedConversationId;
  final HandrailChannelSelected onSelected;
  final ChatConversationListController? controller;
  final HandrailChatClient? client;
  final ChatWidgetBuilders builders;

  /// Host-controlled authorization for showing the channel-creation action.
  ///
  /// This is never inferred from conversation membership or normalized state.
  final bool canCreateChannels;
  final HandrailChannelCreateRequested? onCreateChannel;
  final int pageSize;
  final bool autofocus;

  @override
  State<HandrailChannelList> createState() => HandrailChannelListState();
}

/// Public state type for deterministic ownership tests.
class HandrailChannelListState extends State<HandrailChannelList> {
  static const _autoLoadPrefetchItemCount = 3;

  ChatConversationListController? _controller;
  StreamSubscription<ChatConversationListState>? _subscription;
  final ScrollController _scrollController = ScrollController();
  final Map<ConversationId,
          StreamSubscription<NormalizedConversationPreferenceState>>
      _preferenceSubscriptions = {};
  final Map<ConversationId, bool> _starredConversations = {};
  ChatConversationListState? _state;
  bool _ownsController = false;
  bool _disposed = false;
  bool _autoLoadScheduled = false;
  bool _autoLoadInFlight = false;
  int? _autoLoadedItemCount;
  int _controllerBindingGeneration = 0;

  @visibleForTesting
  ChatConversationListController? get debugController => _controller;

  @visibleForTesting
  bool get debugOwnsController => _ownsController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant HandrailChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.client, widget.client) ||
        oldWidget.pageSize != widget.pageSize ||
        !_sameScope(oldWidget.scope, widget.scope)) {
      _bind(force: true);
    }
  }

  void _bind({bool force = false}) {
    final supplied = widget.controller;
    final client = widget.client ?? ChatScope.maybeOf(context)?.client;
    if (supplied == null && client == null) {
      throw FlutterError(
        'HandrailChannelList requires a controller, client, or ChatScope.',
      );
    }
    if (!force && supplied != null && identical(_controller, supplied)) return;
    if (!force && supplied == null && _ownsController && _controller != null) {
      return;
    }

    _controllerBindingGeneration += 1;
    _autoLoadScheduled = false;
    _autoLoadInFlight = false;
    _autoLoadedItemCount = null;
    final oldController = _controller;
    final disposeOld = _ownsController;
    final oldSubscription = _subscription;
    _subscription = null;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _clearPreferenceSubscriptions();
    if (disposeOld && oldController != null) unawaited(oldController.dispose());

    _ownsController = supplied == null;
    _controller = supplied ??
        ChatConversationListController(
          client: client!,
          scope: widget.scope,
          pageSize: widget.pageSize,
        );
    _state = _controller!.state;
    final bound = _controller!;
    _syncPreferenceSubscriptions(bound, _state!.items);
    _subscription = bound.states.listen((state) {
      if (_disposed || !identical(bound, _controller)) return;
      if (mounted) {
        _syncPreferenceSubscriptions(bound, state.items);
        setState(() => _state = state);
      }
    });
    if (bound.state.status == ChatConversationListStatus.loading) {
      unawaited(bound.refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controllerBindingGeneration += 1;
    _autoLoadScheduled = false;
    _autoLoadInFlight = false;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _clearPreferenceSubscriptions();
    if (_ownsController && _controller != null) {
      unawaited(_controller!.dispose());
    }
    _controller = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleAutoLoadMore({
    required ChatConversationListController controller,
    required int index,
    required int projectionLength,
  }) {
    final thresholdIndex = projectionLength > _autoLoadPrefetchItemCount
        ? projectionLength - _autoLoadPrefetchItemCount
        : 0;
    if (index < thresholdIndex ||
        !_canAutoLoad(controller) ||
        _autoLoadScheduled ||
        _autoLoadInFlight ||
        _autoLoadedItemCount == controller.state.items.length) {
      return;
    }

    _autoLoadScheduled = true;
    final bindingGeneration = _controllerBindingGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (bindingGeneration != _controllerBindingGeneration) return;
      _autoLoadScheduled = false;
      if (!_canAutoLoad(controller) ||
          !_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions ||
          _scrollController.position.maxScrollExtent <= 0) {
        return;
      }

      _autoLoadInFlight = true;
      _autoLoadedItemCount = controller.state.items.length;
      unawaited(
        controller.loadMore().then<void>(
              (_) => _finishAutoLoad(controller, bindingGeneration),
              onError: (Object _, StackTrace __) =>
                  _finishAutoLoad(controller, bindingGeneration),
            ),
      );
    });
  }

  bool _canAutoLoad(ChatConversationListController controller) {
    if (_disposed || !mounted || !identical(controller, _controller)) {
      return false;
    }
    final state = controller.state;
    return state.status == ChatConversationListStatus.ready &&
        state.error == null &&
        state.hasMore &&
        !state.isBusy &&
        !state.isDisposed;
  }

  void _finishAutoLoad(
    ChatConversationListController controller,
    int bindingGeneration,
  ) {
    if (bindingGeneration != _controllerBindingGeneration ||
        !identical(controller, _controller)) {
      return;
    }
    _autoLoadInFlight = false;
  }

  void _syncPreferenceSubscriptions(
    ChatConversationListController controller,
    List<ChatConversationListItem> items,
  ) {
    final conversationIds = items.map((item) => item.conversationId).toSet();
    for (final conversationId
        in _preferenceSubscriptions.keys.toList(growable: false)) {
      if (conversationIds.contains(conversationId)) continue;
      unawaited(_preferenceSubscriptions.remove(conversationId)!.cancel());
      _starredConversations.remove(conversationId);
    }

    for (final conversationId in conversationIds) {
      _starredConversations[conversationId] = controller
              .conversationPreference(conversationId)
              .preference
              ?.isStarred ??
          false;
      if (_preferenceSubscriptions.containsKey(conversationId)) continue;
      _preferenceSubscriptions[conversationId] = controller
          .conversationPreferenceStates(conversationId)
          .listen((preferenceState) {
        if (_disposed ||
            !mounted ||
            !identical(controller, _controller) ||
            !_preferenceSubscriptions.containsKey(conversationId)) {
          return;
        }
        final isStarred = preferenceState.preference?.isStarred ?? false;
        if (_starredConversations[conversationId] == isStarred) return;
        setState(() => _starredConversations[conversationId] = isStarred);
      });
    }
  }

  void _clearPreferenceSubscriptions() {
    for (final subscription in _preferenceSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _preferenceSubscriptions.clear();
    _starredConversations.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final controller = _controller;
    if (state == null || controller == null) return const SizedBox.shrink();
    final builders = widget.builders;

    switch (state.status) {
      case ChatConversationListStatus.loading:
        if (state.items.isEmpty) {
          return _withCreateChannelAction(
            context,
            builders.loading(
              context,
              const ChatLoadingBuilderInput(
                target: ChatLoadingTarget.conversationList,
              ),
            ),
          );
        }
      case ChatConversationListStatus.empty:
        return _withCreateChannelAction(
          context,
          const Center(child: Text('No channels')),
        );
      case ChatConversationListStatus.error:
        return _withCreateChannelAction(
          context,
          builders.error(
            context,
            ChatErrorBuilderInput.conversationList(
              error: state.error!,
              conversationListActions: ChatConversationListActions(controller),
            ),
          ),
        );
      case ChatConversationListStatus.accessDenied:
      case ChatConversationListStatus.accessRevoked:
        return _AccessState(
          revoked: state.status == ChatConversationListStatus.accessRevoked,
          onRetry: controller.retry,
        );
      case ChatConversationListStatus.disposed:
        return const Center(child: Text('Channel list unavailable'));
      case ChatConversationListStatus.ready:
        break;
    }

    final chatTheme = HandrailChatTheme.of(context);
    final projection = _ChannelListProjection(
      items: state.items,
      starredConversationIds: _starredConversations.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .toSet(),
    );
    final list = FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ListView.builder(
        key: const ValueKey('handrail-channel-list'),
        controller: _scrollController,
        itemCount: projection.length + (state.hasMore ? 1 : 0),
        findChildIndexCallback: projection.indexForKey,
        itemBuilder: (context, index) {
          if (index == projection.length) {
            return Padding(
              key: const ValueKey('handrail-channel-list-load-more-footer'),
              padding: EdgeInsets.all(chatTheme.spacing.small),
              child: TextButton(
                key: const ValueKey('handrail-channel-list-load-more'),
                onPressed: state.isBusy ? null : controller.loadMore,
                child: state.isBusy
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              key: ValueKey(
                                'handrail-channel-list-loading-more',
                              ),
                              strokeWidth: 2,
                              semanticsLabel: 'Loading channels',
                            ),
                          ),
                          SizedBox(width: 8),
                          ExcludeSemantics(child: Text('Loading channels')),
                        ],
                      )
                    : const Text('Load more'),
              ),
            );
          }

          _scheduleAutoLoadMore(
            controller: controller,
            index: index,
            projectionLength: projection.length,
          );
          final entry = projection.entryAt(index);
          if (entry.isHeader) {
            return _ChannelListSectionHeader(
              key: _channelListEntryKey(entry),
              section: entry.section,
            );
          }

          final item = entry.item!;
          final selected = item.conversationId == widget.selectedConversationId;
          return _ChannelListRow(
            key: _channelListEntryKey(entry),
            controller: controller,
            item: item,
            section: entry.section,
            selected: selected,
            autofocus: widget.autofocus && entry.focusableIndex == 0,
            builder: builders.channel,
            onSelected: widget.onSelected,
          );
        },
      ),
    );
    return _withCreateChannelAction(context, list);
  }

  Widget _withCreateChannelAction(BuildContext context, Widget child) {
    if (!widget.canCreateChannels) return child;
    final chatTheme = HandrailChatTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.all(chatTheme.spacing.small),
          child: FilledButton.icon(
            key: const ValueKey<String>('handrail-create-channel'),
            onPressed: widget.onCreateChannel,
            icon: const Icon(Icons.add),
            label: const Text('Create channel'),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }
}

enum _ChannelListSection {
  starred('Starred', 'starred'),
  directMessages('Direct messages', 'direct-messages'),
  publicChannels('Public channels', 'public-channels'),
  privateChannels('Private channels', 'private-channels'),
  groupConversations('Group conversations', 'group-conversations'),
  threads('Threads', 'threads');

  const _ChannelListSection(this.label, this.keySegment);

  final String label;
  final String keySegment;
}

final class _ChannelListEntry {
  const _ChannelListEntry.header({required this.section})
      : item = null,
        focusableIndex = null;

  const _ChannelListEntry.row({
    required this.section,
    required this.item,
    required this.focusableIndex,
  });

  final _ChannelListSection section;
  final ChatConversationListItem? item;
  final int? focusableIndex;

  bool get isHeader => item == null;
}

final class _ChannelListProjection {
  _ChannelListProjection({
    required List<ChatConversationListItem> items,
    required Set<ConversationId> starredConversationIds,
  }) : _entries = _project(items, starredConversationIds);

  final List<_ChannelListEntry> _entries;

  int get length => _entries.length;

  _ChannelListEntry entryAt(int index) => _entries[index];

  int? indexForKey(Key key) {
    for (var index = 0; index < length; index += 1) {
      if (_channelListEntryKey(entryAt(index)) == key) return index;
    }
    return null;
  }

  static List<_ChannelListEntry> _project(
    List<ChatConversationListItem> items,
    Set<ConversationId> starredConversationIds,
  ) {
    final groupedItems = <_ChannelListSection, List<ChatConversationListItem>>{
      for (final section in _ChannelListSection.values) section: [],
    };
    for (final item in items) {
      if (starredConversationIds.contains(item.conversationId)) {
        groupedItems[_ChannelListSection.starred]!.add(item);
      }
      groupedItems[_ordinarySection(item)]!.add(item);
    }

    final entries = <_ChannelListEntry>[];
    var focusableIndex = 0;
    for (final section in _ChannelListSection.values) {
      final sectionItems = groupedItems[section]!;
      if (sectionItems.isEmpty) continue;
      entries.add(_ChannelListEntry.header(section: section));
      for (final item in sectionItems) {
        entries.add(_ChannelListEntry.row(
          section: section,
          item: item,
          focusableIndex: focusableIndex,
        ));
        focusableIndex += 1;
      }
    }
    return entries;
  }

  static _ChannelListSection _ordinarySection(
    ChatConversationListItem item,
  ) =>
      switch ((item.conversation.type, item.conversation.visibility)) {
        (ConversationType.direct, _) => _ChannelListSection.directMessages,
        (ConversationType.channel, ConversationVisibility.public) =>
          _ChannelListSection.publicChannels,
        (ConversationType.channel, ConversationVisibility.private) =>
          _ChannelListSection.privateChannels,
        (ConversationType.groupDirect, _) =>
          _ChannelListSection.groupConversations,
        (ConversationType.thread, _) => _ChannelListSection.threads,
      };
}

ValueKey<String> _channelListEntryKey(_ChannelListEntry entry) {
  if (entry.isHeader) {
    return ValueKey<String>(
      'handrail-channel-${entry.section.keySegment}-header',
    );
  }
  return ValueKey<String>(
    'handrail-channel-${entry.section.keySegment}-'
    '${entry.item!.conversationId.value}-row',
  );
}

class _ChannelListSectionHeader extends StatelessWidget {
  const _ChannelListSectionHeader({required this.section, super.key});

  final _ChannelListSection section;

  @override
  Widget build(BuildContext context) {
    final chatTheme = HandrailChatTheme.of(context);
    return Semantics(
      key: ValueKey<String>(
        'handrail-channel-${section.keySegment}-header-semantics',
      ),
      container: true,
      header: true,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          chatTheme.spacing.medium,
          chatTheme.spacing.small,
          chatTheme.spacing.medium,
          chatTheme.spacing.extraSmall,
        ),
        child: Text(
          section.label,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }
}

class _ChannelListRow extends StatefulWidget {
  const _ChannelListRow({
    required this.controller,
    required this.item,
    required this.section,
    required this.selected,
    required this.autofocus,
    required this.builder,
    required this.onSelected,
    super.key,
  });

  final ChatConversationListController controller;
  final ChatConversationListItem item;
  final _ChannelListSection section;
  final bool selected;
  final bool autofocus;
  final ChatChannelWidgetBuilder builder;
  final HandrailChannelSelected onSelected;

  @override
  State<_ChannelListRow> createState() => _ChannelListRowState();
}

class _ChannelListRowState extends State<_ChannelListRow> {
  StreamSubscription<NormalizedConversationPreferenceState>? _subscription;
  late NormalizedConversationPreferenceState _preferenceState;
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    _bindPreference();
  }

  @override
  void didUpdateWidget(covariant _ChannelListRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.item.conversationId != widget.item.conversationId) {
      unawaited(_subscription?.cancel());
      _submitting = false;
      _bindPreference();
    }
  }

  void _bindPreference() {
    final controller = widget.controller;
    final conversationId = widget.item.conversationId;
    _preferenceState = controller.conversationPreference(conversationId);
    _subscription = controller
        .conversationPreferenceStates(conversationId)
        .listen((preferenceState) {
      if (!mounted || !identical(controller, widget.controller)) return;
      setState(() => _preferenceState = preferenceState);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }

  Future<void> _toggleStar() async {
    if (_submitting) return;
    final preference = _preferenceState.preference;
    if (preference == null || _preferenceState.isPending) return;
    final desired = !preference.isStarred;
    setState(() => _submitting = true);

    final result = await widget.controller.setConversationStarred(
      widget.item.conversationId,
      isStarred: desired,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result
        case ChatCommandSuccess<UpdateConversationPreferenceResult>(
          :final value,
        )) {
      if (value.reconciliationStatus ==
          ConversationPreferenceReconciliationStatus
              .preferenceRevisionConflict) {
        _showFeedback('Star setting changed elsewhere. Showing the latest.');
      }
      return;
    }
    _showFeedback('Could not update the star. Please try again.');
  }

  void _showFeedback(String message) {
    if (Scaffold.maybeOf(context) == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final selected = widget.selected;
    final theme = Theme.of(context);
    final chatTheme = HandrailChatTheme.of(context);
    final preference = _preferenceState.preference;
    final isStarred = preference?.isStarred ?? false;
    final canToggle =
        preference != null && !_preferenceState.isPending && !_submitting;
    final starLabel = '${isStarred ? 'Unstar' : 'Star'} ${item.displayName}';
    void select() => widget.onSelected(item.conversationId);

    return Material(
      color: selected ? theme.colorScheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(chatTheme.radii.small),
      child: Opacity(
        opacity: item.isArchived ? 0.72 : 1,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                key: ValueKey(
                  'handrail-channel-${widget.section.keySegment}-'
                  '${item.conversationId.value}-semantics',
                ),
                container: true,
                button: true,
                selected: selected,
                label: _semanticsLabel(item, selected: selected),
                onTap: select,
                child: ExcludeSemantics(
                  child: Shortcuts(
                    shortcuts: const <ShortcutActivator, Intent>{
                      SingleActivator(LogicalKeyboardKey.arrowDown):
                          DirectionalFocusIntent(TraversalDirection.down),
                      SingleActivator(LogicalKeyboardKey.arrowUp):
                          DirectionalFocusIntent(TraversalDirection.up),
                      SingleActivator(LogicalKeyboardKey.enter):
                          ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.space):
                          ActivateIntent(),
                    },
                    child: InkWell(
                      key: ValueKey(
                        'handrail-channel-${widget.section.keySegment}-'
                        '${item.conversationId.value}',
                      ),
                      autofocus: widget.autofocus,
                      borderRadius:
                          BorderRadius.circular(chatTheme.radii.small),
                      onTap: select,
                      child: ClipRect(
                        child: DefaultTextStyle.merge(
                          style: chatTheme.typography.conversationTitle,
                          child: Builder(
                            builder: (channelContext) => widget.builder(
                              channelContext,
                              ChatChannelBuilderInput(
                                item: item,
                                selected: selected,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              key: ValueKey(
                'handrail-channel-${widget.section.keySegment}-'
                '${item.conversationId.value}-star-semantics',
              ),
              container: true,
              button: true,
              enabled: canToggle,
              toggled: isStarred,
              label: starLabel,
              onTap: canToggle ? _toggleStar : null,
              child: ExcludeSemantics(
                child: IconButton(
                  key: ValueKey(
                    'handrail-channel-${widget.section.keySegment}-'
                    '${item.conversationId.value}-star',
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: canToggle ? _toggleStar : null,
                  icon: Icon(isStarred ? Icons.star : Icons.star_border),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessState extends StatelessWidget {
  const _AccessState({required this.revoked, required this.onRetry});

  final bool revoked;
  final Future<ChatConversationListState> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(revoked
                ? 'Access to these channels was revoked'
                : 'You do not have access to these channels'),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
}

String _semanticsLabel(
  ChatConversationListItem item, {
  required bool selected,
}) {
  final parts = <String>[
    item.displayName,
    selected ? 'selected' : 'not selected',
  ];
  if (item.unreadCount > 0) {
    parts.add(
      '${item.unreadCount} unread ${item.unreadCount == 1 ? 'message' : 'messages'}',
    );
  }
  if (item.isArchived) parts.add('archived');
  return parts.join(', ');
}

bool _sameScope(
  ConversationSnapshotScope left,
  ConversationSnapshotScope right,
) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());
