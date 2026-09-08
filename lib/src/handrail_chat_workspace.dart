import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import 'chat_application_delegates.dart';
import 'chat_scope.dart';
import 'chat_widget_builders.dart';
import 'handrail_channel_header.dart';
import 'handrail_channel_list.dart';
import 'handrail_chat_theme.dart';
import 'handrail_huddle_panel.dart';
import 'handrail_member_picker.dart';
import 'handrail_message_composer.dart';
import 'handrail_message_search.dart';
import 'handrail_message_timeline.dart';
import 'handrail_named_thread_dialog.dart';
import 'handrail_reaction_picker.dart';
import 'handrail_reply_style_settings.dart';
import 'handrail_thread_view.dart';
import 'handrail_thread_list.dart';
import 'handrail_typing_indicator.dart';
import 'media_session.dart';

/// Resolves a caller-owned huddle controller for the active conversation.
typedef HandrailWorkspaceHuddleControllerResolver = ChatHuddleController
    Function(HandrailChatClient client, ConversationId conversationId);

/// Host-backed member-directory configuration for a workspace.
@immutable
final class HandrailWorkspaceMemberConfiguration {
  const HandrailWorkspaceMemberConfiguration({
    required this.searchDirectory,
    required this.authorization,
    this.selectedUserIds = const <UserId>{},
    this.onSelectionChanged,
    this.defaultAddRole = ConversationMembershipMemberRole.member,
    this.roleOptions = const <ConversationMembershipMemberRole>[
      ConversationMembershipMemberRole.member,
    ],
  });

  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final HandrailMemberPickerAuthorization authorization;
  final Set<UserId> selectedUserIds;
  final ValueChanged<Set<UserId>>? onSelectionChanged;
  final ConversationMembershipMemberRole defaultAddRole;
  final List<ConversationMembershipMemberRole> roleOptions;
}

/// Host-backed directory and authorization for direct-conversation creation.
///
/// Supplying a directory does not grant authorization. The workspace only
/// renders the action and invokes [searchDirectory] when [authorized] is true.
@immutable
final class HandrailWorkspaceDirectCreationConfiguration {
  const HandrailWorkspaceDirectCreationConfiguration({
    required this.searchDirectory,
    this.authorized = false,
  });

  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final bool authorized;
}

/// Host-backed directory and authorization for group-direct creation.
///
/// Supplying a directory does not grant authorization. The workspace only
/// renders the action and invokes [searchDirectory] when [authorized] is true.
@immutable
final class HandrailWorkspaceGroupDirectCreationConfiguration {
  const HandrailWorkspaceGroupDirectCreationConfiguration({
    required this.searchDirectory,
    this.authorized = false,
  });

  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final bool authorized;
}

enum _WorkspacePanel { search, members, reactions, huddle, thread, threads }

/// A complete, router-neutral Handrail Chat screen built from public widgets.
///
/// The workspace owns a conversation-list controller only when
/// [conversationListController] is omitted. Client-owned conversation,
/// timeline, thread, and huddle controllers are retained through their public
/// contracts and are never disposed by this widget. Thread handles acquired by
/// the workspace are released when their panel closes or the workspace is
/// disposed.
final class HandrailChatWorkspace extends StatefulWidget {
  const HandrailChatWorkspace({
    this.scope = const OrganizationConversationSnapshotScope(),
    this.initialConversationId,
    this.conversationListController,
    this.builders = const ChatWidgetBuilders(),
    this.delegates = const ChatApplicationDelegates(),
    this.theme,
    this.messageSearch,
    this.searchFilters = HandrailMessageSearchFilter.empty,
    this.members,
    this.mentions,
    this.availableReactions = const <HandrailReactionOption>[],
    this.huddleController,
    this.huddleMediaDelegate,
    this.directCreation,
    this.groupDirectCreation,
    this.notificationControls,
    this.canCreateChannels = false,
    this.compactBreakpoint = 720,
    this.channelPaneWidth = 280,
    this.panelWidth = 380,
    this.pageSize = 50,
    super.key,
  })  : assert(compactBreakpoint > 0),
        assert(channelPaneWidth > 0),
        assert(panelWidth > 0),
        assert(pageSize >= 1 && pageSize <= 100);

  HandrailChatWorkspace.forEntity({
    required HostEntityReference entity,
    this.initialConversationId,
    this.conversationListController,
    this.builders = const ChatWidgetBuilders(),
    this.delegates = const ChatApplicationDelegates(),
    this.theme,
    this.messageSearch,
    this.searchFilters = HandrailMessageSearchFilter.empty,
    this.members,
    this.mentions,
    this.availableReactions = const <HandrailReactionOption>[],
    this.huddleController,
    this.huddleMediaDelegate,
    this.directCreation,
    this.groupDirectCreation,
    this.notificationControls,
    this.canCreateChannels = false,
    this.compactBreakpoint = 720,
    this.channelPaneWidth = 280,
    this.panelWidth = 380,
    this.pageSize = 50,
    super.key,
  })  : scope = EntityConversationSnapshotScope(entity: entity),
        assert(compactBreakpoint > 0),
        assert(channelPaneWidth > 0),
        assert(panelWidth > 0),
        assert(pageSize >= 1 && pageSize <= 100);

  final ConversationSnapshotScope scope;
  final ConversationId? initialConversationId;
  final ChatConversationListController? conversationListController;
  final ChatWidgetBuilders builders;
  final ChatApplicationDelegates delegates;

  /// Overrides chat theme tokens for this workspace and all child surfaces.
  final HandrailChatTheme? theme;

  /// Overrides the negotiated client-backed message-search transport.
  ///
  /// When omitted, search is available only while the scoped client is ready
  /// and [messageSearchFeature] was positively negotiated.
  final HandrailMessageSearchDelegate? messageSearch;
  final HandrailMessageSearchFilter searchFilters;
  final HandrailWorkspaceMemberConfiguration? members;

  /// Optional host directory for composer mentions.
  ///
  /// This is independent from membership-management authorization and is
  /// forwarded unchanged to the selected conversation's composer.
  final HandrailMessageMentionConfiguration? mentions;
  final List<HandrailReactionOption> availableReactions;
  final HandrailWorkspaceHuddleControllerResolver? huddleController;

  /// Optional host media integration for panel-owned huddle sessions.
  ///
  /// The workspace forwards this delegate without invoking it. The huddle
  /// panel creates and closes each media session when its panel is opened and
  /// closed. Omitting it preserves lifecycle-only huddle behavior.
  final ChatMediaDelegate? huddleMediaDelegate;

  /// Optional, explicitly authorized direct-conversation creation surface.
  final HandrailWorkspaceDirectCreationConfiguration? directCreation;

  /// Optional, explicitly authorized group-direct creation surface.
  final HandrailWorkspaceGroupDirectCreationConfiguration? groupDirectCreation;

  /// Optional, explicitly authorized conversation notification controls.
  ///
  /// This is passed to the header unchanged and never inferred from membership.
  final HandrailChannelNotificationControls? notificationControls;

  /// Host-controlled authorization for channel creation.
  ///
  /// This is never inferred from conversation membership or normalized state.
  final bool canCreateChannels;

  final double compactBreakpoint;
  final double channelPaneWidth;
  final double panelWidth;
  final int pageSize;

  @override
  State<HandrailChatWorkspace> createState() => HandrailChatWorkspaceState();
}

/// Public state type for selection and controller-ownership verification.
final class HandrailChatWorkspaceState extends State<HandrailChatWorkspace> {
  final _composerKey = GlobalKey<HandrailMessageComposerState>();

  bool _selectReply(MessageContextRequest source) =>
      _composerKey.currentState?.selectReply(source) ?? false;

