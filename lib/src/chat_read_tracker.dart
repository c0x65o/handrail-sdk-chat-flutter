import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core.dart';
import 'chat_scope.dart';

/// One keyed message row observed by [ChatReadTracker].
///
/// Put [key] on the widget whose painted bounds represent the message row.
/// Global keys make the contract independent of any particular scrollable,
/// sliver, or state-management implementation.
@immutable
final class ChatReadTrackedItem {
  const ChatReadTrackedItem({
    required this.key,
    required this.sequence,
  });

  final GlobalKey key;
  final MessageSequence sequence;
}

/// Geometry supplied to a host visibility policy.
@immutable
final class ChatReadVisibilityDetails {
  const ChatReadVisibilityDetails({
    required this.trackerContext,
    required this.item,
    required this.itemContext,
    required this.paintBounds,
    required this.visibleBounds,
    required this.visibleFraction,
  });

  final BuildContext trackerContext;
  final ChatReadTrackedItem item;

  /// The keyed row's current context, or `null` when it is not mounted.
  final BuildContext? itemContext;

  /// The row's global painted bounds, before ancestor viewport clipping.
  final Rect? paintBounds;

  /// [paintBounds] intersected with every ancestor paint clip.
  ///
  /// This includes each enclosing viewport, so nested scrollables are clipped
  /// by both their inner and outer viewports.
  final Rect? visibleBounds;

  /// The visible painted area divided by the row's painted area.
  final double visibleFraction;
}

/// Decides whether a measured row counts as visible.
///
/// The tracker still owns sequence selection and coordinator reporting. This
/// delegate only lets a host refine visibility for unusual renderers.
typedef ChatReadVisibilityDelegate = bool Function(
  ChatReadVisibilityDetails details,
);

/// Imperative sampling hook for timelines whose visibility changes without a
/// Flutter scroll notification or rebuild.
final class ChatReadTrackerController {
  _ChatReadTrackerState? _state;

  bool get isAttached => _state != null;

  /// Measures the keyed rows after the next rendered frame.
  void sampleVisibility() => _state?._scheduleVisibilitySample();

  void _attach(_ChatReadTrackerState state) {
    final current = _state;
    if (current != null && !identical(current, state)) {
      throw FlutterError(
        'A ChatReadTrackerController cannot be attached to multiple trackers.',
      );
    }
    _state = state;
  }

  void _detach(_ChatReadTrackerState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// Adapts a custom Flutter timeline to the public read-visibility contract.
///
/// By default the coordinator comes from the nearest [ChatScope]. Pass [reads]
/// when the host already owns the public coordinator directly. The widget
/// never invokes `markRead`; it reports only through
/// [ChatReadVisibilityCoordinator].
final class ChatReadTracker extends StatefulWidget {
  const ChatReadTracker({
    required this.conversationId,
    required this.items,
    required this.child,
    this.controller,
    this.reads,
    this.visibilityDelegate,
    this.minimumVisibleFraction = 0,
    this.isConversationActive = true,
    super.key,
  }) : assert(
          minimumVisibleFraction >= 0 && minimumVisibleFraction <= 1,
          'minimumVisibleFraction must be between zero and one.',
        );

  final ConversationId conversationId;
  final List<ChatReadTrackedItem> items;
  final Widget child;
  final ChatReadTrackerController? controller;

  /// An explicit public coordinator; otherwise [ChatScope] supplies one.
  final ChatReadVisibilityCoordinator? reads;

  /// Optional host policy applied to the tracker's viewport-aware geometry.
  final ChatReadVisibilityDelegate? visibilityDelegate;

  /// Minimum painted area required for the default visibility policy.
  ///
  /// Zero still requires at least one painted pixel to be visible.
  final double minimumVisibleFraction;

  /// Whether this conversation is the one actively presented by the host.
  final bool isConversationActive;

  @override
  State<ChatReadTracker> createState() => _ChatReadTrackerState();
}

final class _ChatReadTrackerState extends State<ChatReadTracker>
    with WidgetsBindingObserver {
  ChatReadVisibilityCoordinator? _reads;
  var _sampleScheduled = false;
  var _disposed = false;
  var _activeScrolls = 0;
  Duration? _lastScrollTimestamp;
  final Stopwatch _scrollClock = Stopwatch();
  Duration _lastScrollElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._attach(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.reads ?? ChatScope.of(context).client.reads;
    if (!identical(_reads, next)) {
      if (widget.isConversationActive) {
        _reads?.setConversationActive(
          widget.conversationId,
          isActive: false,
        );
      }
      _reads = next;
      next
        ..setApplicationForeground(_isApplicationForeground)
        ..setConversationActive(
          widget.conversationId,
          isActive: widget.isConversationActive,
        );
    }
    _scheduleVisibilitySample();
  }

  @override
  void didUpdateWidget(ChatReadTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }

    final next = widget.reads ?? ChatScope.of(context).client.reads;
    final coordinatorChanged = !identical(_reads, next);
    final conversationChanged =
        oldWidget.conversationId != widget.conversationId;
    final activityChanged =
        oldWidget.isConversationActive != widget.isConversationActive;
    if ((coordinatorChanged || conversationChanged || activityChanged) &&
        oldWidget.isConversationActive) {
      _reads?.setConversationActive(
        oldWidget.conversationId,
        isActive: false,
      );
    }
    if (coordinatorChanged) {
      _reads = next;
      next.setApplicationForeground(_isApplicationForeground);
    }
    if ((coordinatorChanged || conversationChanged || activityChanged) &&
        widget.isConversationActive) {
      next.setConversationActive(
        widget.conversationId,
        isActive: true,
      );
    }

    if (!coordinatorChanged && !conversationChanged) {
      _reportRemovedRows(oldWidget.items, widget.items);
    }
    _scheduleVisibilitySample();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _reads?.setApplicationForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) _scheduleVisibilitySample();
  }

