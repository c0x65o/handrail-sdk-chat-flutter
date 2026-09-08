import 'dart:async';
import 'dart:collection';

import '../../media.dart';

/// One recorded provider operation. Its string form contains no descriptors.
final class FakeChatMediaOperationCall {
  const FakeChatMediaOperationCall(
    this.operation, {
    this.enabled,
    this.deviceId,
  });

  final ChatMediaOperation operation;
  final bool? enabled;
  final String? deviceId;

  @override
  String toString() => 'FakeChatMediaOperationCall('
      'operation: ${operation.name}, enabled: $enabled, '
      'hasDeviceId: ${deviceId != null})';
}

/// A controllable provider-neutral media session.
final class FakeChatMediaProviderSession implements ChatMediaProviderSession {
  FakeChatMediaProviderSession({ChatMediaProviderState? initialState})
      : _initialState = initialState ??
            ChatMediaProviderState(
              devices: ChatMediaDeviceState(
                devices: const <ChatMediaDevice>[],
              ),
            );

  final ChatMediaProviderState _initialState;
  final StreamController<ChatMediaDeviceState> _deviceChanges =
      StreamController<ChatMediaDeviceState>.broadcast(sync: true);
  final StreamController<List<ChatMediaActiveSpeaker>> _speakerChanges =
      StreamController<List<ChatMediaActiveSpeaker>>.broadcast(sync: true);
  final Map<ChatMediaOperation, Queue<_MediaFailureScript>> _failures =
      <ChatMediaOperation, Queue<_MediaFailureScript>>{};
  final List<FakeChatMediaOperationCall> _calls =
      <FakeChatMediaOperationCall>[];
  var _closeCount = 0;
  var _closed = false;

  List<FakeChatMediaOperationCall> get calls =>
      List<FakeChatMediaOperationCall>.unmodifiable(_calls);
  int get closeCount => _closeCount;
  bool get isClosed => _closed;

  @override
  ChatMediaProviderState get initialState => _initialState;

  @override
  Stream<ChatMediaDeviceState> get deviceChanges => _deviceChanges.stream;

  @override
  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakerChanges =>
      _speakerChanges.stream;

  void queueError(
    ChatMediaOperation operation,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    _ensureOpen();
    (_failures[operation] ??= Queue<_MediaFailureScript>()).add(
      _MediaFailureScript(error, stackTrace ?? StackTrace.current),
    );
  }

  void emitDevices(ChatMediaDeviceState state) {
    _ensureOpen();
    _deviceChanges.add(state);
  }

  void emitActiveSpeakers(Iterable<ChatMediaActiveSpeaker> speakers) {
    _ensureOpen();
    _speakerChanges.add(List<ChatMediaActiveSpeaker>.unmodifiable(speakers));
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) => _record(
        FakeChatMediaOperationCall(
          ChatMediaOperation.microphone,
          enabled: enabled,
        ),
      );

  @override
  Future<void> setCameraEnabled(bool enabled) => _record(
        FakeChatMediaOperationCall(ChatMediaOperation.camera, enabled: enabled),
      );

  @override
  Future<void> setScreenShareEnabled(bool enabled) => _record(
        FakeChatMediaOperationCall(
          ChatMediaOperation.screenShare,
          enabled: enabled,
        ),
      );

  @override
  Future<void> selectAudioInput(String? deviceId) => _record(
        FakeChatMediaOperationCall(
          ChatMediaOperation.audioInput,
          deviceId: deviceId,
        ),
      );

  @override
  Future<void> selectAudioOutput(String? deviceId) => _record(
        FakeChatMediaOperationCall(
          ChatMediaOperation.audioOutput,
          deviceId: deviceId,
        ),
      );

