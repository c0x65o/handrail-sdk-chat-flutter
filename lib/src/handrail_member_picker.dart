import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/command_dispatcher.dart';
import 'generated/conversation_membership.dart';
import 'generated/conversation_snapshot.dart';
import 'generated/identifiers.dart';
import 'handrail_chat_client.dart';

/// One transient host-directory result rendered by [HandrailMemberPicker].
///
/// The chat SDK never writes these rows to normalized state or persistence.
/// Hosts should include only the presentation fields needed by the picker.
@immutable
final class HandrailMemberDirectoryRow {
  const HandrailMemberDirectoryRow({
    required this.userId,
    required this.displayName,
    this.subtitle,
    this.disabled = false,
    this.disabledReason,
  }) : assert(displayName != '');

  final UserId userId;
  final String displayName;
  final String? subtitle;

  /// Whether the host directory considers this identity ineligible.
  final bool disabled;

  /// Host-authored explanation announced by accessibility services.
  final String? disabledReason;
}

/// An immutable page returned by [HandrailMemberDirectorySearchDelegate].
@immutable
final class HandrailMemberDirectoryPage {
  HandrailMemberDirectoryPage({
    required Iterable<HandrailMemberDirectoryRow> rows,
    this.nextPageToken,
  }) : rows = List<HandrailMemberDirectoryRow>.unmodifiable(rows) {
    if (nextPageToken != null && nextPageToken!.isEmpty) {
      throw ArgumentError.value(
        nextPageToken,
        'nextPageToken',
        'must be null or non-empty',
      );
    }
  }

  final List<HandrailMemberDirectoryRow> rows;

  /// An opaque host-owned token returned unchanged on the next request.
  final String? nextPageToken;
}

/// One deterministic host-directory page request.
@immutable
final class HandrailMemberDirectorySearchRequest {
  const HandrailMemberDirectorySearchRequest({
    required this.query,
    required this.pageSize,
    this.pageToken,
  });

  final String query;
  final int pageSize;
  final String? pageToken;
}

/// Searches an ERP-owned directory without transferring directory ownership
/// to Handrail Chat.
typedef HandrailMemberDirectorySearchDelegate
    = Future<HandrailMemberDirectoryPage> Function(
  HandrailMemberDirectorySearchRequest request,
);

/// Explicit host authorization for membership mutations shown by the picker.
@immutable
final class HandrailMemberPickerAuthorization {
  const HandrailMemberPickerAuthorization({
    this.canAddMembers = false,
    this.canRemoveMembers = false,
    this.canChangeMemberRoles = false,
  });

  final bool canAddMembers;
  final bool canRemoveMembers;
  final bool canChangeMemberRoles;
}

/// A state-management-neutral, transient ERP-directory member picker.
///
/// Membership is always read from [HandrailChatClient.normalizedState], and
/// authorized mutations use the client's public membership commands with the
/// latest canonical member-list revision.
class HandrailMemberPicker extends StatefulWidget {
  const HandrailMemberPicker({
    required this.client,
    required this.conversationId,
    required this.searchDirectory,
    required this.authorization,
    this.searchDebounce = const Duration(milliseconds: 300),
    this.pageSize = 50,
    this.initialQuery = '',
    this.selectedUserIds = const <UserId>{},
    this.onSelectionChanged,
    this.defaultAddRole = ConversationMembershipMemberRole.member,
    this.roleOptions = const <ConversationMembershipMemberRole>[
      ConversationMembershipMemberRole.member,
    ],
    this.autofocusSearch = false,
    super.key,
  }) : assert(pageSize > 0);

  final HandrailChatClient client;
  final ConversationId conversationId;
  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final HandrailMemberPickerAuthorization authorization;
  final Duration searchDebounce;
  final int pageSize;
  final String initialQuery;
  final Set<UserId> selectedUserIds;
  final ValueChanged<Set<UserId>>? onSelectionChanged;