  ChatConversationListController? _listController;
  HandrailChatClient? _listClient;
  StreamSubscription<ChatConversationListState>? _listSubscription;
  ChatConversationListState? _listState;
  ConversationId? _selectedConversationId;
  _WorkspacePanel? _panel;
  ChatConversationController? _discoveryParent;
  StreamSubscription<ChatConversationControllerState>?
      _discoveryParentSubscription;
  ChatConversationControllerState? _discoveryParentState;
  bool _discoveryOpen = false;
  FocusNode? _discoveryRowFocus;
  final _threadsActionFocusNode =
      FocusNode(debugLabel: 'Browse channel threads');

  ChatThreadListAuthority? get _discoveryAuthority {
    final state = _discoveryParentState;
    final conversation = state?.conversation;
    final user = state?.currentUserReadState?.userId;
    // A ready authorized parent snapshot supplies identity, never membership or
    // following. Every list/open request still rechecks server authorization.
    if (state?.status != ChatConversationControllerStatus.ready ||
        conversation is! ChannelConversation ||
        user == null ||
        conversation.archivedAt != null ||
        state?.lifecycle?.authoritativeArchived == true) {
      return null;
    }
    return ChatThreadListAuthority(
        tenantId: conversation.tenantId, userId: user, canRead: true);
  }

  void _bindDiscoveryParent() {
    final id = _selectedConversationId;
    final client = ChatScope.of(context).client;
    final controller =
        id == null ? null : client.conversations.forConversation(id);
    if (identical(controller, _discoveryParent)) return;
    unawaited(_discoveryParentSubscription?.cancel());
    _discoveryParent = controller;
    _discoveryParentState = controller?.state;
    _discoveryParentSubscription = controller?.states.listen((state) {
      if (_disposed || !identical(controller, _discoveryParent)) return;
      setState(() => _discoveryParentState = state);
      if (_discoveryOpen && _discoveryAuthority == null) _closePanel();
    });
  }

  ChatThreadOpenHandle? _threadHandle;
  ChatThreadOpenHandle? _presentingThreadHandle;
  MessageId? _threadRootMessageId;
  ChatMessageBuilderInput? _reactionInput;
  HandrailChatClient? _messageSearchClient;
  HandrailMessageSearchDelegate? _clientMessageSearch;
  GlobalKey<_ForwardMessageDialogState>? _forwardDialogKey;
  bool _ownsListController = false;
  bool _showChannels = true;
  bool _openingThread = false;
  DialogRoute<ChatThreadOpenHandle>? _namedThreadRoute;
  HandrailChatClient? _namedThreadClient;
  HandrailChatClient? _threadClient;
  int _bindingGeneration = 0;
  int _threadGeneration = 0;
  bool _disposed = false;
  DialogRoute<void>? _settingsRoute;
  HandrailChatClient? _settingsClient;
  final FocusNode _settingsActionFocusNode =
      FocusNode(debugLabel: 'Open workspace settings');
  final FocusNode _searchActionFocusNode =
      FocusNode(debugLabel: 'Search messages');
  final FocusNode _membersActionFocusNode =
      FocusNode(debugLabel: 'Manage members');
  final FocusNode _huddleActionFocusNode = FocusNode(debugLabel: 'Open huddle');
  FocusNode? _panelReturnFocusNode;

  @visibleForTesting
  ChatConversationListController? get debugConversationListController =>
      _listController;

  @visibleForTesting
  bool get debugOwnsConversationListController => _ownsListController;

  @visibleForTesting
  ConversationId? get selectedConversationId => _selectedConversationId;

  bool get _canCreateDirectConversation =>
      widget.directCreation?.authorized == true;

  bool get _canCreateGroupDirectConversation =>
      widget.groupDirectCreation?.authorized == true;

  HandrailMessageSearchDelegate? _messageSearchFor(
    ChatScopeBinding binding,
  ) {
    final hostSearch = widget.messageSearch;
    if (hostSearch != null) return hostSearch;
    final lifecycle = binding.state;
    if (lifecycle is! ChatClientReadyState ||
        lifecycle.negotiatedCapabilities[messageSearchFeature] != true) {
      return null;
    }
    if (!identical(_messageSearchClient, binding.client)) {
      _messageSearchClient = binding.client;
      _clientMessageSearch = (request) => _searchMessages(
            binding.client,
            request,
          );
    }
    return _clientMessageSearch;
  }

  Future<HandrailMessageSearchPage> _searchMessages(
    HandrailChatClient client,
    HandrailMessageSearchRequest request,
  ) async {
    final result = await client.searchMessages(request);
    return switch (result) {
      ChatSnapshotQuerySuccess<HandrailMessageSearchPage>(:final value) =>
        value,
      _ => throw const _WorkspaceMessageSearchFailure(),
    };
  }