  Future<void> _record(FakeChatMediaOperationCall call) async {
    _ensureOpen();
    _calls.add(call);
    _throwNext(call.operation);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeCount += 1;
    _calls.add(const FakeChatMediaOperationCall(ChatMediaOperation.close));
    Object? failure;
    StackTrace? failureStack;
    try {
      _throwNext(ChatMediaOperation.close);
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    await _deviceChanges.close();
    await _speakerChanges.close();
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  void resetCalls() {
    _ensureOpen();
    _calls.clear();
    _failures.clear();
  }

  void _throwNext(ChatMediaOperation operation) {
    final queue = _failures[operation];
    if (queue == null || queue.isEmpty) return;
    queue.removeFirst().throwError();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The fake media provider is closed.');
  }

  @override
  String toString() => 'FakeChatMediaProviderSession('
      'callCount: ${_calls.length}, closeCount: $_closeCount, closed: $_closed)';
}

/// Scripted native permissions and provider connections.
final class FakeChatMediaDelegate implements ChatMediaDelegate {
  FakeChatMediaDelegate({
    ChatMediaPermissionDecision defaultPermission =
        ChatMediaPermissionDecision.granted,
    FakeChatMediaProviderSession? fallbackSession,
  })  : _defaultPermission = defaultPermission,
        _fallbackSession = fallbackSession;

  final Map<ChatMediaPermission, Queue<Object>> _permissions =
      <ChatMediaPermission, Queue<Object>>{};
  final Queue<Object> _connections = Queue<Object>();
  final List<ChatMediaPermission> _permissionRequests = <ChatMediaPermission>[];
  final List<HuddleMediaJoinDescriptor> _descriptors =
      <HuddleMediaJoinDescriptor>[];
  ChatMediaPermissionDecision _defaultPermission;
  FakeChatMediaProviderSession? _fallbackSession;

  List<ChatMediaPermission> get permissionRequests =>
      List<ChatMediaPermission>.unmodifiable(_permissionRequests);
  List<HuddleMediaJoinDescriptor> get connectedDescriptors =>
      List<HuddleMediaJoinDescriptor>.unmodifiable(_descriptors);
  int get connectCount => _descriptors.length;

  void enqueuePermission(
    ChatMediaPermission permission,
    ChatMediaPermissionDecision decision,
  ) =>
      (_permissions[permission] ??= Queue<Object>()).add(decision);

  void enqueuePermissionError(
    ChatMediaPermission permission,
    Object error, [
    StackTrace? stackTrace,
  ]) =>
      (_permissions[permission] ??= Queue<Object>()).add(
        _MediaFailureScript(error, stackTrace ?? StackTrace.current),
      );

  void enqueueSession(FakeChatMediaProviderSession session) =>
      _connections.add(session);

  void enqueueConnectError(Object error, [StackTrace? stackTrace]) =>
      _connections.add(
        _MediaFailureScript(error, stackTrace ?? StackTrace.current),
      );

  @override
  Future<ChatMediaPermissionDecision> requestPermission(
    ChatMediaPermission permission,
  ) async {
    _permissionRequests.add(permission);
    final queue = _permissions[permission];
    if (queue == null || queue.isEmpty) return _defaultPermission;
    final script = queue.removeFirst();
    if (script case final _MediaFailureScript failure) failure.throwError();
    return script as ChatMediaPermissionDecision;
  }

  @override
  Future<ChatMediaProviderSession> connect(
    HuddleMediaJoinDescriptor descriptor,
  ) async {
    _descriptors.add(descriptor);
    if (_connections.isNotEmpty) {
      final script = _connections.removeFirst();
      if (script case final _MediaFailureScript failure) failure.throwError();
      return script as FakeChatMediaProviderSession;
    }
    return _fallbackSession ??= FakeChatMediaProviderSession();
  }

  void reset({
    ChatMediaPermissionDecision defaultPermission =
        ChatMediaPermissionDecision.granted,
    FakeChatMediaProviderSession? fallbackSession,
  }) {
    _permissions.clear();
    _connections.clear();
    _permissionRequests.clear();
    _descriptors.clear();
    _defaultPermission = defaultPermission;
    _fallbackSession = fallbackSession;
  }

  @override
  String toString() => 'FakeChatMediaDelegate('
      'permissionRequestCount: ${_permissionRequests.length}, '
      'connectCount: ${_descriptors.length}, '
      'hasFallbackSession: ${_fallbackSession != null})';
}

final class _MediaFailureScript {
  const _MediaFailureScript(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  Never throwError() => Error.throwWithStackTrace(error, stackTrace);
}
