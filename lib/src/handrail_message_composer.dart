import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import 'chat_application_delegates.dart';
import 'chat_scope.dart';
import 'handrail_chat_theme.dart';
import 'handrail_member_picker.dart';

/// The upload-handle surface consumed by [HandrailMessageComposer].
///
/// Production composers adapt the public [ChatAttachmentUploadHandle]
/// returned by [ChatConversationController.uploadAttachment]. Tests and host
/// wrappers may provide an equivalent handle without exposing transport or
/// picker internals.
abstract interface class HandrailMessageComposerUploadHandle {
  String get uploadId;
  ChatAttachmentUploadState get state;
  Future<ChatAttachmentUploadResult> get completion;
  void cancel();
}

typedef HandrailMessageComposerUploadStarter
    = HandrailMessageComposerUploadHandle Function(
  ChatConversationController conversation,
  ChatAttachmentUploadSource source,
);

/// Resolves one host-directory identity without granting membership access.
///
/// The composer accepts the result only when it describes the requested user,
/// is eligible, and is an active member of the bound conversation.
typedef HandrailMessageMentionResolver = Future<HandrailMemberDirectoryRow?>
    Function(UserId userId);

/// Explicit host directory used only for message mention lookup.
///
/// Search results and resolved identities are always intersected with the
/// conversation controller's canonical active-member map. Omitting this
/// configuration disables mention suggestions and mention metadata.
@immutable
final class HandrailMessageMentionConfiguration {
  const HandrailMessageMentionConfiguration({
    required this.searchDirectory,
    required this.resolveUser,
    this.pageSize = 8,
  }) : assert(pageSize > 0 && pageSize <= 100);

  final HandrailMemberDirectorySearchDelegate searchDirectory;
  final HandrailMessageMentionResolver resolveUser;
  final int pageSize;
}

/// Customizes the selected reply strip without owning its shared source controller.
typedef HandrailMessageComposerReplyBuilder = Widget Function(
  BuildContext context,
  HandrailMessageComposerReplyControls controls,
);

/// Typed integration surface for reply presentation. Source context is ephemeral;
/// builders must replace it on every rebuild and never persist source text.
@immutable
final class HandrailMessageComposerReplyControls {
  const HandrailMessageComposerReplyControls({
    required this.reference,
    required this.context,
    required this.setNotifyAuthor,
    required this.cancel,
    required this.retry,
  });
  final MessageReplyReference reference;
  final ChatMessageContextState context;
  final ValueChanged<bool>? setNotifyAuthor;
  final VoidCallback? cancel;
  final VoidCallback? retry;
}

/// Optional controller-backed message input for one conversation.
///
/// The composer uses only the public conversation, timeline, draft, typing,
/// send, and attachment-upload contracts. Attachment selection remains owned
/// by the host application through [delegates].
class HandrailMessageComposer extends StatefulWidget {
  const HandrailMessageComposer({
    required this.conversationId,
    this.delegates = const ChatApplicationDelegates(),
    this.controller,
    this.focusNode,
    this.enabled = true,
    this.autofocus = false,
    this.submitOnKeyboardAction = true,
    this.initialFormat = MessageContentFormat.plain,
    this.showFormatSelector = true,
    this.draftDebounce = const Duration(milliseconds: 500),
    this.typingIdleTimeout = const Duration(seconds: 3),
    this.maxTextUtf8Bytes = maxDraftTextUtf8Bytes,
    this.maxAttachments = maxDraftAttachmentReferences,
    this.minLines = 1,
    this.maxLines = 6,
    this.mentions,
    this.attachmentUploadStarter,
    this.onSent,
    this.replyBuilder,
    super.key,
  })  : assert(maxTextUtf8Bytes > 0),
        assert(maxTextUtf8Bytes <= maxDraftTextUtf8Bytes),
        assert(maxAttachments > 0),
        assert(maxAttachments <= maxDraftAttachmentReferences),
        assert(minLines > 0),
        assert(maxLines >= minLines);

  final ConversationId conversationId;
  final ChatApplicationDelegates delegates;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool autofocus;

  /// Uses the platform's send keyboard action to submit the current message.
  /// Multiline editing remains available from the keyboard's newline key.
  final bool submitOnKeyboardAction;
  final MessageContentFormat initialFormat;

  /// Shows the visual formatting toolbar.
  ///
  /// The name is retained for source compatibility with the former raw
  /// Plain text/Markdown selector. The composer no longer exposes that
  /// source-format control.
  final bool showFormatSelector;
  final Duration draftDebounce;
  final Duration typingIdleTimeout;
  final int maxTextUtf8Bytes;
  final int maxAttachments;
  final int minLines;
  final int maxLines;

  /// Optional host directory for active-conversation-member mentions.
  final HandrailMessageMentionConfiguration? mentions;

  /// Overrides only creation of the public upload handle.
  ///
  /// When omitted, the composer calls
  /// [ChatConversationController.uploadAttachment] directly.
  final HandrailMessageComposerUploadStarter? attachmentUploadStarter;
  final VoidCallback? onSent;

  /// Optional reply presentation. Selection is available through a GlobalKey's
  /// [HandrailMessageComposerState.selectReply]. Hosts configure authority on
  /// client.messageContexts once for all shared consumers. This widget only
  /// subscribes; it never resets authority or disposes a shared controller.
  final HandrailMessageComposerReplyBuilder? replyBuilder;

  @override
  HandrailMessageComposerState createState() => HandrailMessageComposerState();
}

/// Public state type to support focus and disposal tests with a [GlobalKey].
class HandrailMessageComposerState extends State<HandrailMessageComposer> {
  late _ComposerTextEditingController _textController;
  TextEditingController? _hostTextController;
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  late MessageContentFormat _format;

  HandrailChatClient? _client;
  ChatConversationController? _conversation;
  ChatTimelineController? _timeline;
  StreamSubscription<ChatConversationControllerState>?
      _conversationSubscription;
  StreamSubscription<ChatTimelineControllerState>? _timelineSubscription;
  ChatConversationControllerState? _conversationState;
  ChatTimelineControllerState? _timelineState;

  Timer? _draftTimer;
  Timer? _typingTimer;
  Timer? _uploadProgressTimer;
  final List<AttachmentId> _attachmentIds = <AttachmentId>[];
  final List<_ComposerUpload> _uploads = <_ComposerUpload>[];
  _ComposerSubmission? _failedContent;
  MessageReplyReference? _replyTo;
  ChatMessageContextController? _replyContext;
  StreamSubscription<ChatMessageContextState>? _replySubscription;
  int _compositionGeneration = 0;

  MessageReplyReference? get replyTo => _replyTo;

  /// Continues composition without changing the draft, destination or reference.
  bool focusComposition() {
    if (!_canInteract || _sending) return false;
    _focusNode.requestFocus();
    return true;
  }

  /// Selects a source in this composer conversation, including an existing
  /// thread. This creates a new message; it never edits message ancestry.
  /// Returns false when disabled, sending, or given another conversation.
  bool selectReply(MessageContextRequest source) {
    if (!_canInteract ||
        _sending ||
        source.conversationId != widget.conversationId) {
      return false;
    }
    _setReplyReference(MessageReplyReference(
      messageId: source.messageId,
      notifyAuthor: true,
    ));
    _authoredContentChanged();
    _focusNode.requestFocus();
    return true;
  }

  void setReplyNotifyAuthor(bool notifyAuthor) {
    if (!_canInteract || _sending || _replyTo == null) return;
    _setReplyReference(MessageReplyReference(
      messageId: _replyTo!.messageId,
      notifyAuthor: notifyAuthor,
    ));
    _authoredContentChanged();
    _focusNode.requestFocus();
  }

  /// Cancels only the reference, retaining text, mentions and attachments.
  void cancelReply() {
    if (!_canInteract || _sending || _replyTo == null) return;
    _setReplyReference(null);
    _authoredContentChanged();
    _focusNode.requestFocus();
  }

  void retryReplyContext() {
    if (!_canInteract || _sending) return;
    final controller = _replyContext;
    if (controller != null) unawaited(controller.retry());
    _focusNode.requestFocus();
  }

  void _setReplyReference(MessageReplyReference? reference) {
    final sameSource = _replyTo?.messageId == reference?.messageId;
    _replyTo = reference;
    if (sameSource && _replyContext != null) return;
    unawaited(_replySubscription?.cancel());
    _replySubscription = null;
    _replyContext = null;
    if (reference == null || _client == null) return;
    final controller =
        _client!.messageContexts.forMessage(MessageContextRequest(
      conversationId: widget.conversationId,
      messageId: reference.messageId,
    ));
    _replyContext = controller;
    _replySubscription = controller.states.listen((_) {
      if (!_disposed && identical(_replyContext, controller)) setState(() {});
    });
    unawaited(controller.load());
  }

  String? _sendError;
  String? _attachmentError;
  String? _draftError;
  String? _validationError;
  int? _lastAppliedDraftRevision;
  var _bindingGeneration = 0;
  var _draftGeneration = 0;
  var _programmaticTextChange = false;
  var _synchronizingHostController = false;
  var _initialDraftRestored = false;
  var _localDraftDirty = false;
  var _typingStarted = false;
  var _pickingAttachment = false;
  var _sending = false;
  var _restoringMentions = false;
  var _disposed = false;
  late String _lastText;
  final List<_TrackedMention> _trackedMentions = <_TrackedMention>[];
  final LayerLink _mentionAnchor = LayerLink();
  final OverlayPortalController _mentionOverlay = OverlayPortalController();
  List<HandrailMemberDirectoryRow> _mentionRows = const [];
  _ActiveMentionToken? _activeMentionToken;
  String? _dismissedMentionSignature;
  int _selectedMentionIndex = 0;
  int _mentionSearchGeneration = 0;
  int _mentionValidationGeneration = 0;

  /// Active uploads retained by this composer. Intended for lifecycle tests.
  @visibleForTesting
  int get debugActiveUploadCount => _uploads.length;