  /// Role requested by the add command. The host must choose this explicitly
  /// when its policy permits a role other than `member`.
  final ConversationMembershipMemberRole defaultAddRole;

  /// Roles the host permits users to choose for existing members.
  final List<ConversationMembershipMemberRole> roleOptions;
  final bool autofocusSearch;

  @override
  HandrailMemberPickerState createState() => HandrailMemberPickerState();
}

/// Public only to support lifecycle verification with a [GlobalKey].
class HandrailMemberPickerState extends State<HandrailMemberPicker> {
  late final TextEditingController _searchController;
  late Set<UserId> _selectedUserIds;
  StreamSubscription<Object?>? _membershipSubscription;
  Timer? _debounceTimer;
  int _searchGeneration = 0;
  String _activeQuery = '';
  List<HandrailMemberDirectoryRow> _rows = const [];
  Set<UserId> _rowIds = <UserId>{};
  final Set<String> _requestedPageTokens = <String>{};
  bool _initialPageRequested = false;
  String? _nextPageToken;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _directoryError = false;
  String? _failedPageToken;
  final Map<UserId, FocusNode> _rowFocusNodes = <UserId, FocusNode>{};
  final Set<UserId> _memberCommands = <UserId>{};
  final Set<UserId> _memberCommandErrors = <UserId>{};
  bool _disposed = false;

  /// Number of host-directory rows still referenced by this state object.
  ///
  /// This diagnostic is intended for lifecycle tests. It is always zero after
  /// [dispose], even when a host search future completes later.
  @visibleForTesting
  int get debugRetainedDirectoryRowCount => _rows.length;

  @override
  void initState() {
    super.initState();
    _activeQuery = widget.initialQuery.trim();
    _searchController = TextEditingController(text: widget.initialQuery);
    _selectedUserIds = Set<UserId>.of(widget.selectedUserIds);
    _subscribeToMembership();
    final generation = ++_searchGeneration;
    unawaited(_requestPage(generation: generation, pageToken: null));
  }

