import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'chat_widget_builders.dart';
import 'handrail_chat_theme.dart';

/// One host-configured reaction that may be shown by
/// [HandrailReactionPicker].
@immutable
final class HandrailReactionOption {
  const HandrailReactionOption({
    required this.reactionKey,
    required this.label,
    this.semanticLabel,
  })  : assert(reactionKey != ''),
        assert(label != '');

  /// Stable reaction identifier sent unchanged to the public chat command.
  final String reactionKey;

  /// Short visual label, commonly an emoji.
  final String label;

  /// Spoken description. Falls back to [label] when omitted.
  final String? semanticLabel;
}

/// An inline, host-placeable reaction chooser for one message.
///
/// The picker deliberately owns no overlay, dialog, route, or placement
/// policy. A host may embed it inline or place it inside a host-owned surface.
/// Mutations are delegated only through the public [ChatMessageActions]
/// adapter backed by [ChatTimelineController.setReaction].
class HandrailReactionPicker extends StatefulWidget {
  const HandrailReactionPicker({
    required this.actions,
    required this.availableReactions,
    required this.reactionAggregates,
    this.capabilityEnabled = true,
    this.enabled = true,
    this.maxVisibleReactions = defaultMaxVisibleReactions,
    this.autofocus = false,
    this.capabilityDisabledMessage = 'Reactions are unavailable.',
    this.failureMessage = 'Reaction could not be updated. Try again.',
    super.key,
  })  : assert(maxVisibleReactions > 0),
        assert(maxVisibleReactions <= maximumVisibleReactions);

  /// Default upper bound applied to the host's configured set.
  static const int defaultMaxVisibleReactions = 12;

  /// Absolute defensive bound for one picker instance.
  static const int maximumVisibleReactions = 24;

  /// Public message actions supplied by a timeline/message builder.
  final ChatMessageActions actions;

  /// Host-owned ordered set. Duplicate keys are ignored after the first.
  final List<HandrailReactionOption> availableReactions;

  /// Immutable public reaction state for the message.
  final List<MessageReactionAggregate> reactionAggregates;

  /// Whether negotiated chat capabilities permit reaction mutations.
  final bool capabilityEnabled;

  /// Additional host-controlled interaction gate.
  final bool enabled;

  /// Number of distinct configured reactions rendered from the start of
  /// [availableReactions]. This is capped by [maximumVisibleReactions].
  final int maxVisibleReactions;

  /// Requests initial focus for the first visible reaction.
  final bool autofocus;

  /// Non-sensitive feedback shown when the capability is unavailable.
  final String capabilityDisabledMessage;

  /// Non-sensitive feedback shown after any command failure.
  final String failureMessage;

  @override
  State<HandrailReactionPicker> createState() => _HandrailReactionPickerState();
}

class _HandrailReactionPickerState extends State<HandrailReactionPicker> {
  final Map<String, bool> _confirmedSelections = <String, bool>{};
  final Map<String, bool> _desiredSelections = <String, bool>{};
  final Map<String, int> _confirmedCounts = <String, int>{};
  final Map<String, FocusNode> _focusNodes = <String, FocusNode>{};
  final Set<String> _activeKeys = <String>{};
  final Set<String> _failedKeys = <String>{};
  var _bindingGeneration = 0;
  var _disposed = false;

  bool get _canInteract => widget.capabilityEnabled && widget.enabled;

  @override
  void initState() {
    super.initState();
    _synchronizeConfiguration(reset: true);
  }

  @override
  void didUpdateWidget(covariant HandrailReactionPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedMessage =
        oldWidget.actions.messageId != widget.actions.messageId;
    if (changedMessage) _bindingGeneration += 1;
    _synchronizeConfiguration(reset: changedMessage);
  }

  List<HandrailReactionOption> _visibleOptions() {
    final seen = <String>{};
    final visible = <HandrailReactionOption>[];
    for (final option in widget.availableReactions) {
      if (!seen.add(option.reactionKey)) continue;
      visible.add(option);
      if (visible.length == widget.maxVisibleReactions) break;
    }
    return visible;
  }

  Map<String, MessageReactionAggregate> _aggregateByKey() => {
        for (final aggregate in widget.reactionAggregates)
          aggregate.reactionKey: aggregate,
      };

  void _synchronizeConfiguration({required bool reset}) {
    if (reset) {
      _confirmedSelections.clear();
      _desiredSelections.clear();
      _confirmedCounts.clear();
      _activeKeys.clear();
      _failedKeys.clear();
    }

    final aggregates = _aggregateByKey();
    final visibleKeys = <String>{};
    for (final option in _visibleOptions()) {
      final key = option.reactionKey;
      visibleKeys.add(key);
      _focusNodes.putIfAbsent(
        key,
        () => FocusNode(debugLabel: 'Handrail reaction $key'),
      );
      if (_activeKeys.contains(key)) continue;
      final aggregate = aggregates[key];
      final selected = aggregate?.reactedByCurrentUser ?? false;
      _confirmedSelections[key] = selected;
      _desiredSelections[key] = selected;
      _confirmedCounts[key] = aggregate?.count ?? 0;
      _failedKeys.remove(key);
    }

    final removedKeys = _focusNodes.keys
        .where((key) => !visibleKeys.contains(key))
        .toList(growable: false);
    for (final key in removedKeys) {
      _focusNodes.remove(key)?.dispose();
      if (!_activeKeys.contains(key)) {
        _confirmedSelections.remove(key);
        _desiredSelections.remove(key);
        _confirmedCounts.remove(key);
        _failedKeys.remove(key);
      }
    }
  }