  @override
  void initState() {
    super.initState();
    _format = widget.initialFormat;
    _hostTextController = widget.controller;
    _textController = _ComposerTextEditingController(
      value: widget.controller?.value ?? TextEditingValue.empty,
    );
    _hostTextController?.addListener(_handleHostControllerChanged);
    _lastText = _textController.text;
    _textController.addListener(_handleTextChanged);
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChanged);
    _updateValidation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(ChatScope.of(context).client);
  }

  @override
  void didUpdateWidget(covariant HandrailMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _hostTextController?.removeListener(_handleHostControllerChanged);
      _hostTextController = widget.controller;
      _hostTextController?.addListener(_handleHostControllerChanged);
      _textController.replaceWithPlainText(
        widget.controller?.value ?? TextEditingValue.empty,
      );
      _lastText = _textController.text;
      _clearMentionState();
      _updateValidation();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_handleFocusChanged);
      if (_ownsFocusNode) _focusNode.dispose();
      _ownsFocusNode = widget.focusNode == null;
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.conversationId != widget.conversationId) {
      _bind(ChatScope.of(context).client, force: true);
    }
    if (oldWidget.mentions != widget.mentions) {
      _revalidateTrackedMentions();
      _refreshMentionSuggestions();
    }
    if (oldWidget.enabled && !widget.enabled) {
      _stopTyping();
      _dismissMentionSuggestions();
    }
    if (oldWidget.maxTextUtf8Bytes != widget.maxTextUtf8Bytes ||
        oldWidget.maxAttachments != widget.maxAttachments) {
      setState(_updateValidation);
    }
  }

  void _bind(HandrailChatClient client, {bool force = false}) {
    if (!force && identical(_client, client) && _conversation != null) return;
    if (_localDraftDirty && !_sending) {
      unawaited(_synchronizeDraft(_draftGeneration));
    }
    _draftTimer?.cancel();
    ++_draftGeneration;
    final generation = ++_bindingGeneration;
    _sending = false;
    _pickingAttachment = false;
    _failedContent = null;
    _sendError = null;
    _draftError = null;
    _attachmentError = null;
    _setReplyReference(null);
    _stopTyping();
    _cancelBindingSubscriptions();
    _cancelUploads();
    _client = client;
    _conversation = client.conversations.forConversation(widget.conversationId);
    _timeline = client.timelines.forConversation(widget.conversationId);
    _conversationState = _conversation!.state;
    _timelineState = _timeline!.state;
    _initialDraftRestored = false;
    _lastAppliedDraftRevision = null;
    _localDraftDirty = false;
    _attachmentIds.clear();
    _uploads.clear();
    _clearMentionState();
    _replaceAuthoredContent(
        text: '',
        format: widget.initialFormat,
        attachmentIds: const [],
        mentions: null);
    _restoreDraftIfNeeded(_conversationState!, allowInitialClear: false);
    _conversationSubscription = _conversation!.states.listen((state) {
      if (_disposed || generation != _bindingGeneration) return;
      if (state == _conversationState) return;
      setState(() {
        _conversationState = state;
        if (_pruneTrackedMentions()) {
          _localDraftDirty = true;
          _scheduleDraftSynchronization();
        }
        _restoreDraftIfNeeded(state, allowInitialClear: state.isReady);
      });
      _refreshMentionSuggestions();
      if (!state.isReady) _stopTyping();
    });
    _timelineSubscription = _timeline!.states.listen((state) {
      if (_disposed || generation != _bindingGeneration) return;
      if (identical(state, _timelineState)) return;
      setState(() => _timelineState = state);
      if (!state.isReady) _stopTyping();
    });
  }

  void _cancelBindingSubscriptions() {
    final conversation = _conversationSubscription;
    final timeline = _timelineSubscription;
    _conversationSubscription = null;
    _timelineSubscription = null;
    if (conversation != null) unawaited(conversation.cancel());
    if (timeline != null) unawaited(timeline.cancel());
  }

  void _restoreDraftIfNeeded(
    ChatConversationControllerState state, {
    required bool allowInitialClear,
  }) {
    if (_localDraftDirty || _sending) return;
    final projection = state.draft;
    if (projection == null) {
      if (_initialDraftRestored || !allowInitialClear) return;
      _initialDraftRestored = true;
      _replaceAuthoredContent(
        text: '',
        format: widget.initialFormat,
        attachmentIds: const <AttachmentId>[],
        mentions: null,
      );
      return;
    }
    if (_initialDraftRestored &&
        projection.revision == _lastAppliedDraftRevision) {
      return;
    }
    _initialDraftRestored = true;
    _lastAppliedDraftRevision = projection.revision;
    switch (projection.draft) {
      case CanonicalReplacedDraft(:final content):
        _replaceAuthoredContent(
          text: content.text,
          format: _messageFormat(content.format),
          attachmentIds:
              content.attachments.map((attachment) => attachment.attachmentId),
          mentions: content.mentions,
          replyTo: content.replyTo,
        );
      case CanonicalClearDraftTombstone():
        _replaceAuthoredContent(
          text: '',
          format: widget.initialFormat,
          attachmentIds: const <AttachmentId>[],
          mentions: null,
        );
    }
  }

  void _replaceAuthoredContent({
    required String text,
    required MessageContentFormat format,
    required Iterable<AttachmentId> attachmentIds,
    required Iterable<MessageMention>? mentions,
    MessageReplyReference? replyTo,
  }) {
    _draftTimer?.cancel();
    _setReplyReference(replyTo);
    _clearMentionState();
    _programmaticTextChange = true;
    if (format == MessageContentFormat.markdown) {
      _textController.replaceWithMarkdown(text);
    } else {
      _textController.replaceWithPlainText(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
    }
    _programmaticTextChange = false;
    _lastText = _textController.text;
    _format = format;
    _attachmentIds
      ..clear()
      ..addAll(attachmentIds.take(widget.maxAttachments));
    _localDraftDirty = false;
    _failedContent = null;
    _updateValidation();
    _restoreValidatedMentions(_textController.text, mentions);
  }

  void _handleHostControllerChanged() {
    final host = _hostTextController;
    if (host == null || _synchronizingHostController || _disposed) return;
    _synchronizingHostController = true;
    _textController.value = host.value;
    _synchronizingHostController = false;
  }

  void _synchronizeHostController() {
    final host = _hostTextController;
    if (host == null ||
        _synchronizingHostController ||
        host.value == _textController.value) {
      return;
    }
    _synchronizingHostController = true;
    host.value = _textController.value;
    _synchronizingHostController = false;
  }

  void _handleTextChanged() {
    _synchronizeHostController();
    if (_programmaticTextChange || _disposed) return;
    final text = _textController.text;
    if (text == _lastText) {
      if (mounted) setState(() {});
      _refreshMentionSuggestions();
      return;
    }
    _textController.reconcileTextEdit(_lastText, text);
    _reconcileTrackedMentionsForEdit(_lastText, text);
    _lastText = text;
    ++_mentionValidationGeneration;
    _restoringMentions = false;
    _authoredContentChanged();
    _refreshMentionSuggestions();
    if (_textController.text.trim().isEmpty) {
      _stopTyping();
    } else if (_canInteract && _focusNode.hasFocus) {
      _startOrRefreshTyping();
    }
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _stopTyping();
      _dismissMentionSuggestions(preserveDismissal: false);
    } else if (_textController.text.trim().isNotEmpty && _canInteract) {
      _startOrRefreshTyping();
      _refreshMentionSuggestions();
    }
  }

  void _refreshMentionSuggestions() {
    final configuration = widget.mentions;
    final token = configuration == null || !_canInteract || !_focusNode.hasFocus
        ? null
        : _activeMention(_textController.value);
    final signature = token?.signature;
    if (token == null || signature == _dismissedMentionSignature) {
      ++_mentionSearchGeneration;
      _activeMentionToken = token;
      _mentionRows = const [];
      _selectedMentionIndex = 0;
      _syncMentionOverlay();
      return;
    }
    if (_activeMentionToken?.signature == signature &&
        _mentionRows.isNotEmpty) {
      _syncMentionOverlay();
      return;
    }
    _dismissedMentionSignature = null;
    _activeMentionToken = token;
    _mentionRows = const [];
    _selectedMentionIndex = 0;
    _syncMentionOverlay();
    final generation = ++_mentionSearchGeneration;
    final bindingGeneration = _bindingGeneration;
    unawaited(_searchMentions(
      configuration!,
      token,
      generation,
      bindingGeneration,
    ));
  }

  Future<void> _searchMentions(
    HandrailMessageMentionConfiguration configuration,
    _ActiveMentionToken token,
    int generation,
    int bindingGeneration,
  ) async {
    HandrailMemberDirectoryPage page;
    try {
      page = await configuration.searchDirectory(
        HandrailMemberDirectorySearchRequest(
          query: token.query,
          pageSize: configuration.pageSize,
        ),
      );
    } catch (_) {
      page = HandrailMemberDirectoryPage(rows: const []);
    }
    if (_disposed ||
        generation != _mentionSearchGeneration ||
        bindingGeneration != _bindingGeneration ||
        !identical(configuration, widget.mentions) ||
        _activeMention(_textController.value)?.signature != token.signature) {
      return;
    }
    final normalizedQuery = token.query.toLowerCase();
    final seen = <UserId>{};
    final rows = <HandrailMemberDirectoryRow>[
      for (final row in page.rows)
        if (!row.disabled &&
            _isActiveMember(row.userId) &&
            row.displayName.toLowerCase().contains(normalizedQuery) &&
            seen.add(row.userId))
          row,
    ].take(configuration.pageSize).toList(growable: false);
    setState(() {
      _mentionRows = rows;
      _selectedMentionIndex = 0;
    });
    _syncMentionOverlay();
  }

  void _syncMentionOverlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      final shouldShow = _mentionRows.isNotEmpty &&
          _activeMentionToken != null &&
          _canInteract &&
          _focusNode.hasFocus;
      if (shouldShow && !_mentionOverlay.isShowing) {
        _mentionOverlay.show();
      } else if (!shouldShow && _mentionOverlay.isShowing) {
        _mentionOverlay.hide();
      }
    });
  }

  void _dismissMentionSuggestions({bool preserveDismissal = true}) {
    ++_mentionSearchGeneration;
    if (preserveDismissal) {
      _dismissedMentionSignature = _activeMentionToken?.signature;
    }
    _activeMentionToken = null;
    _mentionRows = const [];
    _selectedMentionIndex = 0;
    _syncMentionOverlay();
    if (mounted) setState(() {});
  }

  KeyEventResult _handleComposerKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_activeMentionToken != null || _mentionRows.isNotEmpty)) {
      _dismissMentionSuggestions();
      return KeyEventResult.handled;
    }
    if (_mentionRows.isEmpty || _activeMentionToken == null) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedMentionIndex =
            (_selectedMentionIndex + 1) % _mentionRows.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedMentionIndex =
            (_selectedMentionIndex - 1 + _mentionRows.length) %
                _mentionRows.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _selectMention(_mentionRows[_selectedMentionIndex]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectMention(HandrailMemberDirectoryRow row) {
    final token = _activeMention(_textController.value);
    if (token == null ||
        row.disabled ||
        !_isActiveMember(row.userId) ||
        !_mentionRows.any((candidate) => candidate.userId == row.userId)) {
      return;
    }
    final oldText = _textController.text;
    final suffixStartsWithWhitespace = token.end < oldText.length &&
        _isWhitespace(oldText.substring(token.end, token.end + 1));
    final replacement = '@${row.displayName}'
        '${suffixStartsWithWhitespace ? '' : ' '}';
    final text = oldText.replaceRange(token.start, token.end, replacement);
    _textController.reconcileTextEdit(oldText, text);
    _reconcileTrackedMentionsForEdit(oldText, text);
    final mentionEnd = token.start + 1 + row.displayName.length;
    _trackedMentions.add(
      _TrackedMention(
        userId: row.userId,
        displayName: row.displayName,
        start: token.start,
        end: mentionEnd,
      ),
    );
    _programmaticTextChange = true;
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: token.start + replacement.length,
      ),
    );
    _programmaticTextChange = false;
    _lastText = text;
    _dismissMentionSuggestions(preserveDismissal: false);
    _authoredContentChanged();
    _focusNode.requestFocus();
  }

  void _restoreValidatedMentions(
    String text,
    Iterable<MessageMention>? mentions,
  ) {
    final configuration = widget.mentions;
    final userIds = <UserId>[
      for (final mention in mentions ?? const <MessageMention>[])
        if (mention is UserMention) mention.userId,
    ];
    final uniqueUserIds = userIds.toSet().toList(growable: false);
    if (configuration == null || uniqueUserIds.isEmpty) return;
    _restoringMentions = true;
    final generation = ++_mentionValidationGeneration;
    final bindingGeneration = _bindingGeneration;
    unawaited(_resolveRestoredMentions(
      configuration,
      uniqueUserIds,
      text,
      generation,
      bindingGeneration,
    ));
  }

  Future<void> _resolveRestoredMentions(
    HandrailMessageMentionConfiguration configuration,
    List<UserId> userIds,
    String text,
    int generation,
    int bindingGeneration,
  ) async {
    final rows = await Future.wait<HandrailMemberDirectoryRow?>([
      for (final userId in userIds)
        _resolveMentionUser(configuration.resolveUser, userId),
    ]);
    if (_disposed ||
        generation != _mentionValidationGeneration ||
        bindingGeneration != _bindingGeneration ||
        !identical(configuration, widget.mentions) ||
        _textController.text != text) {
      return;
    }
    final restored = <_TrackedMention>[];
    final occupied = <(int, int)>[];
    for (var index = 0; index < userIds.length; index += 1) {
      final row = rows[index];
      if (row == null ||
          row.userId != userIds[index] ||
          row.disabled ||
          !_isActiveMember(row.userId)) {
        continue;
      }
      final range = _findMentionRange(text, row.displayName, occupied);
      if (range == null) continue;
      occupied.add(range);
      restored.add(
        _TrackedMention(
          userId: row.userId,
          displayName: row.displayName,
          start: range.$1,
          end: range.$2,
        ),
      );
    }
    setState(() {
      _trackedMentions
        ..clear()
        ..addAll(restored);
      _restoringMentions = false;
    });
  }

  void _revalidateTrackedMentions() {
    final previous = List<_TrackedMention>.of(_trackedMentions);
    _trackedMentions.clear();
    ++_mentionValidationGeneration;
    _restoringMentions = false;
    final configuration = widget.mentions;
    if (configuration == null || previous.isEmpty) {
      if (previous.isNotEmpty) _scheduleDraftSynchronization();
      return;
    }
    _restoreValidatedMentions(
      _textController.text,
      previous
          .map((mention) => UserMention(userId: mention.userId))
          .toList(growable: false),
    );
  }

  void _reconcileTrackedMentionsForEdit(String oldText, String newText) {
    if (_trackedMentions.isEmpty || oldText == newText) return;
    var prefix = 0;
    final shortest =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (prefix < shortest &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < oldText.length - prefix &&
        suffix < newText.length - prefix &&
        oldText.codeUnitAt(oldText.length - suffix - 1) ==
            newText.codeUnitAt(newText.length - suffix - 1)) {
      suffix += 1;
    }
    final oldEnd = oldText.length - suffix;
    final delta = newText.length - oldText.length;
    for (final mention in _trackedMentions) {
      if (oldEnd <= mention.start) {
        mention
          ..start += delta
          ..end += delta;
      } else if (prefix < mention.end && oldEnd > mention.start) {
        mention.invalid = true;
      }
    }
    _trackedMentions.removeWhere(
      (mention) => mention.invalid || !_isTrackedMentionValid(mention, newText),
    );
  }

  bool _pruneTrackedMentions() {
    final previousLength = _trackedMentions.length;
    _trackedMentions.removeWhere(
      (mention) =>
          !_isActiveMember(mention.userId) ||
          !_isTrackedMentionValid(mention, _textController.text),
    );
    return previousLength != _trackedMentions.length;
  }

  bool _isTrackedMentionValid(_TrackedMention mention, String text) {
    if (mention.start < 0 || mention.end > text.length) return false;
    if (text.substring(mention.start, mention.end) !=
        '@${mention.displayName}') {
      return false;
    }
    return _hasMentionBoundaries(text, mention.start, mention.end);
  }

  bool _isActiveMember(UserId userId) =>
      _conversationState?.members[userId]?.state == 'active';

  List<MessageMention> _currentMentions() {
    _pruneTrackedMentions();
    final ids = <UserId>{};
    return <MessageMention>[
      for (final mention in _trackedMentions)
        if (ids.add(mention.userId)) UserMention(userId: mention.userId),
    ];
  }

  void _clearMentionState() {
    ++_mentionSearchGeneration;
    ++_mentionValidationGeneration;
    _trackedMentions.clear();
    _mentionRows = const [];
    _activeMentionToken = null;
    _dismissedMentionSignature = null;
    _selectedMentionIndex = 0;
    _restoringMentions = false;
    _syncMentionOverlay();
  }

  void _authoredContentChanged() {
    ++_compositionGeneration;
    _localDraftDirty = true;
    _failedContent = null;
    _sendError = null;
    _draftError = null;
    _updateValidation();
    if (mounted) setState(() {});
    _scheduleDraftSynchronization();
  }

  void _updateValidation() {
    final textBytes = utf8.encode(_wireText).length;
    if (textBytes > widget.maxTextUtf8Bytes) {
      _validationError = 'Message is too long '
          '($textBytes/${widget.maxTextUtf8Bytes} UTF-8 bytes).';
      return;
    }
    final attachmentCount = _attachmentIds.length + _uploads.length;
    if (attachmentCount > widget.maxAttachments) {
      _validationError = 'A message can include at most '
          '${widget.maxAttachments} attachments.';
      return;
    }
    _validationError = null;
  }

  void _scheduleDraftSynchronization() {
    _draftTimer?.cancel();
    final generation = ++_draftGeneration;
    if (_validationError != null || !_conversationReady) return;
    if (widget.draftDebounce == Duration.zero) {
      unawaited(_synchronizeDraft(generation));
      return;
    }
    _draftTimer = Timer(widget.draftDebounce, () {
      _draftTimer = null;
      unawaited(_synchronizeDraft(generation));
    });
  }

  Future<void> _synchronizeDraft(int generation) async {
    final conversation = _conversation;
    if (_disposed ||
        generation != _draftGeneration ||
        conversation == null ||
        !_conversationReady ||
        _validationError != null) {
      return;
    }
    final snapshot = _currentDraftContent();
    ChatCommandResult<SynchronizeDraftResult> result;
    try {
      result = snapshot.text.isEmpty &&
              snapshot.attachments.isEmpty &&
              snapshot.replyTo == null
          ? await conversation.clearDraft()
          : await conversation.synchronizeDraft(content: snapshot);
    } catch (_) {
      if (_disposed || generation != _draftGeneration) return;
      setState(() => _draftError = 'Draft could not be synchronized.');
      return;
    }
    if (_disposed || generation != _draftGeneration) return;
    if (result is ChatCommandSuccess<SynchronizeDraftResult>) {
      if (_sameDraft(snapshot, _currentDraftContent())) {
        setState(() {
          _localDraftDirty = false;
          _draftError = null;
        });
      } else {
        _scheduleDraftSynchronization();
      }
      return;
    }
    setState(() => _draftError = 'Draft could not be synchronized.');
  }

  DraftContent _currentDraftContent() {
    final mentions = _currentMentions();
    return DraftContent(
      replyTo: _replyTo,
      format: _draftFormat(_format),
      text: _wireText,
      mentions: mentions.isEmpty ? null : mentions,
      attachments: _attachmentIds.map(
        (attachmentId) => DraftAttachmentReference(attachmentId: attachmentId),
      ),
    );
  }

  MessageContent _currentMessageContent() {
    final mentions = _currentMentions();
    return MessageContent(
      format: _format,
      text: _wireText,
      mentions: mentions.isEmpty ? null : mentions,
      attachments: _attachmentIds
          .map((attachmentId) =>
              MessageAttachmentReference(attachmentId: attachmentId))
          .toList(growable: false),
    );
  }

  String get _wireText => _format == MessageContentFormat.markdown
      ? _textController.canonicalMarkdown
      : _textController.text;

  void _toggleInlineFormat(ComposerRichTextMarkType type) {
    if (!_textController.toggleInlineMark(type)) return;
    _formattingChanged();
  }

  void _toggleBlockFormat(_ComposerBlockType type) {
    if (!_textController.toggleBlock(type)) return;
    _formattingChanged();
  }

  void _formattingChanged() {
    _format = MessageContentFormat.markdown;
    _authoredContentChanged();
    _focusNode.requestFocus();
  }

  Future<void> _editLink() async {
    final selection = _textController.linkEditingSelection;
    if (selection == null || !_canInteract || _sending) return;
    final existing = _textController.linkAtSelection;
    final destination = TextEditingController(text: existing?.href ?? '');
    String? error;
    final result = await showDialog<_LinkEditResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add link' : 'Edit link'),
          content: TextField(
            key: const ValueKey('handrail-message-composer-link-destination'),
            controller: destination,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Link destination',
              hintText: 'https://example.com',
              errorText: error,
            ),
            onSubmitted: (_) {
              final href = sanitizeComposerMarkdownLink(destination.text);
              if (href == null) {
                setDialogState(
                    () => error = 'Enter a safe web, email, or relative link.');
                return;
              }
              Navigator.of(context).pop(_LinkEditResult(href: href));
            },
          ),
          actions: [
            if (existing != null)
              TextButton(
                key: const ValueKey('handrail-message-composer-link-remove'),
                onPressed: () => Navigator.of(context).pop(
                  const _LinkEditResult(remove: true),
                ),
                child: const Text('Remove link'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('handrail-message-composer-link-apply'),
              onPressed: () {
                final href = sanitizeComposerMarkdownLink(destination.text);
                if (href == null) {
                  setDialogState(() =>
                      error = 'Enter a safe web, email, or relative link.');
                  return;
                }
                Navigator.of(context).pop(_LinkEditResult(href: href));
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    destination.dispose();
    if (result == null || !mounted) return;
    final changed = result.remove
        ? _textController.removeLink(selection)
        : _textController.setLink(selection, result.href!);
    if (changed) _formattingChanged();
  }

  void _startOrRefreshTyping() {
    final conversation = _conversation;
    if (conversation == null || !_canInteract) return;
    try {
      _typingStarted = conversation.startTyping() || _typingStarted;
    } on StateError {
      return;
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(widget.typingIdleTimeout, _stopTyping);
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (!_typingStarted) return;
    _typingStarted = false;
    try {
      _conversation?.stopTyping();
    } on StateError {
      // A controller may become unresolved while the widget is unmounting.
    }
  }

  Future<void> _submit([_ComposerSubmission? retry]) async {
    if (!_canSend) return;
    final submission = retry ??
        _ComposerSubmission(
          client: _client!,
          input: ChatSendMessageInput(
            conversationId: widget.conversationId,
            content: _currentMessageContent(),
            replyTo: _replyTo,
          ),
          draft: _currentDraftContent(),
        );
    final binding = _bindingGeneration;
    final composition = _compositionGeneration;
    bool isCurrent() =>
        !_disposed &&
        binding == _bindingGeneration &&
        composition == _compositionGeneration &&
        !submission.identityChanged &&
        submission.hasCurrentActor;
    void releaseSupersededSend() {
      if (!_disposed && binding == _bindingGeneration) {
        setState(() => _sending = false);
        if (!submission.identityChanged && submission.hasCurrentActor) {
          _scheduleDraftSynchronization();
        }
      }
    }

    _draftTimer?.cancel();
    ++_draftGeneration;
    _stopTyping();
    setState(() {
      _sending = true;
      _sendError = null;
      _attachmentError = null;
    });

    // Watch the captured actor even when this widget is rebound while storage
    // is completing. A retry must never move the composition to another actor.
    final identityReady = Completer<void>();
    final identitySubscription =
        submission.client.queuedSendMessageStates.listen((state) {
      if (!submission.identityCaptured) {
        submission.identity = state.identity;
        submission.identityCaptured = true;
      } else if (submission.identity != state.identity) {
        submission.identityChanged = true;
      }
      if (!identityReady.isCompleted) identityReady.complete();
    });
    final actorSubscription =
        submission.client.replyStyles.states.listen((state) {
      if (!submission.hasCurrentActor) submission.identityChanged = true;
    });
    try {
      await identityReady.future;
      if (submission.identityChanged ||
          !submission.hasCurrentActor ||
          _disposed) {
        releaseSupersededSend();
        return;
      }
      final synchronization =
          submission.client.synchronizeDraftWithLocalPersistence(
        ChatReplaceDraftInput(
          conversationId: submission.input.conversationId,
          baseRevision: submission.client
                  .draftFor(submission.input.conversationId)
                  ?.revision ??
              0,
          content: submission.draft,
        ),
      );
      // Observe this same mutation's remote result; never submit it a second time.
      final settlement = synchronization.remoteSettlement;
      final local = await synchronization.localPersistence;
      if (local is ChatDraftNotPersisted &&
          local.reason != ChatDraftNotPersistedReason.storageUnavailable) {
        if (isCurrent()) {
          setState(() {
            _sending = false;
            _failedContent = submission;
            _localDraftDirty = true;
            _sendError =
                'Draft could not be saved locally. Retry or revise your message.';
          });
        } else {
          releaseSupersededSend();
        }
        return;
      }
      if (local is ChatDraftNotPersisted) {
        // No adapter means no durability promise. Preserve the legacy online
        // remote synchronization boundary in this configuration.
        await settlement;
      }
      if (submission.identityChanged ||
          !submission.hasCurrentActor ||
          _disposed) {
        releaseSupersededSend();
        return;
      }
      final draftRevision =
          submission.client.draftFor(submission.input.conversationId)?.revision;
      ChatCommandResult<SendMessageResult> result;
      try {
        result = await submission.client.sendMessage(submission.input);
      } catch (_) {
        if (!isCurrent()) {
          releaseSupersededSend();
          return;
        }
        setState(() {
          _sending = false;
          _failedContent = submission;
          _localDraftDirty = true;
          _sendError =
              'Message could not be sent. Retry or revise your message.';
        });
        _focusNode.requestFocus();
        return;
      }
      if (result is! ChatCommandSuccess<SendMessageResult> &&
          result is! ChatCommandQueued<SendMessageResult>) {
        if (!isCurrent()) {
          releaseSupersededSend();
          return;
        }
        setState(() {
          _sending = false;
          _failedContent = submission;
          _localDraftDirty = true;
          _sendError = result is ChatCommandFailure<SendMessageResult>
              ? result.message
              : 'Message could not be sent.';
        });
        _focusNode.requestFocus();
        return;
      }

      // Never clear a new binding or a newer local/remote composition. The
      // captured client always addresses the original destination.
      final projection =
          submission.client.draftFor(submission.input.conversationId);
      final unchangedDraft = projection?.revision == draftRevision &&
          projection?.draft is CanonicalReplacedDraft &&
          _sameDraft((projection!.draft as CanonicalReplacedDraft).content,
              submission.draft);
      final mayClear = unchangedDraft &&
          projection.conflict == null &&
          !submission.identityChanged &&
          submission.hasCurrentActor &&
          (binding != _bindingGeneration || isCurrent());
      ChatDraftSynchronization? clear;
      var cleanupFailed = false;
      if (mayClear) {
        // Queue the tombstone behind the pending replacement before releasing
        // the editor. Its local projection also prevents restoration on rebind.
        clear = submission.client.synchronizeDraftWithLocalPersistence(
          ChatClearDraftInput(
            conversationId: submission.input.conversationId,
            baseRevision: draftRevision!,
          ),
        );
        final cleared = await clear.localPersistence;
        cleanupFailed = cleared is ChatDraftNotPersisted &&
            cleared.reason != ChatDraftNotPersistedReason.storageUnavailable;
      }
      if (isCurrent()) {
        final newerDraft =
            !unchangedDraft && projection?.draft is CanonicalReplacedDraft
                ? (projection!.draft as CanonicalReplacedDraft).content
                : null;
        _replaceAuthoredContent(
          text: newerDraft?.text ?? '',
          format:
              newerDraft == null ? _format : _messageFormat(newerDraft.format),
          attachmentIds:
              newerDraft?.attachments.map((a) => a.attachmentId) ?? const [],
          mentions: newerDraft?.mentions,
          replyTo: newerDraft?.replyTo,
        );
        setState(() {
          _sending = false;
          _failedContent = null;
          _sendError = null;
          if (cleanupFailed) {
            _draftError = 'Message sent, but its draft could not be cleared.';
            _localDraftDirty = true;
          }
        });
        _focusNode.requestFocus();
        widget.onSent?.call();
      } else {
        releaseSupersededSend();
      }
      final settledEditor = isCurrent() ? _currentDraftContent() : null;
      bool mayReportCleanup() =>
          isCurrent() &&
          settledEditor != null &&
          _sameDraft(settledEditor, _currentDraftContent());
      try {
        await settlement;
        final result = await clear?.remoteSettlement;
        if (mayReportCleanup() &&
            result != null &&
            result is! ChatCommandSuccess<SynchronizeDraftResult>) {
          setState(() => _draftError =
              'Message sent, but its draft could not be cleared.');
        }
      } catch (_) {
        if (mayReportCleanup()) {
          setState(() => _draftError =
              'Message sent, but its draft could not be cleared.');
        }
      }
    } finally {
      await identitySubscription.cancel();
      await actorSubscription.cancel();
    }
  }

  Future<void> _pickAttachments() async {
    if (!_canInteract || _pickingAttachment || _sending) return;
    if (_attachmentIds.length + _uploads.length >= widget.maxAttachments) {
      setState(() => _attachmentError = 'A message can include at most '
          '${widget.maxAttachments} attachments.');
      return;
    }
    final generation = _bindingGeneration;
    setState(() {
      _pickingAttachment = true;
      _attachmentError = null;
    });
    ChatAttachmentPickerResult result;
    try {
      result = await widget.delegates.pickAttachment();
    } catch (_) {
      if (_disposed || generation != _bindingGeneration) return;
      setState(() {
        _pickingAttachment = false;
        _attachmentError = 'Attachment selection failed.';
      });
      return;
    }
    if (_disposed || generation != _bindingGeneration) return;
    setState(() => _pickingAttachment = false);
    switch (result) {
      case ChatAttachmentPickerCancelled():
        return;
      case ChatAttachmentPickerUnavailable():
        setState(() => _attachmentError =
            'Attachment selection is unavailable in this application.');
        return;
      case ChatAttachmentPickerSelection(:final attachmentIds):
        final unique = attachmentIds
            .where((id) => !_attachmentIds.contains(id))
            .toList(growable: false);
        if (!_canAddAttachments(unique.length)) return;
        setState(() => _attachmentIds.addAll(unique));
        _authoredContentChanged();
      case ChatAttachmentPickerUploadSelection(:final uploads):
        if (!_canAddAttachments(uploads.length)) return;
        _beginUploads(uploads, generation);
    }
  }

  bool _canAddAttachments(int count) {
    if (_attachmentIds.length + _uploads.length + count <=
        widget.maxAttachments) {
      return true;
    }
    setState(() => _attachmentError = 'A message can include at most '
        '${widget.maxAttachments} attachments.');
    return false;
  }

  void _beginUploads(
    List<ChatAttachmentUploadSource> sources,
    int generation,
  ) {
    final conversation = _conversation;
    if (conversation == null) return;
    final started = <_ComposerUpload>[];
    try {
      for (final source in sources) {
        final handle = widget.attachmentUploadStarter?.call(
              conversation,
              source,
            ) ??
            _ControllerComposerUploadHandle(
              conversation.uploadAttachment(
                metadata: source.metadata,
                source: source.source,
                temporaryResource: source.temporaryResource,
              ),
            );
        final upload = _ComposerUpload(handle: handle);
        started.add(upload);
        unawaited(_monitorUpload(upload, generation));
      }
    } catch (_) {
      for (final upload in started) {
        upload.handle.cancel();
      }
      setState(() => _attachmentError = 'Attachment upload could not start.');
      return;
    }
    setState(() {
      _uploads.addAll(started);
      _updateValidation();
    });
    _ensureUploadProgressTimer();
  }

  Future<void> _monitorUpload(_ComposerUpload upload, int generation) async {
    ChatAttachmentUploadResult result;
    try {
      result = await upload.handle.completion;
    } catch (_) {
      if (_disposed || generation != _bindingGeneration) return;
      setState(() {
        _uploads.remove(upload);
        _attachmentError = 'Attachment upload failed.';
        _updateValidation();
      });
      _stopUploadProgressTimerIfIdle();
      return;
    }
    if (_disposed || generation != _bindingGeneration) return;
    setState(() {
      _uploads.remove(upload);
      switch (result) {
        case ChatAttachmentUploadFinalized(:final attachment):
          if (!_attachmentIds.contains(attachment.attachmentId)) {
            _attachmentIds.add(attachment.attachmentId);
          }
          _localDraftDirty = true;
          _attachmentError = null;
        case ChatAttachmentUploadCancelled():
          _attachmentError = null;
        case ChatAttachmentUploadRejected():
          _attachmentError = 'Attachment was rejected.';
        case ChatAttachmentUploadFailed():
          _attachmentError = 'Attachment upload failed.';
      }
      _updateValidation();
    });
    if (result is ChatAttachmentUploadFinalized) {
      _scheduleDraftSynchronization();
    }
    _stopUploadProgressTimerIfIdle();
  }

  void _ensureUploadProgressTimer() {
    _uploadProgressTimer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (!_disposed && mounted && _uploads.isNotEmpty) setState(() {});
      },
    );
  }

  void _stopUploadProgressTimerIfIdle() {
    if (_uploads.isNotEmpty) return;
    _uploadProgressTimer?.cancel();
    _uploadProgressTimer = null;
  }

  void _cancelUpload(_ComposerUpload upload) {
    upload.handle.cancel();
    setState(() {});
  }

  void _removeAttachment(AttachmentId attachmentId) {
    setState(() => _attachmentIds.remove(attachmentId));
    _authoredContentChanged();
  }

  void _cancelUploads() {
    for (final upload in _uploads) {
      upload.handle.cancel();
    }
    _uploads.clear();
    _uploadProgressTimer?.cancel();
    _uploadProgressTimer = null;
  }

  bool get _conversationReady => _conversationState?.isReady ?? false;

  bool get _timelineReady => _timelineState?.isReady ?? false;

  bool get _canInteract =>
      widget.enabled && _conversationReady && _timelineReady && !_disposed;

  bool get _canSend {
    if (!_canInteract ||
        _sending ||
        _uploads.isNotEmpty ||
        _restoringMentions ||
        _validationError != null) {
      return false;
    }
    return _textController.text.trim().isNotEmpty || _attachmentIds.isNotEmpty;
  }

  String? get _availabilityMessage {
    final conversationStatus = _conversationState?.status;
    final timelineStatus = _timelineState?.status;
    if (conversationStatus == ChatConversationControllerStatus.accessRevoked ||
        timelineStatus == ChatTimelineControllerStatus.accessRevoked) {
      return 'You no longer have access to this conversation.';
    }
    if (conversationStatus == ChatConversationControllerStatus.notFound) {
      return 'This conversation is unavailable.';
    }
    if (conversationStatus == ChatConversationControllerStatus.error ||
        timelineStatus == ChatTimelineControllerStatus.error) {
      return 'The message composer could not be loaded.';
    }
    if (!widget.enabled) return 'Message composer disabled.';
    if (!_conversationReady || !_timelineReady) {
      return 'Loading message composer.';
    }
    return null;
  }

  String? get _operationMessage {
    if (_sending) return 'Sending message.';
    if (_pickingAttachment) return 'Choosing attachment.';
    if (_uploads.isNotEmpty) return 'Uploading attachment.';
    return _sendError ?? _attachmentError ?? _draftError;
  }

  Widget _buildReply(bool interactive) {
    // Read the shared controller's current snapshot on every build. Never hold
    // a second copy of authorized text across invalidation or identity changes.
    final state = _replyContext?.state ??
        ChatMessageContextState(status: ChatMessageContextStatus.unavailable);
    final controls = HandrailMessageComposerReplyControls(
      reference: _replyTo!,
      context: state,
      setNotifyAuthor: interactive ? setReplyNotifyAuthor : null,
      cancel: interactive ? cancelReply : null,
      retry: interactive ? retryReplyContext : null,
    );
    if (widget.replyBuilder != null) {
      return widget.replyBuilder!(context, controls);
    }
    final description = switch (state.status) {
      ChatMessageContextStatus.available =>
        'Replying to: ${state.source?.content.text ?? 'Message'}',
      ChatMessageContextStatus.loading => 'Loading reply source.',
      ChatMessageContextStatus.deleted => 'Reply source was deleted.',
      ChatMessageContextStatus.error => 'Reply source could not be loaded.',
      _ => 'Reply source is unavailable.',
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Inline reply',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterChip(
            label: const Text('Notify reply author'),
            selected: _replyTo!.notifyAuthor,
            onSelected: controls.setNotifyAuthor,
          ),
          IconButton(
              tooltip: 'Cancel reply',
              onPressed: controls.cancel,
              icon: const Icon(Icons.close)),
          if (state.status != ChatMessageContextStatus.available &&
              state.status != ChatMessageContextStatus.loading)
            TextButton.icon(
                onPressed: controls.retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry reply source')),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HandrailChatTheme.of(context);
    final colors = Theme.of(context).colorScheme;
    final availability = _availabilityMessage;
    final operation = _operationMessage;
    final interactive = _canInteract && !_sending;
    _textController.configureVisuals(
      linkColor: colors.primary,
      codeBackgroundColor: colors.surfaceContainerHighest,
      // Keep the 45% list highlight on Flutter 3.19 (8-bit alpha).
      listBackgroundColor: colors.secondaryContainer.withAlpha(115),
    );

    return Semantics(
      container: true,
      label: 'Message composer',
      enabled: interactive,
      child: Material(
        color: colors.surface,
        child: Container(
          padding: EdgeInsets.all(tokens.spacing.small),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_replyTo != null) _buildReply(interactive),
              if (_attachmentIds.isNotEmpty || _uploads.isNotEmpty)
                _buildAttachments(tokens),
              LayoutBuilder(
                // Retain the input/portal when reply and attachment rows change.
                // Flutter 3.19 cannot attach one controller to two portals.
                key: const ValueKey('handrail-message-composer-editor'),
                builder: (context, constraints) => OverlayPortal(
                  controller: _mentionOverlay,
                  overlayChildBuilder: (context) => UnconstrainedBox(
                    alignment: Alignment.topLeft,
                    child: CompositedTransformFollower(
                      link: _mentionAnchor,
                      showWhenUnlinked: false,
                      targetAnchor: Alignment.topLeft,
                      followerAnchor: Alignment.bottomLeft,
                      offset: const Offset(0, -4),
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: _buildMentionSuggestions(context),
                      ),
                    ),
                  ),
                  child: CompositedTransformTarget(
                    link: _mentionAnchor,
                    child: Focus(
                      onKeyEvent: _handleComposerKey,
                      child: Semantics(
                        label: 'Message input',
                        textField: true,
                        enabled: interactive,
                        child: TextField(
                          key:
                              const ValueKey('handrail-message-composer-input'),
                          controller: _textController,
                          focusNode: _focusNode,
                          autofocus: widget.autofocus,
                          enabled: interactive,
                          minLines: widget.minLines,
                          maxLines: widget.maxLines,
                          style: tokens.typography.composer,
                          keyboardType: TextInputType.multiline,
                          textInputAction: widget.submitOnKeyboardAction
                              ? TextInputAction.send
                              : TextInputAction.newline,
                          onSubmitted: widget.submitOnKeyboardAction
                              ? (_) => unawaited(_submit())
                              : null,
                          decoration: InputDecoration(
                            hintText: availability ?? 'Write a message',
                            errorText: _validationError,
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(tokens.radii.medium),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: tokens.spacing.extraSmall),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('handrail-message-composer-attach'),
                    tooltip: 'Add attachment',
                    onPressed: interactive && !_pickingAttachment
                        ? () => unawaited(_pickAttachments())
                        : null,
                    icon: _pickingAttachment
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file),
                  ),
                  if (widget.showFormatSelector)
                    Expanded(
                      child: SingleChildScrollView(
                        key: const ValueKey(
                          'handrail-message-composer-format-toolbar',
                        ),
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _formatButton(
                              keyName: 'bold',
                              tooltip: 'Bold',
                              icon: Icons.format_bold,
                              selected: _textController.selectionHasMark(
                                ComposerRichTextMarkType.bold,
                              ),
                              onPressed: interactive &&
                                      _textController.hasInlineSelection
                                  ? () => _toggleInlineFormat(
                                        ComposerRichTextMarkType.bold,
                                      )
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'italic',
                              tooltip: 'Italic',
                              icon: Icons.format_italic,
                              selected: _textController.selectionHasMark(
                                ComposerRichTextMarkType.italic,
                              ),
                              onPressed: interactive &&
                                      _textController.hasInlineSelection
                                  ? () => _toggleInlineFormat(
                                        ComposerRichTextMarkType.italic,
                                      )
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'link',
                              tooltip: 'Link',
                              icon: Icons.link,
                              selected: _textController.linkAtSelection != null,
                              onPressed: interactive &&
                                      _textController.linkEditingSelection !=
                                          null
                                  ? () => unawaited(_editLink())
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'unordered-list',
                              tooltip: 'Bulleted list',
                              icon: Icons.format_list_bulleted,
                              selected: _textController.selectionHasBlock(
                                _ComposerBlockType.unorderedList,
                              ),
                              onPressed: interactive &&
                                      _textController.hasBlockSelection
                                  ? () => _toggleBlockFormat(
                                        _ComposerBlockType.unorderedList,
                                      )
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'ordered-list',
                              tooltip: 'Numbered list',
                              icon: Icons.format_list_numbered,
                              selected: _textController.selectionHasBlock(
                                _ComposerBlockType.orderedList,
                              ),
                              onPressed: interactive &&
                                      _textController.hasBlockSelection
                                  ? () => _toggleBlockFormat(
                                        _ComposerBlockType.orderedList,
                                      )
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'inline-code',
                              tooltip: 'Inline code',
                              icon: Icons.code,
                              selected: _textController.selectionHasMark(
                                ComposerRichTextMarkType.code,
                              ),
                              onPressed: interactive &&
                                      _textController.hasInlineSelection
                                  ? () => _toggleInlineFormat(
                                        ComposerRichTextMarkType.code,
                                      )
                                  : null,
                            ),
                            _formatButton(
                              keyName: 'code-block',
                              tooltip: 'Code block',
                              icon: Icons.data_object,
                              selected: _textController.selectionHasBlock(
                                _ComposerBlockType.codeBlock,
                              ),
                              onPressed: interactive &&
                                      _textController.hasBlockSelection
                                  ? () => _toggleBlockFormat(
                                        _ComposerBlockType.codeBlock,
                                      )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (_failedContent != null)
                    TextButton.icon(
                      key: const ValueKey('handrail-message-composer-retry'),
                      onPressed: interactive
                          ? () => unawaited(_submit(_failedContent))
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  IconButton.filled(
                    key: const ValueKey('handrail-message-composer-send'),
                    tooltip: 'Send message',
                    onPressed: _canSend ? () => unawaited(_submit()) : null,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
              if (availability != null || operation != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.extraSmall),
                    child: Text(
                      operation ?? availability!,
                      key: const ValueKey('handrail-message-composer-status'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: operation != null &&
                                    !_sending &&
                                    !_pickingAttachment &&
                                    _uploads.isEmpty
                                ? colors.error
                                : colors.onSurfaceVariant,
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formatButton({
    required String keyName,
    required String tooltip,
    required IconData icon,
    required bool selected,
    required VoidCallback? onPressed,
  }) =>
      Semantics(
        selected: selected,
        button: true,
        label: tooltip,
        child: IconButton(
          key: ValueKey('handrail-message-composer-format-$keyName'),
          tooltip: tooltip,
          isSelected: selected,
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          selectedIcon: Icon(icon),
          icon: Icon(icon),
        ),
      );

  Widget _buildMentionSuggestions(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('handrail-message-composer-mention-suggestions'),
      elevation: 8,
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: _mentionRows.length,
          itemBuilder: (context, index) {
            final row = _mentionRows[index];
            final selected = index == _selectedMentionIndex;
            return Semantics(
              selected: selected,
              button: true,
              label: 'Mention ${row.displayName}',
              child: Material(
                color: selected ? colors.primaryContainer : Colors.transparent,
                child: InkWell(
                  key: ValueKey(
                    'handrail-message-composer-mention-${row.userId.value}',
                  ),
                  onTap: () => _selectMention(row),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.displayName),
                        if (row.subtitle case final subtitle?)
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAttachments(HandrailChatThemeData tokens) => Wrap(
        spacing: tokens.spacing.extraSmall,
        runSpacing: tokens.spacing.extraSmall,
        children: [
          for (final attachmentId in _attachmentIds)
            InputChip(
              key: ValueKey(
                'handrail-message-composer-attachment-${attachmentId.value}',
              ),
              label: Text(attachmentId.value),
              deleteButtonTooltipMessage: 'Remove attachment',
              onDeleted:
                  _canInteract ? () => _removeAttachment(attachmentId) : null,
            ),
          for (final upload in _uploads) _buildUpload(upload),
        ],
      );

  Widget _buildUpload(_ComposerUpload upload) {
    final state = upload.handle.state;
    final total = state.metadata.sizeBytes;
    final progress = total == 0 ? null : state.uploadedBytes / total;
    return Semantics(
      container: true,
      label: 'Uploading ${state.metadata.fileName}',
      value: total == 0
          ? state.status.name
          : '${(progress! * 100).round()} percent',
      child: SizedBox(
        width: 210,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.metadata.fileName,
                    overflow: TextOverflow.ellipsis,
                  ),
                  LinearProgressIndicator(value: progress),
                ],
              ),
            ),
            IconButton(
              key: ValueKey(
                'handrail-message-composer-cancel-${upload.handle.uploadId}',
              ),
              tooltip: 'Cancel attachment upload',
              onPressed: () => _cancelUpload(upload),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    ++_bindingGeneration;
    ++_draftGeneration;
    ++_mentionSearchGeneration;
    ++_mentionValidationGeneration;
    _draftTimer?.cancel();
    _typingTimer?.cancel();
    _stopTyping();
    _cancelUploads();
    _cancelBindingSubscriptions();
    unawaited(_replySubscription?.cancel());
    _hostTextController?.removeListener(_handleHostControllerChanged);
    _textController.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _textController.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }
}

final class _ComposerUpload {
  const _ComposerUpload({required this.handle});

  final HandrailMessageComposerUploadHandle handle;
}

final class _TrackedMention {
  _TrackedMention({
    required this.userId,
    required this.displayName,
    required this.start,
    required this.end,
  });

  final UserId userId;
  final String displayName;
  int start;
  int end;
  bool invalid = false;
}

enum _ComposerBlockType { unorderedList, orderedList, codeBlock }

final class _LinkEditResult {
  const _LinkEditResult({this.href, this.remove = false});

  final String? href;
  final bool remove;
}

final class _ComposerMarkRange {
  _ComposerMarkRange({
    required this.start,
    required this.end,
    required this.type,
    this.href,
  });

  int start;
  int end;
  final ComposerRichTextMarkType type;
  final String? href;

  _ComposerMarkRange copyWith({int? start, int? end}) => _ComposerMarkRange(
        start: start ?? this.start,
        end: end ?? this.end,
        type: type,
        href: href,
      );
}

final class _ComposerBlockRange {
  _ComposerBlockRange({
    required this.start,
    required this.end,
    required this.type,
    this.ordinal,
    this.language,
  });

  int start;
  int end;
  final _ComposerBlockType type;
  final int? ordinal;
  final String? language;
}

final class _ComposerTextRange {
  const _ComposerTextRange(this.start, this.end);

  final int start;
  final int end;
}

final class _ComposerLine {
  const _ComposerLine(this.start, this.end);

  final int start;
  final int end;
}

/// A TextField-compatible controller whose value remains delimiter-free.
///
/// Markdown syntax is held as editing metadata and is rendered by
/// [buildTextSpan]. This keeps selection, composing, and host-controller
/// behavior on Flutter's native editable-text path.
final class _ComposerTextEditingController extends TextEditingController {
  _ComposerTextEditingController({required TextEditingValue value})
      : super.fromValue(value);

  final List<_ComposerMarkRange> _marks = <_ComposerMarkRange>[];
  final List<_ComposerBlockRange> _blocks = <_ComposerBlockRange>[];
  Color _linkColor = Colors.blue;
  Color _codeBackgroundColor = const Color(0x1A000000);
  Color _listBackgroundColor = const Color(0x0D000000);

  void configureVisuals({
    required Color linkColor,
    required Color codeBackgroundColor,
    required Color listBackgroundColor,
  }) {
    _linkColor = linkColor;
    _codeBackgroundColor = codeBackgroundColor;
    _listBackgroundColor = listBackgroundColor;
  }

  void replaceWithPlainText(TextEditingValue nextValue) {
    _marks.clear();
    _blocks.clear();
    value = nextValue;
  }

  void replaceWithMarkdown(String markdown) {
    final document = composerMarkdownToRichTextDocument(markdown);
    final visible = StringBuffer();
    _marks.clear();
    _blocks.clear();

    for (var index = 0; index < document.blocks.length; index += 1) {
      final block = document.blocks[index];
      if (index > 0) {
        final previous = document.blocks[index - 1];
        final sameListKind = previous is ComposerRichTextUnorderedListItem &&
                block is ComposerRichTextUnorderedListItem ||
            previous is ComposerRichTextOrderedListItem &&
                block is ComposerRichTextOrderedListItem;
        visible.write(sameListKind ? '\n' : '\n\n');
      }
      final blockStart = visible.length;
      switch (block) {
        case ComposerRichTextParagraph(:final content):
          _appendRichSpans(visible, content);
        case ComposerRichTextUnorderedListItem(:final content):
          _appendRichSpans(visible, content);
          _blocks.add(_ComposerBlockRange(
            start: blockStart,
            end: visible.length,
            type: _ComposerBlockType.unorderedList,
          ));
        case ComposerRichTextOrderedListItem(:final ordinal, :final content):
          _appendRichSpans(visible, content);
          _blocks.add(_ComposerBlockRange(
            start: blockStart,
            end: visible.length,
            type: _ComposerBlockType.orderedList,
            ordinal: ordinal,
          ));
        case ComposerRichTextCodeBlock(:final text, :final language):
          visible.write(text);
          _blocks.add(_ComposerBlockRange(
            start: blockStart,
            end: visible.length,
            type: _ComposerBlockType.codeBlock,
            language: language,
          ));
      }
    }
    final text = visible.toString();
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _appendRichSpans(
    StringBuffer visible,
    List<ComposerRichTextSpan> spans,
  ) {
    for (final span in spans) {
      final start = visible.length;
      visible.write(span.text);
      final end = visible.length;
      for (final mark in span.marks) {
        _marks.add(_ComposerMarkRange(
          start: start,
          end: end,
          type: mark.type,
          href: mark.href,
        ));
      }
    }
  }

  bool get hasInlineSelection {
    final range = _normalizedSelection;
    return range != null && range.start < range.end;
  }

  bool get hasBlockSelection {
    final range = _selectedLineRange;
    return range != null && range.start < range.end;
  }

  _ComposerTextRange? get _normalizedSelection {
    final current = selection;
    if (!current.isValid) return null;
    final start = current.start.clamp(0, text.length);
    final end = current.end.clamp(0, text.length);
    return _ComposerTextRange(start, end);
  }

  _ComposerTextRange? get _selectedLineRange {
    final current = _normalizedSelection;
    if (current == null || text.isEmpty) return null;
    final selectionEnd = current.start == current.end
        ? current.end
        : (current.end - 1).clamp(current.start, text.length);
    final lineStart = text.lastIndexOf(
          '\n',
          (current.start - 1).clamp(0, text.length),
        ) +
        1;
    final newline = text.indexOf('\n', selectionEnd);
    final lineEnd = newline == -1 ? text.length : newline;
    return _ComposerTextRange(lineStart, lineEnd);
  }

  bool selectionHasMark(ComposerRichTextMarkType type) {
    final selected = _normalizedSelection;
    if (selected == null || selected.start == selected.end) {
      return _markAtCaret(type) != null;
    }
    var cursor = selected.start;
    final ranges = _marks
        .where((range) => range.type == type && range.end > selected.start)
        .toList()
      ..sort((left, right) => left.start.compareTo(right.start));
    for (final range in ranges) {
      if (range.start > cursor) return false;
      if (range.end > cursor) cursor = range.end;
      if (cursor >= selected.end) return true;
    }
    return false;
  }

  _ComposerMarkRange? _markAtCaret(ComposerRichTextMarkType type) {
    final current = _normalizedSelection;
    if (current == null || current.start != current.end) return null;
    final caret = current.start;
    for (final mark in _marks.reversed) {
      if (mark.type == type && mark.start <= caret && caret <= mark.end) {
        return mark;
      }
    }
    return null;
  }

  _ComposerMarkRange? get linkAtSelection {
    final selected = _normalizedSelection;
    if (selected == null) return null;
    for (final mark in _marks.reversed) {
      if (mark.type != ComposerRichTextMarkType.link) continue;
      if (selected.start == selected.end) {
        if (mark.start <= selected.start && selected.start <= mark.end) {
          return mark;
        }
      } else if (mark.start <= selected.start && mark.end >= selected.end) {
        return mark;
      }
    }
    return null;
  }

  TextSelection? get linkEditingSelection {
    final selected = _normalizedSelection;
    if (selected == null) return null;
    if (selected.start < selected.end) {
      return TextSelection(
          baseOffset: selected.start, extentOffset: selected.end);
    }
    final link = linkAtSelection;
    return link == null
        ? null
        : TextSelection(baseOffset: link.start, extentOffset: link.end);
  }

  bool toggleInlineMark(ComposerRichTextMarkType type) {
    final selected = _normalizedSelection;
    if (selected == null || selected.start == selected.end) return false;
    if (selectionHasMark(type)) {
      _removeMark(type, selected);
    } else {
      _marks.add(_ComposerMarkRange(
        start: selected.start,
        end: selected.end,
        type: type,
      ));
      _normalizeMarks();
    }
    notifyListeners();
    return true;
  }

  bool setLink(TextSelection target, String destination) {
    final href = sanitizeComposerMarkdownLink(destination);
    final start = target.start.clamp(0, text.length);
    final end = target.end.clamp(0, text.length);
    if (href == null || start >= end) return false;
    _removeMark(
      ComposerRichTextMarkType.link,
      _ComposerTextRange(start, end),
    );
    _marks.add(_ComposerMarkRange(
      start: start,
      end: end,
      type: ComposerRichTextMarkType.link,
      href: href,
    ));
    _normalizeMarks();
    selection = target;
    notifyListeners();
    return true;
  }

  bool removeLink(TextSelection target) {
    final before = _marks.length;
    _removeMark(
      ComposerRichTextMarkType.link,
      _ComposerTextRange(target.start, target.end),
    );
    if (_marks.length == before) return false;
    selection = target;
    notifyListeners();
    return true;
  }

  void _removeMark(
    ComposerRichTextMarkType type,
    _ComposerTextRange selected,
  ) {
    final replacement = <_ComposerMarkRange>[];
    for (final mark in _marks) {
      if (mark.type != type ||
          mark.end <= selected.start ||
          mark.start >= selected.end) {
        replacement.add(mark);
        continue;
      }
      if (mark.start < selected.start) {
        replacement.add(mark.copyWith(end: selected.start));
      }
      if (mark.end > selected.end) {
        replacement.add(mark.copyWith(start: selected.end));
      }
    }
    _marks
      ..clear()
      ..addAll(replacement);
    _normalizeMarks();
  }

  bool selectionHasBlock(_ComposerBlockType type) {
    final selected = _selectedLineRange;
    if (selected == null || selected.start == selected.end) return false;
    final lines = _linesIn(selected);
    return lines.isNotEmpty &&
        lines.every((line) {
          final block = _blockAt(line.start);
          return block?.type == type;
        });
  }

  bool toggleBlock(_ComposerBlockType type) {
    final selected = _selectedLineRange;
    if (selected == null || selected.start == selected.end) return false;
    final lines = _linesIn(selected);
    if (lines.isEmpty) return false;
    final remove = selectionHasBlock(type);
    _blocks.removeWhere(
      (block) => block.end > selected.start && block.start < selected.end,
    );
    if (!remove) {
      for (var index = 0; index < lines.length; index += 1) {
        final line = lines[index];
        _blocks.add(_ComposerBlockRange(
          start: line.start,
          end: line.end,
          type: type,
          ordinal: type == _ComposerBlockType.orderedList ? index + 1 : null,
        ));
      }
    }
    _blocks.sort((left, right) => left.start.compareTo(right.start));
    notifyListeners();
    return true;
  }

  List<_ComposerLine> _linesIn(_ComposerTextRange range) {
    final lines = <_ComposerLine>[];
    var start = range.start;
    while (start <= range.end && start < text.length) {
      final newline = text.indexOf('\n', start);
      final end = newline == -1 || newline > range.end ? range.end : newline;
      if (end > start) lines.add(_ComposerLine(start, end));
      if (newline == -1 || newline >= range.end) break;
      start = newline + 1;
    }
    return lines;
  }

  _ComposerBlockRange? _blockAt(int offset) {
    for (final block in _blocks.reversed) {
      if (block.start <= offset && offset < block.end) return block;
    }
    return null;
  }

  void reconcileTextEdit(String oldText, String newText) {
    if (oldText == newText) return;
    var prefix = 0;
    final shortest =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (prefix < shortest &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < oldText.length - prefix &&
        suffix < newText.length - prefix &&
        oldText.codeUnitAt(oldText.length - suffix - 1) ==
            newText.codeUnitAt(newText.length - suffix - 1)) {
      suffix += 1;
    }
    final oldEnd = oldText.length - suffix;
    final newEnd = newText.length - suffix;
    final delta = newText.length - oldText.length;

    void transformRange(dynamic range) {
      if (range.end <= prefix) return;
      if (range.start >= oldEnd) {
        range.start += delta;
        range.end += delta;
        return;
      }
      if (range.start > prefix) range.start = prefix;
      if (range.end >= oldEnd) {
        range.end += delta;
      } else {
        range.end = newEnd;
      }
    }

    for (final mark in _marks) {
      transformRange(mark);
    }
    for (final block in _blocks) {
      transformRange(block);
    }
    _marks.removeWhere((mark) => mark.start >= mark.end);
    _blocks.removeWhere((block) => block.start >= block.end);
    _normalizeMarks();
  }

  void _normalizeMarks() {
    _marks.sort((left, right) {
      final start = left.start.compareTo(right.start);
      if (start != 0) return start;
      final type = left.type.index.compareTo(right.type.index);
      if (type != 0) return type;
      return (left.href ?? '').compareTo(right.href ?? '');
    });
    final normalized = <_ComposerMarkRange>[];
    for (final mark in _marks) {
      final previous = normalized.isEmpty ? null : normalized.last;
      if (previous != null &&
          previous.type == mark.type &&
          previous.href == mark.href &&
          mark.start <= previous.end) {
        if (mark.end > previous.end) previous.end = mark.end;
      } else {
        normalized.add(mark);
      }
    }
    _marks
      ..clear()
      ..addAll(normalized);
  }

  String get canonicalMarkdown =>
      richTextDocumentToCanonicalMarkdown(_toDocument());

  ComposerRichTextDocument _toDocument() {
    if (text.isEmpty) return ComposerRichTextDocument();
    final lines = <_ComposerLine>[];
    var start = 0;
    while (start <= text.length) {
      final newline = text.indexOf('\n', start);
      if (newline == -1) {
        lines.add(_ComposerLine(start, text.length));
        break;
      }
      lines.add(_ComposerLine(start, newline));
      start = newline + 1;
      if (start == text.length) {
        lines.add(_ComposerLine(start, start));
        break;
      }
    }

    final result = <ComposerRichTextBlock>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      if (line.start == line.end) {
        index += 1;
        continue;
      }
      final block = _blockAt(line.start);
      if (block?.type == _ComposerBlockType.codeBlock) {
        final first = index;
        var language = block?.language;
        while (index + 1 < lines.length &&
            lines[index + 1].start < lines[index + 1].end &&
            _blockAt(lines[index + 1].start)?.type ==
                _ComposerBlockType.codeBlock) {
          index += 1;
          language ??= _blockAt(lines[index].start)?.language;
        }
        result.add(ComposerRichTextCodeBlock(
          text: text.substring(lines[first].start, lines[index].end),
          language: language,
        ));
        index += 1;
        continue;
      }
      if (block?.type == _ComposerBlockType.unorderedList) {
        result.add(ComposerRichTextUnorderedListItem(
          content: _inlineContent(line.start, line.end),
        ));
        index += 1;
        continue;
      }
      if (block?.type == _ComposerBlockType.orderedList) {
        result.add(ComposerRichTextOrderedListItem(
          ordinal: block?.ordinal ?? 1,
          content: _inlineContent(line.start, line.end),
        ));
        index += 1;
        continue;
      }

      final first = index;
      while (index + 1 < lines.length &&
          lines[index + 1].start < lines[index + 1].end &&
          _blockAt(lines[index + 1].start) == null) {
        index += 1;
      }
      result.add(ComposerRichTextParagraph(
        content: _inlineContent(lines[first].start, lines[index].end),
      ));
      index += 1;
    }
    return ComposerRichTextDocument(blocks: result);
  }

  List<ComposerRichTextSpan> _inlineContent(int start, int end) {
    final boundaries = <int>{start, end};
    for (final mark in _marks) {
      if (mark.end <= start || mark.start >= end) continue;
      boundaries
        ..add(mark.start.clamp(start, end))
        ..add(mark.end.clamp(start, end));
    }
    final ordered = boundaries.toList()..sort();
    final spans = <ComposerRichTextSpan>[];
    for (var index = 0; index + 1 < ordered.length; index += 1) {
      final spanStart = ordered[index];
      final spanEnd = ordered[index + 1];
      if (spanStart == spanEnd) continue;
      final marks = <ComposerRichTextMark>[
        for (final range in _marks)
          if (range.start <= spanStart && range.end >= spanEnd)
            switch (range.type) {
              ComposerRichTextMarkType.bold =>
                const ComposerRichTextMark.bold(),
              ComposerRichTextMarkType.italic =>
                const ComposerRichTextMark.italic(),
              ComposerRichTextMarkType.strikethrough =>
                const ComposerRichTextMark.strikethrough(),
              ComposerRichTextMarkType.code =>
                const ComposerRichTextMark.code(),
              ComposerRichTextMarkType.link =>
                ComposerRichTextMark.link(range.href ?? ''),
            },
      ];
      spans.add(ComposerRichTextSpan(
        text: text.substring(spanStart, spanEnd),
        marks: marks,
      ));
    }
    return spans;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final boundaries = <int>{0, text.length};
    for (final mark in _marks) {
      boundaries
        ..add(mark.start.clamp(0, text.length))
        ..add(mark.end.clamp(0, text.length));
    }
    for (final block in _blocks) {
      boundaries
        ..add(block.start.clamp(0, text.length))
        ..add(block.end.clamp(0, text.length));
    }
    final composing = value.composing;
    if (withComposing && composing.isValid && !composing.isCollapsed) {
      boundaries
        ..add(composing.start.clamp(0, text.length))
        ..add(composing.end.clamp(0, text.length));
    }
    final ordered = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    for (var index = 0; index + 1 < ordered.length; index += 1) {
      final start = ordered[index];
      final end = ordered[index + 1];
      if (start == end) continue;
      var segmentStyle = const TextStyle();
      for (final mark in _marks) {
        if (mark.start > start || mark.end < end) continue;
        segmentStyle = segmentStyle.merge(switch (mark.type) {
          ComposerRichTextMarkType.bold =>
            const TextStyle(fontWeight: FontWeight.bold),
          ComposerRichTextMarkType.italic =>
            const TextStyle(fontStyle: FontStyle.italic),
          ComposerRichTextMarkType.strikethrough =>
            const TextStyle(decoration: TextDecoration.lineThrough),
          ComposerRichTextMarkType.code => TextStyle(
              fontFamily: 'monospace',
              backgroundColor: _codeBackgroundColor,
            ),
          ComposerRichTextMarkType.link => TextStyle(
              color: _linkColor,
              decoration: TextDecoration.underline,
            ),
        });
      }
      final block = _blockAt(start);
      if (block != null) {
        segmentStyle = segmentStyle.merge(
          block.type == _ComposerBlockType.codeBlock
              ? TextStyle(
                  fontFamily: 'monospace',
                  backgroundColor: _codeBackgroundColor,
                )
              : TextStyle(backgroundColor: _listBackgroundColor),
        );
      }
      if (withComposing &&
          composing.isValid &&
          composing.start <= start &&
          composing.end >= end) {
        segmentStyle = segmentStyle.merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      children.add(TextSpan(
        text: text.substring(start, end),
        style: segmentStyle,
      ));
    }
    return TextSpan(style: style, children: children);
  }
}

Future<HandrailMemberDirectoryRow?> _resolveMentionUser(
  HandrailMessageMentionResolver resolver,
  UserId userId,
) async {
  try {
    return await resolver(userId);
  } catch (_) {
    return null;
  }
}

final class _ActiveMentionToken {
  const _ActiveMentionToken({
    required this.start,
    required this.caret,
    required this.end,
    required this.query,
    required this.signature,
  });

  final int start;
  final int caret;
  final int end;
  final String query;
  final String signature;
}

_ActiveMentionToken? _activeMention(TextEditingValue value) {
  final selection = value.selection;
  final composing = value.composing;
  if (!selection.isValid ||
      !selection.isCollapsed ||
      (composing.isValid && !composing.isCollapsed)) {
    return null;
  }
  final text = value.text;
  final caret = selection.extentOffset;
  if (caret < 0 || caret > text.length) return null;
  var at = -1;
  for (var index = caret - 1; index >= 0; index -= 1) {
    final character = text.substring(index, index + 1);
    if (_isWhitespace(character)) break;
    if (character == '@') {
      at = index;
      break;
    }
  }
  if (at < 0 || (at > 0 && !_isMentionLeadingBoundary(text, at))) {
    return null;
  }
  final query = text.substring(at + 1, caret);
  if (query.contains('@')) return null;
  var end = caret;
  while (end < text.length && !_isWhitespace(text.substring(end, end + 1))) {
    end += 1;
  }
  return _ActiveMentionToken(
    start: at,
    caret: caret,
    end: end,
    query: query,
    signature: '$at:$caret:$end:${text.hashCode}:$query',
  );
}

(int, int)? _findMentionRange(
  String text,
  String displayName,
  List<(int, int)> occupied,
) {
  final token = '@$displayName';
  var start = 0;
  while (start <= text.length - token.length) {
    final match = text.indexOf(token, start);
    if (match < 0) return null;
    final end = match + token.length;
    final overlaps = occupied.any(
      (range) => match < range.$2 && end > range.$1,
    );
    if (!overlaps && _hasMentionBoundaries(text, match, end)) {
      return (match, end);
    }
    start = match + 1;
  }
  return null;
}

bool _hasMentionBoundaries(String text, int start, int end) {
  if (start > 0 && !_isMentionLeadingBoundary(text, start)) return false;
  if (end == text.length) return true;
  final next = text.substring(end, end + 1);
  return _isWhitespace(next) || _mentionTrailingPunctuation.contains(next);
}

bool _isMentionLeadingBoundary(String text, int at) {
  final previous = text.substring(at - 1, at);
  return _isWhitespace(previous) ||
      _mentionLeadingPunctuation.contains(previous);
}

bool _isWhitespace(String character) =>
    RegExp(r'\s', unicode: true).hasMatch(character);

const _mentionLeadingPunctuation = <String>{
  '(',
  '[',
  '{',
  '<',
  '"',
  "'",
  ',',
  ';',
  ':',
  '!',
  '?',
};

const _mentionTrailingPunctuation = <String>{
  ')',
  ']',
  '}',
  '>',
  '"',
  "'",
  ',',
  '.',
  ';',
  ':',
  '!',
  '?',
};

final class _ControllerComposerUploadHandle
    implements HandrailMessageComposerUploadHandle {
  const _ControllerComposerUploadHandle(this._handle);

  final ChatAttachmentUploadHandle _handle;

  @override
  Future<ChatAttachmentUploadResult> get completion => _handle.completion;

  @override
  ChatAttachmentUploadState get state => _handle.state;

  @override
  String get uploadId => _handle.uploadId;

  @override
  void cancel() => _handle.cancel();
}

DraftTextFormat _draftFormat(MessageContentFormat format) => switch (format) {
      MessageContentFormat.plain => DraftTextFormat.plain,
      MessageContentFormat.markdown => DraftTextFormat.markdown,
    };

MessageContentFormat _messageFormat(DraftTextFormat format) => switch (format) {
      DraftTextFormat.plain => MessageContentFormat.plain,
      DraftTextFormat.markdown => MessageContentFormat.markdown,
    };

bool _sameDraft(DraftContent left, DraftContent right) {
  final leftMentions = left.mentions ?? const <MessageMention>[];
  final rightMentions = right.mentions ?? const <MessageMention>[];
  if (left.format != right.format ||
      left.text != right.text ||
      left.replyTo?.messageId != right.replyTo?.messageId ||
      left.replyTo?.notifyAuthor != right.replyTo?.notifyAuthor ||
      leftMentions.length != rightMentions.length ||
      left.attachments.length != right.attachments.length) {
    return false;
  }
  for (var index = 0; index < leftMentions.length; index += 1) {
    if (jsonEncode(leftMentions[index].toJson()) !=
        jsonEncode(rightMentions[index].toJson())) {
      return false;
    }
  }
  for (var index = 0; index < left.attachments.length; index += 1) {
    if (left.attachments[index].attachmentId !=
        right.attachments[index].attachmentId) {
      return false;
    }
  }
  return true;
}

final class _ComposerSubmission {
  _ComposerSubmission(
      {required this.client, required this.input, required this.draft})
      : actor = (
          client.replyStyles.state.identity?.tenantId,
          client.replyStyles.state.identity?.userId,
        );
  final HandrailChatClient client;
  final ChatSendMessageInput input;
  final DraftContent draft;
  final (TenantId?, UserId?) actor;
  bool get hasCurrentActor =>
      actor ==
      (
        client.replyStyles.state.identity?.tenantId,
        client.replyStyles.state.identity?.userId,
      );
  ApplicationChatStorageIdentity? identity;
  bool identityCaptured = false;
  bool identityChanged = false;
}