  @override
  void didUpdateWidget(covariant HandrailMemberPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.conversationId != widget.conversationId) {
      unawaited(_membershipSubscription?.cancel());
      _cancelMemberCommands();
      _memberCommandErrors.clear();
      _subscribeToMembership();
    }
    if (!setEquals(oldWidget.selectedUserIds, widget.selectedUserIds)) {
      _selectedUserIds = Set<UserId>.of(widget.selectedUserIds);
    }
    if (oldWidget.searchDirectory != widget.searchDirectory ||
        oldWidget.pageSize != widget.pageSize) {
      _scheduleNewSearch(_searchController.text, immediate: true);
    }
  }

  void _subscribeToMembership() {
    _membershipSubscription = widget.client.normalizedState
        .watchConversation(widget.conversationId)
        .listen((_) {
      if (mounted && !_disposed) setState(() {});
    });
  }

  void _onSearchChanged(String value) {
    _scheduleNewSearch(value, immediate: false);
  }

  void _scheduleNewSearch(String value, {required bool immediate}) {
    _debounceTimer?.cancel();
    final generation = ++_searchGeneration;
    _activeQuery = value.trim();
    _releaseDirectoryData();
    if (mounted) {
      setState(() {
        _initialLoading = true;
      });
    }
    if (immediate || widget.searchDebounce == Duration.zero) {
      unawaited(_requestPage(generation: generation, pageToken: null));
      return;
    }
    _debounceTimer = Timer(widget.searchDebounce, () {
      _debounceTimer = null;
      if (!_disposed && generation == _searchGeneration) {
        unawaited(_requestPage(generation: generation, pageToken: null));
      }
    });
  }

  Future<void> _requestPage({
    required int generation,
    required String? pageToken,
  }) async {
    if (_disposed || generation != _searchGeneration) return;
    if (pageToken == null) {
      if (_initialPageRequested) return;
      _initialPageRequested = true;
    } else if (!_requestedPageTokens.add(pageToken)) {
      return;
    }

    if (mounted) {
      setState(() {
        _directoryError = false;
        _failedPageToken = null;
        if (pageToken == null) {
          _initialLoading = true;
        } else {
          _loadingMore = true;
        }
      });
    }

    try {
      final page = await widget.searchDirectory(
        HandrailMemberDirectorySearchRequest(
          query: _activeQuery,
          pageSize: widget.pageSize,
          pageToken: pageToken,
        ),
      );
      if (_disposed || !mounted || generation != _searchGeneration) return;

      final mergedRows = <HandrailMemberDirectoryRow>[
        if (pageToken != null) ..._rows,
      ];
      final mergedIds = <UserId>{
        if (pageToken != null) ..._rowIds,
      };
      for (final row in page.rows) {
        if (mergedIds.add(row.userId)) mergedRows.add(row);
      }
      final candidateNextToken = page.nextPageToken;
      final safeNextToken = candidateNextToken == pageToken ||
              (candidateNextToken != null &&
                  _requestedPageTokens.contains(candidateNextToken))
          ? null
          : candidateNextToken;

      setState(() {
        _rows = List<HandrailMemberDirectoryRow>.unmodifiable(mergedRows);
        _rowIds = mergedIds;
        _nextPageToken = safeNextToken;
        _initialLoading = false;
        _loadingMore = false;
        _directoryError = false;
      });
      _disposeUnusedFocusNodes();
    } catch (_) {
      if (_disposed || !mounted || generation != _searchGeneration) return;
      if (pageToken == null) {
        _initialPageRequested = false;
      } else {
        _requestedPageTokens.remove(pageToken);
      }
      setState(() {
        _initialLoading = false;
        _loadingMore = false;
        _directoryError = true;
        _failedPageToken = pageToken;
      });
    }
  }

  void _retryDirectoryRequest() {
    if (_initialLoading || _loadingMore || !_directoryError) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: _failedPageToken,
      ),
    );
  }

  void _loadMore() {
    final token = _nextPageToken;
    if (token == null || _loadingMore || _directoryError) return;
    unawaited(
      _requestPage(generation: _searchGeneration, pageToken: token),
    );
  }

  void _toggleSelection(HandrailMemberDirectoryRow row) {
    if (row.disabled) return;
    final next = Set<UserId>.of(_selectedUserIds);
    if (!next.add(row.userId)) next.remove(row.userId);
    setState(() => _selectedUserIds = next);
    widget.onSelectionChanged?.call(Set<UserId>.unmodifiable(next));
  }

  KeyEventResult _handleRowKey(
    KeyEvent event,
    int index,
    HandrailMemberDirectoryRow row,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusRow(index + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focusRow(index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _toggleSelection(row);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusRow(int index) {
    if (_rows.isEmpty) return;
    final bounded = index.clamp(0, _rows.length - 1);
    _focusNodeFor(_rows[bounded].userId).requestFocus();
  }

  FocusNode _focusNodeFor(UserId userId) =>
      _rowFocusNodes.putIfAbsent(userId, FocusNode.new);

  void _disposeUnusedFocusNodes() {
    final staleIds = _rowFocusNodes.keys
        .where((userId) => !_rowIds.contains(userId))
        .toList(growable: false);
    for (final userId in staleIds) {
      _rowFocusNodes.remove(userId)?.dispose();
    }
  }

  ConversationSnapshotMember? _activeMember(UserId userId) {
    final member = widget.client.normalizedState.state
        .membersByConversation[widget.conversationId]?[userId];
    return member?.state == ConversationMembershipMemberState.active.wireValue
        ? member
        : null;
  }

  int? get _memberListRevision => widget
      .client.normalizedState.state.memberListRevisions[widget.conversationId];

  bool _canAdd(HandrailMemberDirectoryRow row) =>
      !row.disabled &&
      widget.authorization.canAddMembers &&
      _memberListRevision != null &&
      _activeMember(row.userId) == null &&
      !_memberCommands.contains(row.userId);

  bool _canRemove(HandrailMemberDirectoryRow row) =>
      !row.disabled &&
      widget.authorization.canRemoveMembers &&
      _memberListRevision != null &&
      _activeMember(row.userId) != null &&
      !_memberCommands.contains(row.userId);

  bool _canChangeRole(HandrailMemberDirectoryRow row) =>
      !row.disabled &&
      widget.authorization.canChangeMemberRoles &&
      widget.roleOptions.isNotEmpty &&
      _memberListRevision != null &&
      _activeMember(row.userId) != null &&
      !_memberCommands.contains(row.userId);

  Future<void> _addMember(HandrailMemberDirectoryRow row) async {
    if (!_canAdd(row)) return;
    await _runMemberCommand(
      row.userId,
      () {
        final state = widget.client.normalizedState.state;
        final revision = state.memberListRevisions[widget.conversationId];
        final canonical =
            state.membersByConversation[widget.conversationId]?[row.userId];
        if (revision == null ||
            canonical?.state ==
                ConversationMembershipMemberState.active.wireValue ||
            !widget.authorization.canAddMembers ||
            row.disabled) {
          return null;
        }
        return widget.client.addConversationMember(
          ChatAddConversationMemberInput(
            conversationId: widget.conversationId,
            targetUserId: row.userId,
            requestedRole: widget.defaultAddRole,
            expectedMemberListRevision: revision,
          ),
        );
      },
    );
  }

  Future<void> _removeMember(HandrailMemberDirectoryRow row) async {
    if (!_canRemove(row)) return;
    await _runMemberCommand(
      row.userId,
      () {
        final state = widget.client.normalizedState.state;
        final revision = state.memberListRevisions[widget.conversationId];
        final canonical =
            state.membersByConversation[widget.conversationId]?[row.userId];
        if (revision == null ||
            canonical?.state !=
                ConversationMembershipMemberState.active.wireValue ||
            !widget.authorization.canRemoveMembers ||
            row.disabled) {
          return null;
        }
        return widget.client.removeConversationMember(
          ChatRemoveConversationMemberInput(
            conversationId: widget.conversationId,
            targetUserId: row.userId,
            expectedMemberListRevision: revision,
          ),
        );
      },
    );
  }

  Future<void> _changeMemberRole(
    HandrailMemberDirectoryRow row,
    ConversationMembershipMemberRole requestedRole,
  ) async {
    if (!_canChangeRole(row) || !widget.roleOptions.contains(requestedRole)) {
      return;
    }
    await _runMemberCommand(
      row.userId,
      () {
        final state = widget.client.normalizedState.state;
        final revision = state.memberListRevisions[widget.conversationId];
        final canonical =
            state.membersByConversation[widget.conversationId]?[row.userId];
        if (revision == null ||
            canonical?.state !=
                ConversationMembershipMemberState.active.wireValue ||
            !widget.authorization.canChangeMemberRoles ||
            !widget.roleOptions.contains(requestedRole) ||
            row.disabled) {
          return null;
        }
        return widget.client.changeConversationMemberRole(
          ChatChangeConversationMemberRoleInput(
            conversationId: widget.conversationId,
            targetUserId: row.userId,
            requestedRole: requestedRole,
            expectedMemberListRevision: revision,
          ),
        );
      },
    );
  }

  Future<void> _runMemberCommand(
    UserId userId,
    Future<ChatCommandResult<ConversationMembershipMutationResult>>? Function()
        command,
  ) async {
    if (_memberCommands.contains(userId)) return;
    final operation = command();
    if (operation == null) {
      return;
    }
    setState(() {
      _memberCommands.add(userId);
      _memberCommandErrors.remove(userId);
    });
    try {
      final result = await operation;
      if (!_disposed &&
          mounted &&
          result.category != ChatCommandResultCategory.success) {
        setState(() => _memberCommandErrors.add(userId));
      }
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() => _memberCommandErrors.add(userId));
      }
    } finally {
      if (!_disposed && mounted) {
        setState(() => _memberCommands.remove(userId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            textField: true,
            label: 'Search member directory',
            child: TextField(
              key: const ValueKey('handrail-member-picker-search'),
              controller: _searchController,
              autofocus: widget.autofocusSearch,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Search people',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildDirectoryBody(context)),
        ],
      ),
    );
  }

  Widget _buildDirectoryBody(BuildContext context) {
    if (_initialLoading && _rows.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'Loading member directory',
          child: const CircularProgressIndicator(
            key: ValueKey('handrail-member-picker-initial-loading'),
          ),
        ),
      );
    }
    if (_directoryError && _rows.isEmpty) {
      return _DirectoryErrorState(onRetry: _retryDirectoryRequest);
    }
    if (_rows.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'No people found',
          child: const Text(
            'No people found',
            key: ValueKey('handrail-member-picker-empty'),
          ),
        ),
      );
    }

    final footerCount =
        _nextPageToken != null || _loadingMore || _directoryError ? 1 : 0;
    return ListView.builder(
      key: const ValueKey('handrail-member-picker-results'),
      itemCount: _rows.length + footerCount,
      itemBuilder: (context, index) {
        if (index == _rows.length) return _buildFooter();
        return _buildRow(context, _rows[index], index);
      },
    );
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading more people',
            child: const CircularProgressIndicator(
              key: ValueKey('handrail-member-picker-loading-more'),
            ),
          ),
        ),
      );
    }
    if (_directoryError) {
      return _DirectoryErrorState(
        loadingMore: true,
        onRetry: _retryDirectoryRequest,
      );
    }
    return Center(
      child: TextButton(
        key: const ValueKey('handrail-member-picker-load-more'),
        onPressed: _loadMore,
        child: const Text('Load more'),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    HandrailMemberDirectoryRow row,
    int index,
  ) {
    final member = _activeMember(row.userId);
    final selected = _selectedUserIds.contains(row.userId);
    final pending = _memberCommands.contains(row.userId);
    final hasCommandError = _memberCommandErrors.contains(row.userId);
    final colorScheme = Theme.of(context).colorScheme;
    final background = selected
        ? colorScheme.primaryContainer
        : member != null
            ? colorScheme.secondaryContainer
            : colorScheme.surface;
    final role = member == null ? null : _roleFromWire(member.role);
    final rowLabel = <String>[
      row.displayName,
      if (selected) 'selected' else 'not selected',
      if (member != null) 'existing member' else 'not a member',
      if (member != null) 'role ${member.role}',
      if (row.disabled) 'disabled',
      if (row.disabledReason case final reason?) reason,
      if (hasCommandError) 'membership update failed',
    ].join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        container: true,
        selected: selected,
        enabled: !row.disabled,
        label: rowLabel,
        onTap: row.disabled ? null : () => _toggleSelection(row),
        child: Focus(
          focusNode: _focusNodeFor(row.userId),
          onKeyEvent: (_, event) => _handleRowKey(event, index, row),
          child: Material(
            key: ValueKey('handrail-member-row-${row.userId.value}'),
            color: background,
            child: InkWell(
              onTap: row.disabled ? null : () => _toggleSelection(row),
              child: Opacity(
                opacity: row.disabled ? 0.55 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: selected,
                        onChanged:
                            row.disabled ? null : (_) => _toggleSelection(row),
                        semanticLabel: 'Select ${row.displayName}',
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.displayName,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            if (row.subtitle case final subtitle?)
                              Text(
                                subtitle,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            Wrap(
                              spacing: 6,
                              runSpacing: 2,
                              children: [
                                if (selected)
                                  const Chip(label: Text('Selected')),
                                if (member != null)
                                  const Chip(label: Text('Member')),
                                if (row.disabled)
                                  Chip(
                                    label: Text(
                                      row.disabledReason ?? 'Disabled',
                                    ),
                                  ),
                                if (hasCommandError)
                                  const Text('Update failed. Try again.'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (pending)
                        const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (member == null)
                        Semantics(
                          label: 'Add ${row.displayName} as '
                              '${widget.defaultAddRole.wireValue}',
                          button: true,
                          enabled: _canAdd(row),
                          child: IconButton(
                            key: ValueKey(
                              'handrail-member-add-${row.userId.value}',
                            ),
                            tooltip: _canAdd(row)
                                ? 'Add member'
                                : 'Adding members is not allowed',
                            onPressed:
                                _canAdd(row) ? () => _addMember(row) : null,
                            icon: const Icon(Icons.person_add_alt_1),
                          ),
                        )
                      else ...[
                        Semantics(
                          label: 'Role for ${row.displayName}',
                          value: member.role,
                          enabled: _canChangeRole(row),
                          child:
                              DropdownButton<ConversationMembershipMemberRole>(
                            key: ValueKey(
                              'handrail-member-role-${row.userId.value}',
                            ),
                            value: role,
                            items: _roleMenuItems(role),
                            onChanged: _canChangeRole(row)
                                ? (nextRole) {
                                    if (nextRole != null && nextRole != role) {
                                      _changeMemberRole(row, nextRole);
                                    }
                                  }
                                : null,
                          ),
                        ),
                        Semantics(
                          label: 'Remove ${row.displayName}',
                          button: true,
                          enabled: _canRemove(row),
                          child: IconButton(
                            key: ValueKey(
                              'handrail-member-remove-${row.userId.value}',
                            ),
                            tooltip: _canRemove(row)
                                ? 'Remove member'
                                : 'Removing members is not allowed',
                            onPressed: _canRemove(row)
                                ? () => _removeMember(row)
                                : null,
                            icon: const Icon(Icons.person_remove),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<DropdownMenuItem<ConversationMembershipMemberRole>> _roleMenuItems(
    ConversationMembershipMemberRole? currentRole,
  ) {
    final roles = <ConversationMembershipMemberRole>{
      if (currentRole != null) currentRole,
      ...widget.roleOptions,
    };
    return [
      for (final role in roles)
        DropdownMenuItem(
          value: role,
          child: Text(role.wireValue),
        ),
    ];
  }

  ConversationMembershipMemberRole? _roleFromWire(String role) =>
      switch (role) {
        'owner' => ConversationMembershipMemberRole.owner,
        'moderator' => ConversationMembershipMemberRole.moderator,
        'member' => ConversationMembershipMemberRole.member,
        _ => null,
      };

  void _releaseDirectoryData() {
    _rows = const [];
    _rowIds = <UserId>{};
    _requestedPageTokens.clear();
    _initialPageRequested = false;
    _nextPageToken = null;
    _loadingMore = false;
    _directoryError = false;
    _failedPageToken = null;
    _disposeUnusedFocusNodes();
  }

  void _cancelMemberCommands() {
    _memberCommands.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchGeneration += 1;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_membershipSubscription?.cancel());
    _membershipSubscription = null;
    _cancelMemberCommands();
    _memberCommandErrors.clear();
    _releaseDirectoryData();
    for (final focusNode in _rowFocusNodes.values) {
      focusNode.dispose();
    }
    _rowFocusNodes.clear();
    _selectedUserIds = <UserId>{};
    _activeQuery = '';
    _searchController.clear();
    _searchController.dispose();
    super.dispose();
  }
}

class _DirectoryErrorState extends StatelessWidget {
  const _DirectoryErrorState({
    required this.onRetry,
    this.loadingMore = false,
  });

  final VoidCallback onRetry;
  final bool loadingMore;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        liveRegion: true,
        label: loadingMore
            ? 'Could not load more people'
            : 'Member directory search failed',
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                loadingMore
                    ? 'Could not load more people.'
                    : 'Could not search the directory.',
                key: const ValueKey('handrail-member-picker-error'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('handrail-member-picker-retry'),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