  void _activate(String reactionKey) {
    if (!_canInteract || _disposed) return;
    final current = _desiredSelections[reactionKey] ?? false;
    final alreadyActive = _activeKeys.contains(reactionKey);
    setState(() {
      _desiredSelections[reactionKey] = !current;
      _failedKeys.remove(reactionKey);
      _activeKeys.add(reactionKey);
    });
    if (!alreadyActive) {
      unawaited(_drain(reactionKey, _bindingGeneration));
    }
  }

  Future<void> _drain(String reactionKey, int bindingGeneration) async {
    // One drain owns each key. Further activations only update the desired
    // state and are observed by this loop after the in-flight command settles.
    while (!_disposed && bindingGeneration == _bindingGeneration) {
      final confirmed = _confirmedSelections[reactionKey] ?? false;
      final desired = _desiredSelections[reactionKey] ?? confirmed;
      if (desired == confirmed) break;

      ChatCommandResult<ReactionMutationResult> result;
      try {
        result = await widget.actions.setReaction(
          reactionKey: reactionKey,
          reactedByCurrentUser: desired,
        );
      } catch (_) {
        if (_disposed || !mounted) return;
        setState(() {
          _desiredSelections[reactionKey] = confirmed;
          _failedKeys.add(reactionKey);
        });
        break;
      }
      if (_disposed || !mounted || bindingGeneration != _bindingGeneration) {
        return;
      }

      if (result
          case ChatCommandSuccess<ReactionMutationResult>(:final value)) {
        setState(() {
          _confirmedSelections[reactionKey] = value.reactedByCurrentUser;
          _confirmedCounts[reactionKey] = value.count;
        });
      } else if (result is ChatCommandQueued<ReactionMutationResult>) {
        setState(() {
          _confirmedSelections[reactionKey] = desired;
          _confirmedCounts[reactionKey] = _optimisticCount(
            reactionKey,
            desired: desired,
            confirmed: confirmed,
          );
        });
      } else {
        setState(() {
          _desiredSelections[reactionKey] = confirmed;
          _failedKeys.add(reactionKey);
        });
        break;
      }
    }

    if (!_disposed && mounted && bindingGeneration == _bindingGeneration) {
      setState(() => _activeKeys.remove(reactionKey));
    }
  }

  int _optimisticCount(
    String reactionKey, {
    required bool desired,
    required bool confirmed,
  }) {
    final count = _confirmedCounts[reactionKey] ?? 0;
    if (desired == confirmed) return count;
    final adjusted = count + (desired ? 1 : -1);
    return adjusted < 0 ? 0 : adjusted;
  }

  @override
  Widget build(BuildContext context) {
    final chatTheme = HandrailChatTheme.of(context);
    final options = _visibleOptions();

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        key: const ValueKey('handrail-reaction-picker'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: chatTheme.spacing.small,
            runSpacing: chatTheme.spacing.extraSmall,
            children: [
              for (var index = 0; index < options.length; index += 1)
                _buildReaction(context, options[index], index),
            ],
          ),
          if (!widget.capabilityEnabled) ...[
            SizedBox(height: chatTheme.spacing.extraSmall),
            Semantics(
              label: widget.capabilityDisabledMessage,
              child: Text(
                widget.capabilityDisabledMessage,
                key: const ValueKey(
                  'handrail-reaction-picker-capability-disabled',
                ),
                style: chatTheme.typography.metadata,
              ),
            ),
          ],
          if (_failedKeys.isNotEmpty) ...[
            SizedBox(height: chatTheme.spacing.extraSmall),
            Semantics(
              liveRegion: true,
              label: widget.failureMessage,
              child: ExcludeSemantics(
                child: Text(
                  widget.failureMessage,
                  key: const ValueKey('handrail-reaction-picker-error'),
                  style: chatTheme.typography.metadata.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReaction(
    BuildContext context,
    HandrailReactionOption option,
    int index,
  ) {
    final key = option.reactionKey;
    final confirmed = _confirmedSelections[key] ?? false;
    final selected = _desiredSelections[key] ?? confirmed;
    final count = _optimisticCount(
      key,
      desired: selected,
      confirmed: confirmed,
    );
    final pending = _activeKeys.contains(key);
    final failed = _failedKeys.contains(key);
    final spokenLabel = option.semanticLabel ?? option.label;
    final stateLabel = selected ? 'selected' : 'not selected';
    final countLabel = count == 1 ? '1 reaction' : '$count reactions';
    final statusLabel = pending
        ? ', update pending'
        : failed
            ? ', update failed'
            : '';

    return FocusTraversalOrder(
      order: NumericFocusOrder(index.toDouble()),
      child: Semantics(
        container: true,
        button: true,
        enabled: _canInteract,
        selected: selected,
        label: '$spokenLabel, $stateLabel, $countLabel$statusLabel',
        hint: _canInteract
            ? 'Activate to ${selected ? 'remove' : 'add'} reaction'
            : widget.capabilityDisabledMessage,
        onTap: _canInteract ? () => _activate(key) : null,
        child: ExcludeSemantics(
          child: FilterChip(
            key: ValueKey('handrail-reaction-$key'),
            focusNode: _focusNodes[key],
            autofocus: widget.autofocus && index == 0,
            selected: selected,
            onSelected: _canInteract ? (_) => _activate(key) : null,
            avatar: pending
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : failed
                    ? Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      )
                    : null,
            label: Text(count == 0 ? option.label : '${option.label} $count'),
            tooltip: spokenLabel,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    _focusNodes.clear();
    super.dispose();
  }
}