  @override
  void initState() {
    super.initState();
    _selectedConversationId = widget.initialConversationId;
    _showChannels = widget.initialConversationId == null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settingsRoute != null &&
        !identical(_settingsClient, ChatScope.of(context).client)) {
      _dismissSettings();
    }
    if ((_namedThreadClient != null &&
            !identical(_namedThreadClient, ChatScope.of(context).client)) ||
        (_threadClient != null &&
            !identical(_threadClient, ChatScope.of(context).client))) {
      _closePanel();
      _threadClient = null;
    }
    _bindListController();
    _bindDiscoveryParent();
  }

  void _dismissSettings() {
    final route = _settingsRoute;
    _settingsRoute = null;
    _settingsClient = null;
    // Identity changes and disposal can happen during the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }

  Future<void> _showSettings() async {
    if (_settingsRoute != null) return;
    final client = ChatScope.of(context).client;
    _settingsClient = client;
    final route = DialogRoute<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Workspace settings'),
        content: SizedBox(
          width: 440,
          child: HandrailReplyStyleSettings(client: client),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close settings'),
          ),
        ],
      ),
    );
    _settingsRoute = route;
    // A route overlay retains the conversation, composer and open thread.
    // Do not use _openPanel here: it releases the retained thread handle.
    await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_settingsRoute, route)) {
      _settingsRoute = null;
      _settingsClient = null;
      if (mounted && _settingsActionFocusNode.canRequestFocus) {
        _settingsActionFocusNode.requestFocus();
      }
    }
  }

  Widget _settingsButton() => IconButton(
        key: const ValueKey<String>('handrail-workspace-settings'),
        tooltip: 'Open workspace settings',
        focusNode: _settingsActionFocusNode,
        onPressed: _showSettings,
        icon: const Icon(Icons.settings_outlined),
      );

  @override
  void didUpdateWidget(covariant HandrailChatWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
          oldWidget.conversationListController,
          widget.conversationListController,
        ) ||
        oldWidget.pageSize != widget.pageSize ||
        !_sameScope(oldWidget.scope, widget.scope)) {
      _bindListController(force: true);
    }
    if (oldWidget.initialConversationId != widget.initialConversationId &&
        widget.initialConversationId != null) {
      _selectConversation(widget.initialConversationId!);
    }
  }

  void _bindListController({bool force = false}) {
    final supplied = widget.conversationListController;
    final client = ChatScope.of(context).client;
    if (!force && supplied != null && identical(_listController, supplied)) {
      return;
    }
    if (!force &&
        supplied == null &&
        _ownsListController &&
        identical(_listClient, client)) {
      return;
    }

    _forwardDialogKey?.currentState?.cancelAndClose();

    final generation = ++_bindingGeneration;
    final previous = _listController;
    final disposePrevious = _ownsListController;
    final subscription = _listSubscription;
    _listSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (disposePrevious && previous != null) unawaited(previous.dispose());

    final controller = supplied ??
        ChatConversationListController(
          client: client,
          scope: widget.scope,
          pageSize: widget.pageSize,
        );
    _ownsListController = supplied == null;
    _listClient = supplied == null ? client : null;
    _listController = controller;
    _listState = controller.state;
    _synchronizeSelection(controller.state);
    _listSubscription = controller.states.listen((state) {
      if (_disposed || generation != _bindingGeneration) return;
      setState(() {
        _listState = state;
        _synchronizeSelection(state, notify: false);
      });
      if (_discoveryOpen &&
          (state.status == ChatConversationListStatus.accessDenied ||
              state.status == ChatConversationListStatus.accessRevoked ||
              state.status == ChatConversationListStatus.disposed)) {
        _closePanel();
      }
    });
    if (controller.state.status == ChatConversationListStatus.loading) {
      unawaited(controller.refresh());
    }
  }

  void _synchronizeSelection(
    ChatConversationListState state, {
    bool notify = true,
  }) {
    if (_selectedConversationId != null || state.items.isEmpty) return;
    void select() {
      _selectedConversationId = state.items.first.conversationId;
      _showChannels = false;
      _bindDiscoveryParent();
    }

    if (notify && mounted) {
      setState(select);
    } else {
      select();
    }
  }

  void _selectConversation(ConversationId conversationId) {
    if (_selectedConversationId == conversationId && !_showChannels) return;
    _closePanel();
    setState(() {
      _selectedConversationId = conversationId;
      _showChannels = false;
      _bindDiscoveryParent();
    });
  }

  void _showChannelNavigation() {
    _closePanel();
    setState(() => _showChannels = true);
  }

  Future<void> _showCreateChannelDialog() async {
    final entity = switch (widget.scope) {
      EntityConversationSnapshotScope(:final entity) => entity,
      OrganizationConversationSnapshotScope() => null,
    };
    final conversationId = await showDialog<ConversationId>(
      context: context,
      builder: (dialogContext) => _CreateChannelDialog(
        client: ChatScope.of(context).client,
        entity: entity,
      ),
    );
    if (!mounted || conversationId == null) return;
    _selectConversation(conversationId);
  }

  Future<void> _showCreateDirectDialog() async {
    final configuration = widget.directCreation;
    if (configuration == null || !configuration.authorized) return;
    final conversationId = await showDialog<ConversationId>(
      context: context,
      builder: (dialogContext) => _CreateDirectDialog(
        client: ChatScope.of(context).client,
        searchDirectory: configuration.searchDirectory,
      ),
    );
    if (!mounted || conversationId == null) return;
    _selectConversation(conversationId);
  }

  Future<void> _showCreateGroupDirectDialog() async {
    final configuration = widget.groupDirectCreation;
    if (configuration == null || !configuration.authorized) return;
    final conversationId = await showDialog<ConversationId>(
      context: context,
      builder: (dialogContext) => _CreateGroupDirectDialog(
        client: ChatScope.of(context).client,
        searchDirectory: configuration.searchDirectory,
      ),
    );
    if (!mounted || conversationId == null) return;
    _selectConversation(conversationId);
  }

  Future<void> _showForwardDialog(ChatMessageActions actions) async {
    if (_forwardDialogKey != null) return;
    final controller = _listController;
    final state = _listState;
    if (controller == null || state == null || state.items.isEmpty) return;
    final generation = _bindingGeneration;
    final key = GlobalKey<_ForwardMessageDialogState>();
    _forwardDialogKey = key;
    ForwardMessageResult? result;
    try {
      result = await showDialog<ForwardMessageResult>(
        context: context,
        builder: (dialogContext) => _ForwardMessageDialog(
          key: key,
          actions: actions,
          destinations: List<ChatConversationListItem>.unmodifiable(
            state.items,
          ),
        ),
      );
    } finally {
      if (identical(_forwardDialogKey, key)) _forwardDialogKey = null;
    }
    if (_disposed ||
        !mounted ||
        generation != _bindingGeneration ||
        !identical(controller, _listController) ||
        result == null) {
      return;
    }
    _selectConversation(result.destinationConversationId);
  }

  void _openPanel(_WorkspacePanel panel, FocusNode returnFocusNode) {
    _discoveryOpen = panel == _WorkspacePanel.threads;
    if (_discoveryOpen) _threadClient = ChatScope.of(context).client;
    _threadGeneration += 1;
    _openingThread = false;
    _releaseThreadHandle();
    setState(() {
      _reactionInput = null;
      _threadRootMessageId = null;
      _panel = panel;
      _panelReturnFocusNode = returnFocusNode;
    });
  }

  void _openReactionPicker(ChatMessageBuilderInput input) {
    _threadGeneration += 1;
    _openingThread = false;
    _releaseThreadHandle();
    setState(() {
      _reactionInput = input;
      _threadRootMessageId = null;
      _panel = _WorkspacePanel.reactions;
      _panelReturnFocusNode = null;
    });
  }

  void _dismissNamedThread() {
    final route = _namedThreadRoute;
    _namedThreadRoute = null;
    _namedThreadClient = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }

  Future<void> _createNamedThread(ChatMessageActions actions) async {
    if (_openingThread || _namedThreadRoute != null) return;
    final parentId = _selectedConversationId;
    if (parentId == null) return;
    final client = ChatScope.of(context).client;
    final generation = ++_threadGeneration;
    final returnFocus = FocusManager.instance.primaryFocus;
    final route = DialogRoute<ChatThreadOpenHandle>(
      context: context,
      builder: (_) => HandrailNamedThreadDialog(
        client: client,
        parentId: parentId,
        rootId: actions.messageId,
      ),
    );
    _namedThreadRoute = route;
    _namedThreadClient = client;
    _threadClient = client;
    final handle = await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_namedThreadRoute, route)) {
      _namedThreadRoute = null;
      _namedThreadClient = null;
    }
    if (_disposed || !mounted || generation != _threadGeneration) {
      handle?.release();
      return;
    }
    if (returnFocus?.context != null && returnFocus!.canRequestFocus) {
      returnFocus.requestFocus();
    }
    if (handle != null) {
      setState(() => _openingThread = true);
      await _presentThread(handle, generation, returnFocus);
    }
  }

  Future<void> _openThread(ChatMessageActions actions) async {
    if (_openingThread || _namedThreadRoute != null) return;
    final generation = ++_threadGeneration;
    final returnFocus = FocusManager.instance.primaryFocus;
    setState(() => _openingThread = true);
    final client = ChatScope.of(context).client;
    _threadClient = client;
    final existingId =
        client
            .normalizedState
            .state
            .canonicalMessages[actions.messageId]
            ?.threadSummary
            ?.threadId ??
        client.normalizedState.state.conversations.values
            .whereType<ThreadConversation>()
            .where(
              (thread) =>
                  thread.rootMessageId == actions.messageId &&
                  thread.parentConversationId == _selectedConversationId,
            )
            .firstOrNull
            ?.id;
    if (existingId != null) {
      final existing = await client.threads.openExistingThread(existingId);
      if (_disposed || !mounted || generation != _threadGeneration) {
        if (existing case ChatExistingThreadOpenSuccess(:final handle)) {
          handle.release();
        }
        return;
      }
      switch (existing) {
        case ChatExistingThreadOpenSuccess(:final handle):
          await _presentThread(handle, generation, returnFocus);
        case ChatExistingThreadOpenFailure():
          setState(() => _openingThread = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This thread is unavailable. Try Open Thread again.',
              ),
            ),
          );
      }
      return;
    }
    final result = await actions.openThread();
    if (_disposed || !mounted || generation != _threadGeneration) {
      if (result case ChatThreadOpenSuccess(:final handle)) handle.release();
      return;
    }
    switch (result) {
      case ChatThreadOpenSuccess(:final handle):
        await _presentThread(handle, generation, returnFocus);
      case ChatThreadOpenFailure():
        _releaseThreadHandle();
        setState(() {
          _threadRootMessageId = actions.messageId;
          _reactionInput = null;
          _panel = _WorkspacePanel.thread;
          _panelReturnFocusNode = returnFocus;
          _openingThread = false;
        });
    }
  }

  Future<void> _openDiscoveredThread(ConversationId id) async {
    if (_openingThread || _discoveryAuthority == null) return;
    final client = ChatScope.of(context).client;
    final parent = _selectedConversationId;
    final generation = ++_threadGeneration;
    _threadClient = client;
    _discoveryRowFocus = FocusManager.instance.primaryFocus;
    setState(() => _openingThread = true);
    final result = await client.threads.openExistingThread(id);
    if (_disposed ||
        !mounted ||
        generation != _threadGeneration ||
        parent != _selectedConversationId ||
        _discoveryAuthority == null) {
      if (result case ChatExistingThreadOpenSuccess(:final handle)) {
        handle.release();
      }
      return;
    }
    if (result case ChatExistingThreadOpenSuccess(:final handle)) {
      if (handle.state.parentConversationId == parent) {
        await _presentThread(handle, generation, _threadsActionFocusNode);
        return;
      }
      handle.release();
    }
    setState(() => _openingThread = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This thread is unavailable. Try opening it again.'),
    ));
  }

  void _backPanel() {
    if (_discoveryOpen && _panel == _WorkspacePanel.thread) {
      ++_threadGeneration;
      _releaseThreadHandle();
      setState(() {
        _panel = _WorkspacePanel.threads;
        _threadRootMessageId = null;
        _openingThread = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _discoveryRowFocus?.context != null) {
          _discoveryRowFocus?.requestFocus();
        }
      });
    } else {
      _closePanel();
    }
  }

  Future<void> _presentThread(
    ChatThreadOpenHandle handle,
    int generation,
    FocusNode? returnFocus,
  ) async {
    _presentingThreadHandle = handle;
    // Delegate calls consume the ID, never ownership of this retain.
    ChatApplicationDelegateResult delegateResult;
    try {
      delegateResult = await widget.delegates.openThread(handle.conversationId);
    } catch (_) {
      if (identical(_presentingThreadHandle, handle)) {
        _presentingThreadHandle = null;
      }
      handle.release();
      if (!_disposed && mounted && generation == _threadGeneration) {
        setState(() => _openingThread = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The host could not open this thread. Try Open Thread again.',
            ),
          ),
        );
      }
      return;
    }
    if (identical(_presentingThreadHandle, handle)) {
      _presentingThreadHandle = null;
    }
    if (_disposed || !mounted || generation != _threadGeneration) {
      handle.release();
      return;
    }
    if (delegateResult != ChatApplicationDelegateResult.unavailable) {
      handle.release();
      setState(() => _openingThread = false);
      return;
    }
    _releaseThreadHandle();
    setState(() {
      _threadHandle = handle;
      _threadRootMessageId = handle.rootMessageId;
      _reactionInput = null;
      _panel = _WorkspacePanel.thread;
      _panelReturnFocusNode = returnFocus;
      _openingThread = false;
    });
  }

  void _closePanel() {
    _discoveryOpen = false;
    _discoveryRowFocus = null;
    _dismissNamedThread();
    _threadGeneration += 1;
    _releaseThreadHandle();
    if (!mounted) return;
    final returnFocusNode = _panelReturnFocusNode;
    setState(() {
      _panel = null;
      _panelReturnFocusNode = null;
      _reactionInput = null;
      _threadRootMessageId = null;
      _openingThread = false;
    });
    if (returnFocusNode?.context != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && returnFocusNode!.canRequestFocus) {
          returnFocusNode.requestFocus();
        }
      });
    }
  }

  void _releaseThreadHandle() {
    _presentingThreadHandle?.release();
    _presentingThreadHandle = null;
    _threadHandle?.release();
    _threadHandle = null;
  }

  @override
  Widget build(BuildContext context) {
    final hostTheme = Theme.of(context);
    final override = widget.theme;
    final content = LayoutBuilder(builder: _buildLayout);
    if (override == null) return content;
    return Theme(
      data: hostTheme.copyWith(
        extensions: <ThemeExtension<dynamic>>[
          for (final extension in hostTheme.extensions.values)
            if (extension is! HandrailChatTheme) extension as dynamic,
          override,
        ],
      ),
      child: content,
    );
  }

  Widget _buildLayout(BuildContext context, BoxConstraints constraints) {
    final state = _listState;
    final controller = _listController;
    if (state == null || controller == null) return const SizedBox.shrink();
    final blocking = _buildBlockingState(context, state, controller);
    if (blocking != null) return blocking;

    final narrow = constraints.maxWidth < widget.compactBreakpoint;
    return PopScope(
      canPop: !_discoveryOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _discoveryOpen) _backPanel();
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Material(
          key: ValueKey<String>(
            narrow ? 'handrail-workspace-narrow' : 'handrail-workspace-wide',
          ),
          color: Theme.of(context).colorScheme.surface,
          child: narrow ? _buildNarrow(context) : _buildWide(context),
        ),
      ),
    );
  }

  Widget? _buildBlockingState(
    BuildContext context,
    ChatConversationListState state,
    ChatConversationListController controller,
  ) {
    if (state.status == ChatConversationListStatus.accessDenied ||
        state.status == ChatConversationListStatus.accessRevoked ||
        state.status == ChatConversationListStatus.disposed) {
      return switch (state.status) {
        ChatConversationListStatus.accessDenied => _WorkspaceAccessState(
            key: const ValueKey<String>('handrail-workspace-access-denied'),
            message: 'Chat access denied',
            onRetry: controller.retry,
          ),
        ChatConversationListStatus.accessRevoked => _WorkspaceAccessState(
            key: const ValueKey<String>('handrail-workspace-access-revoked'),
            message: 'Chat access revoked',
            onRetry: controller.retry,
          ),
        ChatConversationListStatus.disposed => const Center(
            key: ValueKey<String>('handrail-workspace-unavailable'),
            child: Text('Chat unavailable'),
          ),
        _ => null,
      };
    }
    if (state.items.isNotEmpty) return null;
    return switch (state.status) {
      ChatConversationListStatus.loading => widget.builders.loading(
          context,
          const ChatLoadingBuilderInput(
            target: ChatLoadingTarget.conversationList,
          ),
        ),
      ChatConversationListStatus.empty => widget.canCreateChannels ||
              _canCreateDirectConversation ||
              _canCreateGroupDirectConversation
          ? null
          : Column(
              children: [
                const Expanded(
                  child: Center(
                    key: ValueKey<String>('handrail-workspace-empty'),
                    child: Text('No conversations'),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: _settingsButton(),
                ),
              ],
            ),
      ChatConversationListStatus.error => widget.builders.error(
          context,
          ChatErrorBuilderInput.conversationList(
            error: state.error!,
            conversationListActions: ChatConversationListActions(controller),
          ),
        ),
      ChatConversationListStatus.accessDenied ||
      ChatConversationListStatus.accessRevoked ||
      ChatConversationListStatus.disposed =>
        null,
      ChatConversationListStatus.ready => null,
    };
  }

  Widget _buildWide(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey<String>('handrail-workspace-channels'),
          width: widget.channelPaneWidth,
          child: FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: _buildChannels(
              showSettings: _selectedConversationId == null,
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _buildConversation(context, narrow: false)),
        if (_panel != null) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            key: const ValueKey<String>('handrail-workspace-panel'),
            width: widget.panelWidth,
            child: FocusTraversalOrder(
              order: const NumericFocusOrder(7),
              child: _buildPanel(context),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNarrow(BuildContext context) {
    if (_showChannels || _selectedConversationId == null) {
      return KeyedSubtree(
        key: const ValueKey<String>('handrail-workspace-channel-page'),
        child: _buildChannels(showSettings: true),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_panel == null || _discoveryOpen)
          Offstage(
            offstage: _panel != null,
            child: ExcludeFocus(
              excluding: _panel != null,
              child: TickerMode(
                enabled: _panel == null,
                child: KeyedSubtree(
                  key: const ValueKey<String>(
                      'handrail-workspace-conversation-page'),
                  child: _buildConversation(context, narrow: true),
                ),
              ),
            ),
          ),
        if (_panel != null)
          KeyedSubtree(
            key: const ValueKey<String>('handrail-workspace-panel-page'),
            child: _buildPanel(context, showSettings: true),
          ),
      ],
    );
  }

  Widget _buildChannels({bool showSettings = false}) {
    final channels = HandrailChannelList(
      scope: widget.scope,
      selectedConversationId: _selectedConversationId,
      controller: _listController,
      builders: widget.builders,
      autofocus: true,
      canCreateChannels: widget.canCreateChannels,
      onCreateChannel:
          widget.canCreateChannels ? _showCreateChannelDialog : null,
      onSelected: _selectConversation,
    );
    if (!_canCreateDirectConversation &&
        !_canCreateGroupDirectConversation &&
        !showSettings) {
      return channels;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_canCreateDirectConversation)
          Padding(
            padding:
                EdgeInsets.all(HandrailChatTheme.of(context).spacing.small),
            child: OutlinedButton.icon(
              key: const ValueKey<String>('handrail-create-direct'),
              onPressed: _showCreateDirectDialog,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Start direct message'),
            ),
          ),
        if (_canCreateGroupDirectConversation)
          Padding(
            padding:
                EdgeInsets.all(HandrailChatTheme.of(context).spacing.small),
            child: OutlinedButton.icon(
              key: const ValueKey<String>('handrail-create-group-direct'),
              onPressed: _showCreateGroupDirectDialog,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Start group message'),
            ),
          ),
        const Divider(height: 1),
        Expanded(child: channels),
        if (showSettings)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: _settingsButton(),
          ),
      ],
    );
  }

  Widget _buildConversation(BuildContext context, {required bool narrow}) {
    final conversationId = _selectedConversationId;
    if (conversationId == null) {
      return const Center(child: Text('Select a conversation'));
    }
    final messageSearch = _messageSearchFor(ChatScope.of(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HandrailChannelHeader(
          conversationId: conversationId,
          notificationControls: widget.notificationControls,
          leading: narrow
              ? FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: IconButton(
                    key: const ValueKey<String>('handrail-workspace-back'),
                    tooltip: 'Back to conversations',
                    onPressed: _showChannelNavigation,
                    icon: const Icon(Icons.arrow_back),
                  ),
                )
              : null,
          trailing: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_discoveryAuthority != null)
                _actionButton(
                  order: 2,
                  key: 'threads',
                  tooltip: 'Browse channel threads',
                  icon: Icons.forum_outlined,
                  focusNode: _threadsActionFocusNode,
                  onPressed: () => _openPanel(
                      _WorkspacePanel.threads, _threadsActionFocusNode),
                ),
              if (messageSearch != null)
                _actionButton(
                  order: 2,
                  key: 'search',
                  tooltip: 'Search messages',
                  icon: Icons.search,
                  focusNode: _searchActionFocusNode,
                  onPressed: () => _openPanel(
                    _WorkspacePanel.search,
                    _searchActionFocusNode,
                  ),
                ),
              if (widget.members != null)
                _actionButton(
                  order: 3,
                  key: 'members',
                  tooltip: 'Manage members',
                  icon: Icons.group_outlined,
                  focusNode: _membersActionFocusNode,
                  onPressed: () => _openPanel(
                    _WorkspacePanel.members,
                    _membersActionFocusNode,
                  ),
                ),
              if (widget.huddleController != null)
                _actionButton(
                  order: 4,
                  key: 'huddle',
                  tooltip: 'Open huddle',
                  icon: Icons.headset_mic_outlined,
                  focusNode: _huddleActionFocusNode,
                  onPressed: () => _openPanel(
                    _WorkspacePanel.huddle,
                    _huddleActionFocusNode,
                  ),
                ),
              if (_openingThread)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              _settingsButton(),
            ],
          ),
        ),
        Expanded(
          child: FocusTraversalOrder(
            order: const NumericFocusOrder(5),
            child: HandrailMessageTimeline(
              key: ValueKey<String>(
                'handrail-workspace-timeline-${conversationId.value}',
              ),
              conversationId: conversationId,
              builders: widget.builders,
              onThreadRequested: _openThread,
              onCreateThreadRequested: _createNamedThread,
              onReplyRequested: _selectReply,
              onForwardRequested: _showForwardDialog,
              onReactionRequested: widget.availableReactions.isEmpty
                  ? null
                  : _openReactionPicker,
            ),
          ),
        ),
        HandrailTypingIndicator(
          conversationId: conversationId,
          resolveUser: widget.mentions?.resolveUser,
        ),
        FocusTraversalOrder(
          order: const NumericFocusOrder(6),
          child: KeyedSubtree(
            key: ValueKey<String>(
              'handrail-workspace-composer-${conversationId.value}',
            ),
            child: HandrailMessageComposer(
              key: _composerKey,
              conversationId: conversationId,
              delegates: widget.delegates,
              mentions: widget.mentions,
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    required double order,
    required String key,
    required String tooltip,
    required IconData icon,
    required FocusNode focusNode,
    required VoidCallback onPressed,
  }) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: IconButton(
        key: ValueKey<String>('handrail-workspace-$key'),
        tooltip: tooltip,
        focusNode: focusNode,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, {bool showSettings = false}) {
    final panel = _panel!;
    return CallbackShortcuts(
      bindings: {
        if (_discoveryOpen)
          const SingleActivator(LogicalKeyboardKey.escape): _backPanel,
      },
      child: FocusScope(
        autofocus: _discoveryOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 16),
                    child: Text(_discoveryOpen &&
                            panel == _WorkspacePanel.threads
                        ? 'Threads in ${(_discoveryParentState!.conversation as ChannelConversation).name}'
                        : _panelTitle(panel)),
                  ),
                ),
                if (showSettings) _settingsButton(),
                IconButton(
                  key: const ValueKey<String>('handrail-workspace-close-panel'),
                  tooltip: _discoveryOpen
                      ? (panel == _WorkspacePanel.thread
                          ? 'Back to threads'
                          : 'Back to channel')
                      : 'Close panel',
                  onPressed: _backPanel,
                  icon: Icon(_discoveryOpen ? Icons.arrow_back : Icons.close),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
                child: _discoveryOpen
                    ? Stack(fit: StackFit.expand, children: [
                        Offstage(
                          offstage: panel != _WorkspacePanel.threads,
                          child: ExcludeFocus(
                            excluding: panel != _WorkspacePanel.threads,
                            child: _buildPanelBody(
                                context, _WorkspacePanel.threads),
                          ),
                        ),
                        if (panel != _WorkspacePanel.threads)
                          _buildPanelBody(context, panel),
                      ])
                    : _buildPanelBody(context, panel)),
          ],
        ),
      ),
    );
  }

  Widget _buildPanelBody(BuildContext context, _WorkspacePanel panel) {
    final conversationId = _selectedConversationId;
    return switch (panel) {
      _WorkspacePanel.threads => HandrailThreadList(
          client: ChatScope.of(context).client,
          parentConversationId: conversationId!,
          authority: _discoveryAuthority,
          pageSize: widget.pageSize,
          opening: _openingThread,
          onSelected: _openDiscoveredThread,
        ),
      _WorkspacePanel.search => switch (
            _messageSearchFor(ChatScope.of(context))) {
          final search? => HandrailMessageSearch(
              search: search,
              applicationDelegates: widget.delegates,
              filters: widget.searchFilters,
              autofocusSearch: true,
            ),
          null => const Center(
              key: ValueKey<String>('handrail-workspace-search-unavailable'),
              child: Text('Message search is unavailable.'),
            ),
        },
      _WorkspacePanel.members => HandrailMemberPicker(
          client: ChatScope.of(context).client,
          conversationId: conversationId!,
          searchDirectory: widget.members!.searchDirectory,
          authorization: widget.members!.authorization,
          selectedUserIds: widget.members!.selectedUserIds,
          onSelectionChanged: widget.members!.onSelectionChanged,
          defaultAddRole: widget.members!.defaultAddRole,
          roleOptions: widget.members!.roleOptions,
          autofocusSearch: true,
        ),
      _WorkspacePanel.reactions => HandrailReactionPicker(
          actions: _reactionInput!.actions,
          availableReactions: widget.availableReactions,
          reactionAggregates: _reactionInput!.message.reactions,
          autofocus: true,
        ),
      _WorkspacePanel.huddle => SingleChildScrollView(
          key: const ValueKey<String>('handrail-workspace-huddle-scroll'),
          child: HandrailHuddlePanel(
            controller: widget.huddleController!(
              ChatScope.of(context).client,
              conversationId!,
            ),
            mediaDelegate: widget.huddleMediaDelegate,
          ),
        ),
      _WorkspacePanel.thread => HandrailThreadView(
          rootMessageId: _threadRootMessageId,
          openHandle: _threadHandle,
          onClose: _backPanel,
          builders: widget.builders,
          delegates: widget.delegates,
        ),
    };
  }

  String _panelTitle(_WorkspacePanel panel) => switch (panel) {
        _WorkspacePanel.search => 'Search',
        _WorkspacePanel.members => 'Members',
        _WorkspacePanel.reactions => 'Reactions',
        _WorkspacePanel.huddle => 'Huddle',
        _WorkspacePanel.thread => 'Thread',
        _WorkspacePanel.threads => 'Threads',
      };

  @override
  void dispose() {
    _disposed = true;
    _dismissNamedThread();
    _dismissSettings();
    _settingsActionFocusNode.dispose();
    _threadsActionFocusNode.dispose();
    unawaited(_discoveryParentSubscription?.cancel());
    _forwardDialogKey?.currentState?.cancel();
    _forwardDialogKey = null;
    _bindingGeneration += 1;
    _threadGeneration += 1;
    final subscription = _listSubscription;
    _listSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (_ownsListController && _listController != null) {
      unawaited(_listController!.dispose());
    }
    _releaseThreadHandle();
    _searchActionFocusNode.dispose();
    _membersActionFocusNode.dispose();
    _huddleActionFocusNode.dispose();
    _listController = null;
    _listClient = null;
    super.dispose();
  }
}