  bool get _isApplicationForeground {
    final state = SchedulerBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _reportRemovedRows(
    List<ChatReadTrackedItem> previous,
    List<ChatReadTrackedItem> current,
  ) {
    final currentEntries = <GlobalKey, MessageSequence>{
      for (final item in current) item.key: item.sequence,
    };
    final currentSequences = current.map((item) => item.sequence).toSet();
    for (final oldItem in previous) {
      if (currentEntries[oldItem.key] == oldItem.sequence ||
          currentSequences.contains(oldItem.sequence)) {
        continue;
      }
      _reads?.reportSequenceDeleted(
        conversationId: widget.conversationId,
        sequence: oldItem.sequence,
      );
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_disposed || _reads == null) return false;
    switch (notification) {
      case ScrollStartNotification(:final dragDetails):
        _activeScrolls += 1;
        _lastScrollTimestamp = dragDetails?.sourceTimeStamp;
        _scrollClock
          ..reset()
          ..start();
        _lastScrollElapsed = Duration.zero;
        _reportScroll(velocity: 0, isSettled: false);
      case ScrollUpdateNotification(:final dragDetails, :final scrollDelta):
        final velocity = _scrollVelocity(
          scrollDelta ?? 0,
          dragDetails?.sourceTimeStamp,
        );
        _reportScroll(velocity: velocity, isSettled: false);
        _scheduleVisibilitySample();
      case OverscrollNotification(
          :final dragDetails,
          :final overscroll,
        ):
        final velocity = _scrollVelocity(
          overscroll,
          dragDetails?.sourceTimeStamp,
        );
        _reportScroll(velocity: velocity, isSettled: false);
        _scheduleVisibilitySample();
      case ScrollEndNotification():
        _activeScrolls = math.max(0, _activeScrolls - 1);
        if (_activeScrolls == 0) {
          _scrollClock.stop();
          _lastScrollTimestamp = null;
          _reportScroll(velocity: 0, isSettled: true);
          _scheduleVisibilitySample();
        }
      default:
        break;
    }
    return false;
  }

  double _scrollVelocity(double delta, Duration? sourceTimestamp) {
    Duration elapsed;
    if (sourceTimestamp != null && _lastScrollTimestamp != null) {
      elapsed = sourceTimestamp - _lastScrollTimestamp!;
      _lastScrollTimestamp = sourceTimestamp;
    } else {
      if (!_scrollClock.isRunning) _scrollClock.start();
      final now = _scrollClock.elapsed;
      elapsed = now - _lastScrollElapsed;
      _lastScrollElapsed = now;
    }
    if (elapsed <= Duration.zero) {
      elapsed = const Duration(milliseconds: 16);
    }
    return delta * Duration.microsecondsPerSecond / elapsed.inMicroseconds;
  }

  void _reportScroll({required double velocity, required bool isSettled}) {
    _reads?.reportScrollActivity(
      conversationId: widget.conversationId,
      velocity: velocity,
      isSettled: isSettled,
    );
  }

  void _scheduleVisibilitySample() {
    if (_disposed || _sampleScheduled) return;
    _sampleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sampleScheduled = false;
      if (_disposed || !mounted) return;
      _sampleVisibility();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _sampleVisibility() {
    if (!widget.isConversationActive) return;
    MessageSequence? highest;
    for (final item in widget.items) {
      final details = _measure(item);
      final visible = widget.visibilityDelegate?.call(details) ??
          (details.visibleFraction > 0 &&
              details.visibleFraction >= widget.minimumVisibleFraction);
      if (visible && (highest == null || item.sequence.value > highest.value)) {
        highest = item.sequence;
      }
    }
    if (highest == null) return;
    _reads?.reportVisibleThrough(
      conversationId: widget.conversationId,
      sequence: highest,
    );
  }

  ChatReadVisibilityDetails _measure(ChatReadTrackedItem item) {
    final itemContext = item.key.currentContext;
    final renderObject = itemContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) {
      return ChatReadVisibilityDetails(
        trackerContext: context,
        item: item,
        itemContext: itemContext,
        paintBounds: null,
        visibleBounds: null,
        visibleFraction: 0,
      );
    }

    final transform = renderObject.getTransformTo(null);
    final paintBounds = MatrixUtils.transformRect(
      transform,
      renderObject.paintBounds,
    );
    var visibleBounds = paintBounds;
    RenderObject child = renderObject;
    RenderObject? ancestor = child.parent;
    while (ancestor != null) {
      final clip = ancestor.describeApproximatePaintClip(child);
      if (clip != null) {
        final globalClip = MatrixUtils.transformRect(
          ancestor.getTransformTo(null),
          clip,
        );
        visibleBounds = visibleBounds.intersect(globalClip);
      }
      child = ancestor;
      ancestor = ancestor.parent;
    }

    final paintArea = paintBounds.width * paintBounds.height;
    final visibleArea = visibleBounds.width > 0 && visibleBounds.height > 0
        ? visibleBounds.width * visibleBounds.height
        : 0.0;
    final visibleFraction =
        paintArea > 0 ? (visibleArea / paintArea).clamp(0.0, 1.0) : 0.0;
    return ChatReadVisibilityDetails(
      trackerContext: context,
      item: item,
      itemContext: itemContext,
      paintBounds: paintBounds,
      visibleBounds: visibleArea > 0 ? visibleBounds : null,
      visibleFraction: visibleFraction,
    );
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: widget.child,
      );

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detach(this);
    if (widget.isConversationActive) {
      _reads?.setConversationActive(
        widget.conversationId,
        isActive: false,
      );
    }
    super.dispose();
  }
}
