import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_application_delegates.dart';
import 'handrail_chat_theme.dart';
import 'message_search.dart';

/// A state-management-neutral, host-backed conversation and message search.
///
/// Search transport is entirely supplied by [search]. Results are transient:
/// this widget never reads a chat client, scans normalized state, creates a
/// local full-text index, or persists host-provided snippets.
class HandrailMessageSearch extends StatefulWidget {
  const HandrailMessageSearch({
    required this.search,
    required this.applicationDelegates,
    this.filters = HandrailMessageSearchFilter.empty,
    this.searchDebounce = const Duration(milliseconds: 300),
    this.pageSize = 50,
    this.initialQuery = '',
    this.autofocusSearch = false,
    this.snippetMaxLines = 3,
    super.key,
  })  : assert(pageSize > 0),
        assert(snippetMaxLines > 0);

  final HandrailMessageSearchDelegate search;
  final ChatApplicationDelegates applicationDelegates;
  final HandrailMessageSearchFilter filters;
  final Duration searchDebounce;
  final int pageSize;
  final String initialQuery;
  final bool autofocusSearch;
  final int snippetMaxLines;

  @override
  HandrailMessageSearchState createState() => HandrailMessageSearchState();
}

/// Public only to support lifecycle verification with a [GlobalKey].
class HandrailMessageSearchState extends State<HandrailMessageSearch> {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  final Map<Object, FocusNode> _hitFocusNodes = <Object, FocusNode>{};
  Timer? _debounceTimer;
  int _searchGeneration = 0;
  String _activeQuery = '';
  List<HandrailMessageSearchHit> _hits = const [];
  Set<Object> _hitKeys = <Object>{};
  final Set<String> _requestedPageTokens = <String>{};
  bool _initialPageRequested = false;
  String? _nextPageToken;
  String? _failedPageToken;
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _searchError = false;
  String? _navigationAnnouncement;
  bool _disposed = false;