final class _WorkspaceMessageSearchFailure implements Exception {
  const _WorkspaceMessageSearchFailure();

  @override
  String toString() => 'The chat message search could not be completed.';
}

final class _ForwardMessageDialog extends StatefulWidget {
  const _ForwardMessageDialog({
    required this.actions,
    required this.destinations,
    super.key,
  });

  final ChatMessageActions actions;
  final List<ChatConversationListItem> destinations;

  @override
  State<_ForwardMessageDialog> createState() => _ForwardMessageDialogState();
}

final class _ForwardMessageDialogState extends State<_ForwardMessageDialog> {
  final FocusNode _submitFocusNode = FocusNode();
  ConversationId? _selectedConversationId;
  ChatCommandCancellationController? _activeCancellation;
  bool _submitting = false;
  String? _error;
  int _generation = 0;

  void cancel() {
    _generation += 1;
    _activeCancellation?.cancel();
    _activeCancellation = null;
  }

  void cancelAndClose() {
    cancel();
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).removeRoute(route);
  }

  Future<void> _submit() async {
    final destinationConversationId = _selectedConversationId;
    if (_submitting || destinationConversationId == null) return;
    final generation = ++_generation;
    final cancellation = ChatCommandCancellationController();
    _activeCancellation = cancellation;
    setState(() {
      _submitting = true;
      _error = null;
    });
    ChatCommandResult<ForwardMessageResult>? result;
    try {
      result = await widget.actions.forward(
        destinationConversationId,
        cancellationSignal: cancellation.signal,
      );
    } catch (_) {
      result = null;
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
      cancellation.cancel();
    }
    if (!mounted || generation != _generation) return;
    if (result case ChatCommandSuccess<ForwardMessageResult>(:final value)) {
      Navigator.of(context).pop(value);
      return;
    }
    setState(() {
      _submitting = false;
      _error = "Message couldn't be forwarded. Try again.";
    });
    _submitFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey<String>('handrail-forward-dialog'),
        title: const Text('Forward message'),
        content: SizedBox(
          width: 440,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Choose a destination conversation.'),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey<String>(
                    'handrail-forward-destinations',
                  ),
                  itemCount: widget.destinations.length,
                  itemBuilder: (context, index) {
                    final item = widget.destinations[index];
                    final selected =
                        item.conversationId == _selectedConversationId;
                    return Semantics(
                      selected: selected,
                      enabled: !_submitting,
                      child: ListTile(
                        key: ValueKey<String>(
                          'handrail-forward-destination-'
                          '${item.conversationId.value}',
                        ),
                        enabled: !_submitting,
                        selected: selected,
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: Text(item.displayName),
                        onTap: _submitting
                            ? null
                            : () => setState(() {
                                  _selectedConversationId = item.conversationId;
                                  _error = null;
                                }),
                      ),
                    );
                  },
                ),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  container: true,
                  liveRegion: true,
                  label: error,
                  child: ExcludeSemantics(
                    child: Text(
                      error,
                      key: const ValueKey<String>('handrail-forward-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('handrail-forward-cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          Semantics(
            container: _submitting,
            liveRegion: _submitting,
            label: _submitting ? 'Forwarding message' : null,
            child: FilledButton(
              key: const ValueKey<String>('handrail-forward-submit'),
              focusNode: _submitFocusNode,
              onPressed: _submitting || _selectedConversationId == null
                  ? null
                  : _submit,
              child: _submitting
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          key: ValueKey<String>('handrail-forward-progress'),
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Forwarding…'),
                      ],
                    )
                  : const Text('Forward'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    cancel();
    _submitFocusNode.dispose();
    super.dispose();
  }
}

final class _CreateDirectDialog extends StatefulWidget {
  const _CreateDirectDialog({
    required this.client,
    required this.searchDirectory,
  });

  final HandrailChatClient client;
  final HandrailMemberDirectorySearchDelegate searchDirectory;

  @override
  State<_CreateDirectDialog> createState() => _CreateDirectDialogState();
}

final class _CreateDirectDialogState extends State<_CreateDirectDialog> {
  final _searchController = TextEditingController();
  final Set<String> _requestedPageTokens = <String>{};
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  List<HandrailMemberDirectoryRow> _rows = const [];
  Set<UserId> _rowIds = <UserId>{};
  UserId? _selectedUserId;
  String? _nextPageToken;
  String? _failedPageToken;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _directoryError = false;
  bool _submitting = false;
  String? _commandError;

  @override
  void initState() {
    super.initState();
    final generation = ++_searchGeneration;
    unawaited(_requestPage(generation: generation, pageToken: null));
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    _requestedPageTokens.clear();
    setState(() {
      _rows = const [];
      _rowIds = <UserId>{};
      _selectedUserId = null;
      _nextPageToken = null;
      _failedPageToken = null;
      _directoryError = false;
      _initialLoading = true;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _searchDebounce = null;
      if (mounted && generation == _searchGeneration) {
        unawaited(_requestPage(generation: generation, pageToken: null));
      }
    });
  }

  Future<void> _requestPage({
    required int generation,
    required String? pageToken,
  }) async {
    if (!mounted || generation != _searchGeneration) return;
    if (pageToken != null && !_requestedPageTokens.add(pageToken)) return;
    setState(() {
      _directoryError = false;
      _failedPageToken = null;
      if (pageToken == null) {
        _initialLoading = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.searchDirectory(
        HandrailMemberDirectorySearchRequest(
          query: _searchController.text.trim(),
          pageSize: 50,
          pageToken: pageToken,
        ),
      );
      if (!mounted || generation != _searchGeneration) return;
      final rows = <HandrailMemberDirectoryRow>[
        if (pageToken != null) ..._rows,
      ];
      final rowIds = <UserId>{if (pageToken != null) ..._rowIds};
      for (final row in page.rows) {
        if (rowIds.add(row.userId)) rows.add(row);
      }
      final candidateToken = page.nextPageToken;
      final safeNextToken = candidateToken == pageToken ||
              (candidateToken != null &&
                  _requestedPageTokens.contains(candidateToken))
          ? null
          : candidateToken;
      setState(() {
        _rows = List<HandrailMemberDirectoryRow>.unmodifiable(rows);
        _rowIds = rowIds;
        _nextPageToken = safeNextToken;
        _initialLoading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      if (pageToken != null) _requestedPageTokens.remove(pageToken);
      setState(() {
        _initialLoading = false;
        _loadingMore = false;
        _directoryError = true;
        _failedPageToken = pageToken;
      });
    }
  }

  void _retryDirectory() {
    if (_initialLoading || _loadingMore || !_directoryError) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: _failedPageToken,
      ),
    );
  }

  void _loadMore() {
    final pageToken = _nextPageToken;
    if (pageToken == null || _loadingMore) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: pageToken,
      ),
    );
  }

  Future<void> _submit() async {
    final selectedUserId = _selectedUserId;
    if (_submitting || selectedUserId == null) return;
    setState(() {
      _submitting = true;
      _commandError = null;
    });
    final result = await widget.client.createDirect(
      ChatCreateDirectInput(intendedMemberUserIds: [selectedUserId]),
    );
    if (!mounted) return;
    switch (result) {
      case ChatCommandSuccess<DirectConversationCreationResult>(:final value):
        Navigator.of(context).pop(
          value.conversation.conversation.summary.conversation.id,
        );
      case ChatCommandFailure<DirectConversationCreationResult>():
        setState(() {
          _submitting = false;
          _commandError = 'The direct message could not be started. Try again.';
        });
      default:
        setState(() {
          _submitting = false;
          _commandError = 'The direct message could not be started. Try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey<String>('handrail-create-direct-dialog'),
        title: const Text('Start direct message'),
        content: SizedBox(
          width: 440,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey<String>('handrail-create-direct-search'),
                controller: _searchController,
                autofocus: true,
                enabled: !_submitting,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  labelText: 'Search people',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _buildDirectoryBody()),
              if (_commandError case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    key: const ValueKey<String>(
                      'handrail-create-direct-error',
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('handrail-create-direct-cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('handrail-create-direct-submit'),
            onPressed: _submitting || _selectedUserId == null ? null : _submit,
            child: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start'),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryBody() {
    if (_initialLoading && _rows.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey<String>('handrail-create-direct-loading'),
        ),
      );
    }
    if (_directoryError && _rows.isEmpty) {
      return Center(
        child: TextButton(
          key: const ValueKey<String>('handrail-create-direct-retry'),
          onPressed: _retryDirectory,
          child: const Text('Retry directory search'),
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Center(child: Text('No people found'));
    }
    final showFooter =
        _nextPageToken != null || _loadingMore || _directoryError;
    return ListView.builder(
      key: const ValueKey<String>('handrail-create-direct-results'),
      itemCount: _rows.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _rows.length) {
          if (_loadingMore) {
            return const Center(child: CircularProgressIndicator());
          }
          return TextButton(
            onPressed: _directoryError ? _retryDirectory : _loadMore,
            child: Text(_directoryError ? 'Retry' : 'Load more'),
          );
        }
        final row = _rows[index];
        final selected = row.userId == _selectedUserId;
        return Semantics(
          selected: selected,
          enabled: !row.disabled && !_submitting,
          child: ListTile(
            key: ValueKey<String>(
              'handrail-create-direct-user-${row.userId.value}',
            ),
            enabled: !row.disabled && !_submitting,
            selected: selected,
            leading: Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
            ),
            title: Text(row.displayName),
            subtitle: _rowSubtitle(row),
            onTap: row.disabled || _submitting
                ? null
                : () => setState(() => _selectedUserId = row.userId),
          ),
        );
      },
    );
  }

  Widget? _rowSubtitle(HandrailMemberDirectoryRow row) {
    final lines = <String>[
      if (row.subtitle case final subtitle?) subtitle,
      if (row.disabled)
        if (row.disabledReason case final reason?) reason,
    ];
    return lines.isEmpty ? null : Text(lines.join('\n'));
  }

  @override
  void dispose() {
    _searchGeneration += 1;
    _searchDebounce?.cancel();
    _rows = const [];
    _rowIds = <UserId>{};
    _searchController.dispose();
    super.dispose();
  }
}

final class _CreateGroupDirectDialog extends StatefulWidget {
  const _CreateGroupDirectDialog({
    required this.client,
    required this.searchDirectory,
  });

  final HandrailChatClient client;
  final HandrailMemberDirectorySearchDelegate searchDirectory;

  @override
  State<_CreateGroupDirectDialog> createState() =>
      _CreateGroupDirectDialogState();
}

final class _CreateGroupDirectDialogState
    extends State<_CreateGroupDirectDialog> {
  final _searchController = TextEditingController();
  final Set<String> _requestedPageTokens = <String>{};
  final Map<UserId, HandrailMemberDirectoryRow> _selectedRows =
      <UserId, HandrailMemberDirectoryRow>{};
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  List<HandrailMemberDirectoryRow> _rows = const [];
  Set<UserId> _rowIds = <UserId>{};
  String? _nextPageToken;
  String? _failedPageToken;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _directoryError = false;
  bool _submitting = false;
  String? _commandError;

  @override
  void initState() {
    super.initState();
    final generation = ++_searchGeneration;
    unawaited(_requestPage(generation: generation, pageToken: null));
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    _requestedPageTokens.clear();
    setState(() {
      _rows = const [];
      _rowIds = <UserId>{};
      _nextPageToken = null;
      _failedPageToken = null;
      _directoryError = false;
      _initialLoading = true;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _searchDebounce = null;
      if (mounted && generation == _searchGeneration) {
        unawaited(_requestPage(generation: generation, pageToken: null));
      }
    });
  }

  Future<void> _requestPage({
    required int generation,
    required String? pageToken,
  }) async {
    if (!mounted || generation != _searchGeneration) return;
    if (pageToken != null && !_requestedPageTokens.add(pageToken)) return;
    setState(() {
      _directoryError = false;
      _failedPageToken = null;
      if (pageToken == null) {
        _initialLoading = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.searchDirectory(
        HandrailMemberDirectorySearchRequest(
          query: _searchController.text.trim(),
          pageSize: 50,
          pageToken: pageToken,
        ),
      );
      if (!mounted || generation != _searchGeneration) return;
      final rows = <HandrailMemberDirectoryRow>[
        if (pageToken != null) ..._rows,
      ];
      final rowIds = <UserId>{if (pageToken != null) ..._rowIds};
      for (final row in page.rows) {
        if (rowIds.add(row.userId)) rows.add(row);
      }
      final candidateToken = page.nextPageToken;
      final safeNextToken = candidateToken == pageToken ||
              (candidateToken != null &&
                  _requestedPageTokens.contains(candidateToken))
          ? null
          : candidateToken;
      setState(() {
        _rows = List<HandrailMemberDirectoryRow>.unmodifiable(rows);
        _rowIds = rowIds;
        _nextPageToken = safeNextToken;
        _initialLoading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      if (pageToken != null) _requestedPageTokens.remove(pageToken);
      setState(() {
        _initialLoading = false;
        _loadingMore = false;
        _directoryError = true;
        _failedPageToken = pageToken;
      });
    }
  }

  void _retryDirectory() {
    if (_initialLoading || _loadingMore || !_directoryError) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: _failedPageToken,
      ),
    );
  }

  void _loadMore() {
    final pageToken = _nextPageToken;
    if (pageToken == null || _loadingMore) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: pageToken,
      ),
    );
  }

  void _toggleSelection(HandrailMemberDirectoryRow row) {
    if (_submitting || row.disabled) return;
    setState(() {
      _commandError = null;
      if (_selectedRows.containsKey(row.userId)) {
        _selectedRows.remove(row.userId);
      } else {
        _selectedRows[row.userId] = row;
      }
    });
  }

  void _removeSelection(UserId userId) {
    if (_submitting) return;
    setState(() {
      _commandError = null;
      _selectedRows.remove(userId);
    });
  }

  Future<void> _submit() async {
    if (_submitting || _selectedRows.length < 2) return;
    final participantIds = List<UserId>.unmodifiable(_selectedRows.keys);
    setState(() {
      _submitting = true;
      _commandError = null;
    });
    final result = await widget.client.createGroupDirect(
      ChatCreateGroupDirectInput(intendedMemberUserIds: participantIds),
    );
    if (!mounted) return;
    switch (result) {
      case ChatCommandSuccess<GroupDirectConversationCreationResult>(
          :final value,
        ):
        Navigator.of(context).pop(
          value.conversation.conversation.summary.conversation.id,
        );
      case ChatCommandFailure<GroupDirectConversationCreationResult>():
        setState(() {
          _submitting = false;
          _commandError = 'The group message could not be started. Try again.';
        });
      default:
        setState(() {
          _submitting = false;
          _commandError = 'The group message could not be started. Try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey<String>('handrail-create-group-direct-dialog'),
        title: const Text('Start group message'),
        content: SizedBox(
          width: 440,
          height: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey<String>(
                  'handrail-create-group-direct-search',
                ),
                controller: _searchController,
                autofocus: true,
                enabled: !_submitting,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  labelText: 'Search people',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              _buildSelectedUsers(),
              Expanded(child: _buildDirectoryBody()),
              if (_commandError case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    key: const ValueKey<String>(
                      'handrail-create-group-direct-error',
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>(
              'handrail-create-group-direct-cancel',
            ),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>(
              'handrail-create-group-direct-submit',
            ),
            onPressed: _submitting || _selectedRows.length < 2 ? null : _submit,
            child: _submitting
                ? const SizedBox.square(
                    key: ValueKey<String>(
                      'handrail-create-group-direct-progress',
                    ),
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedUsers() {
    if (_selectedRows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text('Select at least two people.'),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 88),
      child: SingleChildScrollView(
        key: const ValueKey<String>(
          'handrail-create-group-direct-selected',
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final row in _selectedRows.values)
              InputChip(
                key: ValueKey<String>(
                  'handrail-create-group-direct-selected-${row.userId.value}',
                ),
                label: Text(row.displayName),
                onDeleted: () => _removeSelection(row.userId),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectoryBody() {
    if (_initialLoading && _rows.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey<String>('handrail-create-group-direct-loading'),
        ),
      );
    }
    if (_directoryError && _rows.isEmpty) {
      return Center(
        child: TextButton(
          key: const ValueKey<String>('handrail-create-group-direct-retry'),
          onPressed: _retryDirectory,
          child: const Text('Retry directory search'),
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Center(child: Text('No people found'));
    }
    final showFooter =
        _nextPageToken != null || _loadingMore || _directoryError;
    return ListView.builder(
      key: const ValueKey<String>('handrail-create-group-direct-results'),
      itemCount: _rows.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _rows.length) {
          if (_loadingMore) {
            return const Center(child: CircularProgressIndicator());
          }
          return TextButton(
            key: const ValueKey<String>(
              'handrail-create-group-direct-directory-action',
            ),
            onPressed: _directoryError ? _retryDirectory : _loadMore,
            child: Text(_directoryError ? 'Retry' : 'Load more'),
          );
        }
        final row = _rows[index];
        final selected = _selectedRows.containsKey(row.userId);
        return Semantics(
          selected: selected,
          enabled: !row.disabled && !_submitting,
          child: ListTile(
            key: ValueKey<String>(
              'handrail-create-group-direct-user-${row.userId.value}',
            ),
            enabled: !row.disabled && !_submitting,
            selected: selected,
            leading: Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            title: Text(row.displayName),
            subtitle: _rowSubtitle(row),
            onTap: row.disabled || _submitting
                ? null
                : () => _toggleSelection(row),
          ),
        );
      },
    );
  }

  Widget? _rowSubtitle(HandrailMemberDirectoryRow row) {
    final lines = <String>[
      if (row.subtitle case final subtitle?) subtitle,
      if (row.disabled)
        if (row.disabledReason case final reason?) reason,
    ];
    return lines.isEmpty ? null : Text(lines.join('\n'));
  }

  @override
  void dispose() {
    _searchGeneration += 1;
    _searchDebounce?.cancel();
    _rows = const [];
    _rowIds = <UserId>{};
    _selectedRows.clear();
    _searchController.dispose();
    super.dispose();
  }
}

final class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog({required this.client, this.entity});

  final HandrailChatClient client;
  final HostEntityReference? entity;

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

final class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  ConversationVisibility _visibility = ConversationVisibility.public;
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await widget.client.createChannel(
      ChatCreateChannelInput(
        name: _nameController.text.trim(),
        visibility: _visibility,
        entity: widget.entity,
      ),
    );
    if (!mounted) return;
    switch (result) {
      case ChatCommandSuccess<ChannelConversationCreationResult>(
          :final value,
        ):
        Navigator.of(context).pop(
          value.conversation.conversation.summary.conversation.id,
        );
      case ChatCommandFailure<ChannelConversationCreationResult>(
          :final message,
        ):
        setState(() {
          _submitting = false;
          _error = '$message Try again.';
        });
      default:
        setState(() {
          _submitting = false;
          _error = 'The channel could not be created. Try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey<String>('handrail-create-channel-dialog'),
        title: const Text('Create channel'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey<String>('handrail-create-channel-name'),
                controller: _nameController,
                autofocus: true,
                enabled: !_submitting,
                decoration: const InputDecoration(labelText: 'Channel name'),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => unawaited(_submit()),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a channel name.'
                    : null,
              ),
              const SizedBox(height: 16),
              const Text('Visibility'),
              const SizedBox(height: 8),
              SegmentedButton<ConversationVisibility>(
                key: const ValueKey<String>(
                  'handrail-create-channel-visibility',
                ),
                segments: const [
                  ButtonSegment(
                    value: ConversationVisibility.public,
                    label: Text('Public'),
                    icon: Icon(Icons.public),
                  ),
                  ButtonSegment(
                    value: ConversationVisibility.private,
                    label: Text('Private'),
                    icon: Icon(Icons.lock_outline),
                  ),
                ],
                selected: {_visibility},
                onSelectionChanged: _submitting
                    ? null
                    : (selection) =>
                        setState(() => _visibility = selection.single),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    key: const ValueKey<String>(
                      'handrail-create-channel-error',
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('handrail-create-channel-cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('handrail-create-channel-submit'),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          key: ValueKey<String>(
                            'handrail-create-channel-progress',
                          ),
                          strokeWidth: 2,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text('Creating…'),
                    ],
                  )
                : const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}

final class _WorkspaceAccessState extends StatelessWidget {
  const _WorkspaceAccessState({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => unawaited(onRetry()),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameScope(
  ConversationSnapshotScope left,
  ConversationSnapshotScope right,
) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());