  /// Number of transient search hits still retained by this state object.
  @visibleForTesting
  int get debugRetainedHitCount => _hits.length;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _searchFocusNode = FocusNode(debugLabel: 'Handrail message search');
    _activeQuery = normalizeHandrailMessageSearchQuery(widget.initialQuery);
    if (_activeQuery.isNotEmpty) {
      final generation = ++_searchGeneration;
      unawaited(_requestPage(generation: generation, pageToken: null));
    }
  }

  @override
  void didUpdateWidget(covariant HandrailMessageSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.search != widget.search ||
        oldWidget.filters != widget.filters ||
        oldWidget.pageSize != widget.pageSize) {
      _scheduleNewSearch(_searchController.text, immediate: true);
    }
  }

  void _onSearchChanged(String value) {
    _scheduleNewSearch(value, immediate: false);
  }

  void _scheduleNewSearch(String value, {required bool immediate}) {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final generation = ++_searchGeneration;
    _activeQuery = normalizeHandrailMessageSearchQuery(value);
    _releaseSearchData();
    if (mounted) setState(() {});
    if (_activeQuery.isEmpty) return;
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
      if (_initialPageRequested || _activeQuery.isEmpty) return;
      _initialPageRequested = true;
    } else if (!_requestedPageTokens.add(pageToken)) {
      return;
    }

    if (mounted) {
      setState(() {
        _searchError = false;
        _failedPageToken = null;
        _navigationAnnouncement = null;
        if (pageToken == null) {
          _initialLoading = true;
        } else {
          _loadingMore = true;
        }
      });
    }

    try {
      final page = await widget.search(
        HandrailMessageSearchRequest(
          query: _activeQuery,
          filters: widget.filters,
          pageSize: widget.pageSize,
          pageToken: pageToken,
        ),
      );
      if (_disposed || !mounted || generation != _searchGeneration) return;

      final mergedHits = <HandrailMessageSearchHit>[
        if (pageToken != null) ..._hits,
      ];
      final mergedKeys = <Object>{
        if (pageToken != null) ..._hitKeys,
      };
      for (final hit in page.hits) {
        if (mergedKeys.add(hit.identityKey)) mergedHits.add(hit);
      }
      final candidateNextToken = page.nextPageToken;
      final safeNextToken = candidateNextToken == pageToken ||
              (candidateNextToken != null &&
                  _requestedPageTokens.contains(candidateNextToken))
          ? null
          : candidateNextToken;

      setState(() {
        _hits = List<HandrailMessageSearchHit>.unmodifiable(mergedHits);
        _hitKeys = mergedKeys;
        _nextPageToken = safeNextToken;
        _initialLoading = false;
        _loadingMore = false;
        _searchError = false;
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
        _searchError = true;
        _failedPageToken = pageToken;
      });
    }
  }

  void _retry() {
    if (_initialLoading || _loadingMore || !_searchError) return;
    unawaited(
      _requestPage(
        generation: _searchGeneration,
        pageToken: _failedPageToken,
      ),
    );
  }

  void _loadMore() {
    final token = _nextPageToken;
    if (token == null || _loadingMore || _searchError) return;
    unawaited(
      _requestPage(generation: _searchGeneration, pageToken: token),
    );
  }

  Future<void> _activate(HandrailMessageSearchHit hit) async {
    if (_disposed) return;
    try {
      final result =
          await widget.applicationDelegates.openMessageSearchHit(hit);
      if (_disposed || !mounted) return;
      setState(() {
        _navigationAnnouncement = switch (result) {
          ChatApplicationDelegateResult.handled => null,
          ChatApplicationDelegateResult.cancelled => 'Opening result cancelled',
          ChatApplicationDelegateResult.unavailable =>
            'This search result cannot be opened',
        };
      });
    } catch (_) {
      if (_disposed || !mounted) return;
      setState(() {
        _navigationAnnouncement = 'Could not open search result';
      });
    }
  }

  KeyEventResult _handleSearchKey(FocusNode _, KeyEvent event) {
    if (!_isActivationKeyEvent(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && _hits.isNotEmpty) {
      _focusHit(0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleHitKey(
    KeyEvent event,
    int index,
    HandrailMessageSearchHit hit,
  ) {
    if (!_isActivationKeyEvent(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusHit(index + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (index == 0) {
        _searchFocusNode.requestFocus();
      } else {
        _focusHit(index - 1);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_activate(hit));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _isActivationKeyEvent(KeyEvent event) =>
      event is KeyDownEvent || event is KeyRepeatEvent;

  void _focusHit(int index) {
    if (_hits.isEmpty) return;
    final bounded = index.clamp(0, _hits.length - 1);
    _focusNodeFor(_hits[bounded]).requestFocus();
  }

  FocusNode _focusNodeFor(HandrailMessageSearchHit hit) =>
      _hitFocusNodes.putIfAbsent(
        hit.identityKey,
        () => FocusNode(debugLabel: 'Search result ${hit.identityKey}'),
      );

  @override
  Widget build(BuildContext context) {
    final chatTheme = HandrailChatTheme.of(context);
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: Focus(
              onKeyEvent: _handleSearchKey,
              child: Semantics(
                textField: true,
                label: 'Search conversations and messages',
                child: TextField(
                  key: const ValueKey('handrail-message-search-field'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: widget.autofocusSearch,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Search messages',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: chatTheme.spacing.small),
          Expanded(child: _buildBody(context, chatTheme)),
          if (_navigationAnnouncement case final announcement?)
            Semantics(
              liveRegion: true,
              label: announcement,
              child: ExcludeSemantics(child: Text(announcement)),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    HandrailChatThemeData chatTheme,
  ) {
    if (_activeQuery.isEmpty) {
      return Center(
        child: Text(
          'Enter a search term',
          key: ValueKey('handrail-message-search-initial'),
        ),
      );
    }
    if (_initialLoading && _hits.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'Searching messages',
          child: CircularProgressIndicator(
            key: ValueKey('handrail-message-search-initial-loading'),
          ),
        ),
      );
    }
    if (_searchError && _hits.isEmpty) {
      return _MessageSearchErrorState(onRetry: _retry);
    }
    if (_hits.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'No search results',
          child: Text(
            'No results found',
            key: ValueKey('handrail-message-search-empty'),
          ),
        ),
      );
    }

    final footerCount =
        _nextPageToken != null || _loadingMore || _searchError ? 1 : 0;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${_hits.length} search results',
      child: ListView.builder(
        key: const ValueKey('handrail-message-search-results'),
        itemCount: _hits.length + footerCount,
        itemBuilder: (context, index) {
          if (index == _hits.length) return _buildFooter();
          return _buildHit(context, chatTheme, _hits[index], index);
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      return Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading more search results',
            child: CircularProgressIndicator(
              key: ValueKey('handrail-message-search-loading-more'),
            ),
          ),
        ),
      );
    }
    if (_searchError) {
      return _MessageSearchErrorState(loadingMore: true, onRetry: _retry);
    }
    return Center(
      child: FocusTraversalOrder(
        order: NumericFocusOrder(_hits.length + 1),
        child: TextButton(
          key: const ValueKey('handrail-message-search-load-more'),
          onPressed: _loadMore,
          child: const Text('Load more'),
        ),
      ),
    );
  }

  Widget _buildHit(
    BuildContext context,
    HandrailChatThemeData chatTheme,
    HandrailMessageSearchHit hit,
    int index,
  ) {
    final typeLabel =
        hit is HandrailMessageSearchMessageHit ? 'message' : 'conversation';
    final detail =
        hit is HandrailMessageSearchMessageHit ? hit.authorDisplayName : null;
    final semanticsLabel = <String>[
      typeLabel,
      hit.title,
      if (detail != null && detail.isNotEmpty) detail,
      hit.snippet,
    ].join(', ');

    return FocusTraversalOrder(
      order: NumericFocusOrder(index + 1),
      child: Semantics(
        container: true,
        button: true,
        label: semanticsLabel,
        onTap: () => _activate(hit),
        child: Focus(
          focusNode: _focusNodeFor(hit),
          onKeyEvent: (_, event) => _handleHitKey(event, index, hit),
          child: Material(
            key: ValueKey('handrail-message-search-hit-$typeLabel-$index'),
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(chatTheme.radii.medium),
            child: InkWell(
              excludeFromSemantics: true,
              borderRadius: BorderRadius.circular(chatTheme.radii.medium),
              onTap: () => _activate(hit),
              child: Padding(
                padding: EdgeInsets.all(chatTheme.spacing.medium),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          hit is HandrailMessageSearchMessageHit
                              ? Icons.chat_bubble_outline
                              : Icons.forum_outlined,
                          size: 18,
                        ),
                        SizedBox(width: chatTheme.spacing.small),
                        Expanded(
                          child: Text(
                            hit.title,
                            style: chatTheme.typography.conversationTitle,
                          ),
                        ),
                      ],
                    ),
                    if (detail != null && detail.isNotEmpty) ...[
                      SizedBox(height: chatTheme.spacing.extraSmall),
                      Text(detail, style: chatTheme.typography.metadata),
                    ],
                    SizedBox(height: chatTheme.spacing.extraSmall),
                    Text(
                      hit.snippet,
                      key: ValueKey('handrail-message-search-snippet-$index'),
                      maxLines: widget.snippetMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: chatTheme.typography.message,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _releaseSearchData() {
    _hits = const [];
    _hitKeys = <Object>{};
    _requestedPageTokens.clear();
    _initialPageRequested = false;
    _nextPageToken = null;
    _failedPageToken = null;
    _initialLoading = false;
    _loadingMore = false;
    _searchError = false;
    _navigationAnnouncement = null;
    _disposeUnusedFocusNodes();
  }

  void _disposeUnusedFocusNodes() {
    final staleKeys = _hitFocusNodes.keys
        .where((key) => !_hitKeys.contains(key))
        .toList(growable: false);
    for (final key in staleKeys) {
      _hitFocusNodes.remove(key)?.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchGeneration += 1;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _releaseSearchData();
    for (final focusNode in _hitFocusNodes.values) {
      focusNode.dispose();
    }
    _hitFocusNodes.clear();
    _activeQuery = '';
    _searchFocusNode.dispose();
    _searchController.clear();
    _searchController.dispose();
    super.dispose();
  }
}

class _MessageSearchErrorState extends StatelessWidget {
  const _MessageSearchErrorState({
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
            ? 'Could not load more search results'
            : 'Message search failed',
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                loadingMore
                    ? 'Could not load more results.'
                    : 'Could not search messages.',
                key: ValueKey(
                  loadingMore
                      ? 'handrail-message-search-pagination-error'
                      : 'handrail-message-search-error',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('handrail-message-search-retry'),
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
