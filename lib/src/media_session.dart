import 'dart:async';

import '../core.dart';

/// Native permission classes that a host application may request for media.
enum ChatMediaPermission { microphone, camera, screenShare }

/// Provider-neutral result of a native media permission request.
enum ChatMediaPermissionDecision { granted, denied, restricted }

/// Kinds of native devices reported by a media provider.
enum ChatMediaDeviceKind { audioInput, audioOutput, videoInput }

/// Operations used in stable, provider-neutral media failures.
enum ChatMediaOperation {
  connect,
  microphone,
  camera,
  screenShare,
  audioInput,
  audioOutput,
  deviceChanges,
  activeSpeakers,
  close,
}

/// Stable media failure categories. Provider exception text is never exposed.
enum ChatMediaErrorCode {
  permissionDenied,
  descriptorUnavailable,
  providerUnavailable,
  providerFailure,
  huddleFailure,
  notConnected,
  closed,
}

/// Lifecycle of a [ChatHuddleMediaSession].
enum ChatMediaSessionStatus {
  idle,
  unavailable,
  connecting,
  connected,
  closing,
  closed,
}

/// Immutable native media device metadata supplied by the host provider.
final class ChatMediaDevice {
  const ChatMediaDevice({
    required this.id,
    required this.kind,
    required this.label,
    this.isDefault = false,
  });

  final String id;
  final ChatMediaDeviceKind kind;
  final String label;
  final bool isDefault;

  @override
  String toString() => 'ChatMediaDevice(kind: ${kind.name}, '
      'isDefault: $isDefault)';
}

/// Immutable device inventory and selected audio routes.
final class ChatMediaDeviceState {
  ChatMediaDeviceState({
    required Iterable<ChatMediaDevice> devices,
    this.selectedAudioInputId,
    this.selectedAudioOutputId,
  }) : devices = List<ChatMediaDevice>.unmodifiable(devices);

  final List<ChatMediaDevice> devices;
  final String? selectedAudioInputId;
  final String? selectedAudioOutputId;

  @override
  String toString() => 'ChatMediaDeviceState(deviceCount: ${devices.length}, '
      'hasAudioInput: ${selectedAudioInputId != null}, '
      'hasAudioOutput: ${selectedAudioOutputId != null})';
}

/// Immutable active-speaker update supplied by the host media provider.
final class ChatMediaActiveSpeaker {
  const ChatMediaActiveSpeaker({
    required this.participantId,
    required this.isSpeaking,
  });

  final String participantId;
  final bool isSpeaking;

  @override
  String toString() => 'ChatMediaActiveSpeaker(isSpeaking: $isSpeaking)';
}

/// Immutable initial provider session snapshot.
final class ChatMediaProviderState {
  ChatMediaProviderState({
    required this.devices,
    this.microphoneEnabled = false,
    this.cameraEnabled = false,
    this.screenShareEnabled = false,
    Iterable<ChatMediaActiveSpeaker> activeSpeakers = const [],
  }) : activeSpeakers =
            List<ChatMediaActiveSpeaker>.unmodifiable(activeSpeakers);

  final ChatMediaDeviceState devices;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final List<ChatMediaActiveSpeaker> activeSpeakers;

  @override
  String toString() => 'ChatMediaProviderState('
      'devices: $devices, microphoneEnabled: $microphoneEnabled, '
      'cameraEnabled: $cameraEnabled, '
      'screenShareEnabled: $screenShareEnabled, '
      'activeSpeakerCount: ${activeSpeakers.length})';
}

/// Stable, descriptor-safe media failure exposed to application code.
final class ChatMediaFailure {
  const ChatMediaFailure({
    required this.code,
    required this.operation,
    required this.message,
    required this.retryable,
  });

  final ChatMediaErrorCode code;
  final ChatMediaOperation operation;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ChatMediaFailure(code: ${code.name}, '
      'operation: ${operation.name}, retryable: $retryable)';
}

/// Exception wrapper used by media commands.
final class ChatMediaException implements Exception {
  const ChatMediaException(this.failure);

  final ChatMediaFailure failure;

  @override
  String toString() => 'ChatMediaException($failure)';
}

/// Immutable renderer-safe state for one native huddle media session.
final class ChatMediaSessionState {
  ChatMediaSessionState({
    required this.status,
    required this.devices,
    required Iterable<ChatMediaActiveSpeaker> activeSpeakers,
    this.microphoneEnabled = false,
    this.cameraEnabled = false,
    this.screenShareEnabled = false,
    this.lastFailure,
  }) : activeSpeakers =
            List<ChatMediaActiveSpeaker>.unmodifiable(activeSpeakers);

  final ChatMediaSessionStatus status;
  final ChatMediaDeviceState devices;
  final List<ChatMediaActiveSpeaker> activeSpeakers;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final ChatMediaFailure? lastFailure;

  @override
  String toString() => 'ChatMediaSessionState(status: ${status.name}, '
      'devices: $devices, microphoneEnabled: $microphoneEnabled, '
      'cameraEnabled: $cameraEnabled, '
      'screenShareEnabled: $screenShareEnabled, '
      'activeSpeakerCount: ${activeSpeakers.length}, '
      'failure: $lastFailure)';
}

/// A connected provider session returned by [ChatMediaDelegate.connect].
///
/// Implement this interface with the application's chosen WebRTC or native
/// media package. Handrail does not select or initialize a provider package.
abstract interface class ChatMediaProviderSession {
  ChatMediaProviderState get initialState;

  Stream<ChatMediaDeviceState> get deviceChanges;

  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakerChanges;

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> setCameraEnabled(bool enabled);

  Future<void> setScreenShareEnabled(bool enabled);

  Future<void> selectAudioInput(String? deviceId);

  Future<void> selectAudioOutput(String? deviceId);

  Future<void> close();
}

/// Host-supplied native permission and media-provider integration.
abstract interface class ChatMediaDelegate {
  Future<ChatMediaPermissionDecision> requestPermission(
    ChatMediaPermission permission,
  );

  /// Connects the provider with the exact opaque descriptor from Handrail.
  ///
  /// The delegate must treat [descriptor] as secret, short-lived join material
  /// and must not log, persist, diagnose, or stringify its contents.
  Future<ChatMediaProviderSession> connect(
    HuddleMediaJoinDescriptor descriptor,
  );
}

/// Provider-neutral native media binding for a [ChatHuddleController].
///
/// The controller remains responsible for canonical huddle lifecycle state.
/// This adapter owns native permissions, devices, tracks, and audio routes. A
/// capability-disabled controller produces a successful unavailable/no-op
/// session without calling the provider or requesting permissions.
final class ChatHuddleMediaSession {
  ChatHuddleMediaSession({
    required ChatHuddleController controller,
    ChatMediaDelegate? delegate,
  })  : _controller = controller,
        _delegate = delegate,
        _state = _initialSessionState(controller) {
    _states = _currentFirst(_stateChanges.stream, () => _state);
    _deviceStates = _currentFirst(_deviceChanges.stream, () => _state.devices);
    _activeSpeakers = _currentFirst(
      _activeSpeakerChanges.stream,
      () => _state.activeSpeakers,
    );
  }

  final ChatHuddleController _controller;
  final ChatMediaDelegate? _delegate;
  final StreamController<ChatMediaSessionState> _stateChanges =
      StreamController<ChatMediaSessionState>.broadcast(sync: true);
  final StreamController<ChatMediaDeviceState> _deviceChanges =
      StreamController<ChatMediaDeviceState>.broadcast(sync: true);
  final StreamController<List<ChatMediaActiveSpeaker>> _activeSpeakerChanges =
      StreamController<List<ChatMediaActiveSpeaker>>.broadcast(sync: true);
  late final Stream<ChatMediaSessionState> _states;
  late final Stream<ChatMediaDeviceState> _deviceStates;
  late final Stream<List<ChatMediaActiveSpeaker>> _activeSpeakers;
  ChatMediaSessionState _state;
  ChatMediaProviderSession? _provider;
  StreamSubscription<ChatMediaDeviceState>? _deviceSubscription;
  StreamSubscription<List<ChatMediaActiveSpeaker>>? _speakerSubscription;
  Future<void>? _connectFuture;
  Future<void>? _closeFuture;
  Future<void>? _providerCloseFuture;
  Future<void> _operationTail = Future<void>.value();
  bool _closing = false;

  ChatMediaSessionState get state => _state;

  /// Broadcast state stream that gives each observer the current state first.
  Stream<ChatMediaSessionState> get states => _states;

  /// Broadcast device stream that gives each observer current devices first.
  Stream<ChatMediaDeviceState> get deviceStates => _deviceStates;

  /// Broadcast speaker stream that gives each observer current speakers first.
  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakers => _activeSpeakers;

  /// Connects once using the controller's exact opaque join descriptor.
  ///
  /// Concurrent calls share one attempt. Failed attempts may be retried after
  /// the controller obtains fresh join material.
  Future<void> connect() {
    if (_enterUnavailableIfNeeded()) return Future<void>.value();
    if (_state.status == ChatMediaSessionStatus.connected) {
      return Future<void>.value();
    }
    if (_closing || _state.status == ChatMediaSessionStatus.closed) {
      return Future<void>.error(_exception(
        ChatMediaErrorCode.closed,
        ChatMediaOperation.connect,
      ));
    }
    final active = _connectFuture;
    if (active != null) return active;
    late final Future<void> attempt;
    attempt = _connect().whenComplete(() {
      if (identical(_connectFuture, attempt)) _connectFuture = null;
    });
    _connectFuture = attempt;
    return attempt;
  }

  Future<void> setMicrophoneEnabled(bool enabled) => _enqueue(
        ChatMediaOperation.microphone,
        () async {
          if (enabled) {
            await _requestPermission(
              ChatMediaPermission.microphone,
              ChatMediaOperation.microphone,
            );
          }
          await _connectedProvider(ChatMediaOperation.microphone)
              .setMicrophoneEnabled(enabled);
          _emit(_copyState(
            microphoneEnabled: enabled,
            clearFailure: true,
          ));
        },
      );

  Future<void> setCameraEnabled(bool enabled) => _enqueue(
        ChatMediaOperation.camera,
        () async {
          if (enabled) {
            await _requestPermission(
              ChatMediaPermission.camera,
              ChatMediaOperation.camera,
            );
          }
          await _connectedProvider(ChatMediaOperation.camera)
              .setCameraEnabled(enabled);
          _emit(_copyState(cameraEnabled: enabled, clearFailure: true));
        },
      );

  /// Coordinates canonical screen-share intent before changing native tracks.
  Future<void> setScreenShareEnabled(bool enabled) => _enqueue(
        ChatMediaOperation.screenShare,
        () async {
          if (enabled) {
            await _requestPermission(
              ChatMediaPermission.screenShare,
              ChatMediaOperation.screenShare,
            );
          }
          final result = enabled
              ? await _controller.setScreenShare(HuddleScreenShareIntent.set)
              : await _controller.clearScreenShare();
          if (result is ChatHuddleActionFeatureDisabled) {
            _emit(_copyState(
              status: ChatMediaSessionStatus.unavailable,
              clearFailure: true,
            ));
            return;
          }
          if (result is ChatHuddleActionFailure) {
            throw _exception(
              ChatMediaErrorCode.huddleFailure,
              ChatMediaOperation.screenShare,
              retryable: result.retryable,
            );
          }
          await _connectedProvider(ChatMediaOperation.screenShare)
              .setScreenShareEnabled(enabled);
          _emit(_copyState(
            screenShareEnabled: enabled,
            clearFailure: true,
          ));
        },
      );

  Future<void> selectAudioInput(String? deviceId) => _enqueue(
        ChatMediaOperation.audioInput,
        () async {
          await _connectedProvider(ChatMediaOperation.audioInput)
              .selectAudioInput(deviceId);
          _setDevices(ChatMediaDeviceState(
            devices: _state.devices.devices,
            selectedAudioInputId: deviceId,
            selectedAudioOutputId: _state.devices.selectedAudioOutputId,
          ));
        },
      );

  Future<void> selectAudioOutput(String? deviceId) => _enqueue(
        ChatMediaOperation.audioOutput,
        () async {
          await _connectedProvider(ChatMediaOperation.audioOutput)
              .selectAudioOutput(deviceId);
          _setDevices(ChatMediaDeviceState(
            devices: _state.devices.devices,
            selectedAudioInputId: _state.devices.selectedAudioInputId,
            selectedAudioOutputId: deviceId,
          ));
        },
      );

  /// Closes provider tracks and all adapter streams exactly once.
  Future<void> close() => _closeFuture ??= _close();

  /// Alias for [close] for controller-style ownership APIs.
  Future<void> dispose() => close();

  bool _enterUnavailableIfNeeded() {
    if (_state.status == ChatMediaSessionStatus.unavailable) return true;
    if (_provider == null &&
        _controller.state.media is ChatHuddleMediaUnavailableState) {
      _emit(_copyState(
        status: ChatMediaSessionStatus.unavailable,
        clearFailure: true,
      ));
      return true;
    }
    return false;
  }

  Future<void> _connect() async {
    final delegate = _delegate;
    if (delegate == null) {
      return _fail(
        _exception(
          ChatMediaErrorCode.providerUnavailable,
          ChatMediaOperation.connect,
        ),
      );
    }
    final descriptor = _controller.mediaBoundary.readJoinDescriptor();
    if (descriptor == null) {
      return _fail(
        _exception(
          ChatMediaErrorCode.descriptorUnavailable,
          ChatMediaOperation.connect,
          retryable: true,
        ),
      );
    }

    _emit(_copyState(
      status: ChatMediaSessionStatus.connecting,
      clearFailure: true,
    ));
    try {
      final provider = await delegate.connect(descriptor);
      _provider = provider;
      if (_closing) {
        await _closeProvider(provider);
        return;
      }
      final initial = provider.initialState;
      _emit(ChatMediaSessionState(
        status: ChatMediaSessionStatus.connected,
        devices: initial.devices,
        activeSpeakers: initial.activeSpeakers,
        microphoneEnabled: initial.microphoneEnabled,
        cameraEnabled: initial.cameraEnabled,
        screenShareEnabled: initial.screenShareEnabled,
      ));
      _deviceSubscription = provider.deviceChanges.listen(
        _setDevices,
        onError: (_, __) => _recordProviderStreamFailure(
          ChatMediaOperation.deviceChanges,
        ),
      );
      _speakerSubscription = provider.activeSpeakerChanges.listen(
        _setActiveSpeakers,
        onError: (_, __) => _recordProviderStreamFailure(
          ChatMediaOperation.activeSpeakers,
        ),
      );
    } on ChatMediaException catch (error) {
      await _fail(error);
    } catch (_) {
      await _fail(_exception(
        ChatMediaErrorCode.providerFailure,
        ChatMediaOperation.connect,
        retryable: true,
      ));
    }
  }

  Future<void> _enqueue(
    ChatMediaOperation operation,
    Future<void> Function() action,
  ) {
    if (_enterUnavailableIfNeeded()) return Future<void>.value();
    if (_closing || _state.status == ChatMediaSessionStatus.closed) {
      return Future<void>.error(
        _exception(ChatMediaErrorCode.closed, operation),
      );
    }
    final result = _operationTail.then((_) async {
      if (_enterUnavailableIfNeeded()) return;
      if (_closing || _state.status == ChatMediaSessionStatus.closed) {
        throw _exception(ChatMediaErrorCode.closed, operation);
      }
      try {
        await action();
      } on ChatMediaException catch (error) {
        _emit(_copyState(lastFailure: error.failure));
        rethrow;
      } catch (_) {
        final error = _exception(
          ChatMediaErrorCode.providerFailure,
          operation,
          retryable: true,
        );
        _emit(_copyState(lastFailure: error.failure));
        throw error;
      }
    });
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<void> _requestPermission(
    ChatMediaPermission permission,
    ChatMediaOperation operation,
  ) async {
    final delegate = _delegate;
    if (delegate == null) {
      throw _exception(
        ChatMediaErrorCode.providerUnavailable,
        operation,
      );
    }
    final decision = await delegate.requestPermission(permission);
    if (decision != ChatMediaPermissionDecision.granted) {
      throw _exception(ChatMediaErrorCode.permissionDenied, operation);
    }
  }

  ChatMediaProviderSession _connectedProvider(ChatMediaOperation operation) {
    final provider = _provider;
    if (provider == null || _state.status != ChatMediaSessionStatus.connected) {
      throw _exception(ChatMediaErrorCode.notConnected, operation);
    }
    return provider;
  }

  Future<void> _close() async {
    _closing = true;
    if (_state.status != ChatMediaSessionStatus.closed) {
      _emit(_copyState(status: ChatMediaSessionStatus.closing));
    }
    ChatMediaException? failure;
    try {
      try {
        await _connectFuture;
      } catch (_) {
        // A failed connection already emitted a stable public failure.
      }
      await _operationTail;
      await _deviceSubscription?.cancel();
      await _speakerSubscription?.cancel();
      final provider = _provider;
      if (provider != null) await _closeProvider(provider);
    } catch (_) {
      failure = _exception(
        ChatMediaErrorCode.providerFailure,
        ChatMediaOperation.close,
      );
    } finally {
      _emit(_copyState(status: ChatMediaSessionStatus.closed));
      await _stateChanges.close();
      await _deviceChanges.close();
      await _activeSpeakerChanges.close();
    }
    if (failure != null) throw failure;
  }

  Future<void> _closeProvider(ChatMediaProviderSession provider) =>
      _providerCloseFuture ??= provider.close();

  Future<void> _fail(ChatMediaException error) {
    _emit(_copyState(
      status: ChatMediaSessionStatus.idle,
      lastFailure: error.failure,
    ));
    return Future<void>.error(error);
  }

  void _recordProviderStreamFailure(ChatMediaOperation operation) {
    if (_closing) return;
    _emit(_copyState(
      lastFailure: _exception(
        ChatMediaErrorCode.providerFailure,
        operation,
        retryable: true,
      ).failure,
    ));
  }

  void _setDevices(ChatMediaDeviceState devices) {
    if (_closing) return;
    _emit(_copyState(devices: devices, clearFailure: true));
    if (!_deviceChanges.isClosed) _deviceChanges.add(devices);
  }

  void _setActiveSpeakers(Iterable<ChatMediaActiveSpeaker> speakers) {
    if (_closing) return;
    final immutable = List<ChatMediaActiveSpeaker>.unmodifiable(speakers);
    _emit(_copyState(activeSpeakers: immutable, clearFailure: true));
    if (!_activeSpeakerChanges.isClosed) {
      _activeSpeakerChanges.add(immutable);
    }
  }

  ChatMediaSessionState _copyState({
    ChatMediaSessionStatus? status,
    ChatMediaDeviceState? devices,
    Iterable<ChatMediaActiveSpeaker>? activeSpeakers,
    bool? microphoneEnabled,
    bool? cameraEnabled,
    bool? screenShareEnabled,
    ChatMediaFailure? lastFailure,
    bool clearFailure = false,
  }) =>
      ChatMediaSessionState(
        status: status ?? _state.status,
        devices: devices ?? _state.devices,
        activeSpeakers: activeSpeakers ?? _state.activeSpeakers,
        microphoneEnabled: microphoneEnabled ?? _state.microphoneEnabled,
        cameraEnabled: cameraEnabled ?? _state.cameraEnabled,
        screenShareEnabled: screenShareEnabled ?? _state.screenShareEnabled,
        lastFailure: clearFailure ? null : lastFailure ?? _state.lastFailure,
      );

  void _emit(ChatMediaSessionState next) {
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
  }

  @override
  String toString() => 'ChatHuddleMediaSession('
      'status: ${_state.status.name}, hasProvider: ${_provider != null})';
}

ChatMediaSessionState _initialSessionState(ChatHuddleController controller) =>
    ChatMediaSessionState(
      status: controller.state.media is ChatHuddleMediaUnavailableState
          ? ChatMediaSessionStatus.unavailable
          : ChatMediaSessionStatus.idle,
      devices: ChatMediaDeviceState(devices: const []),
      activeSpeakers: const [],
    );

ChatMediaException _exception(
  ChatMediaErrorCode code,
  ChatMediaOperation operation, {
  bool retryable = false,
}) =>
    ChatMediaException(ChatMediaFailure(
      code: code,
      operation: operation,
      message: switch (code) {
        ChatMediaErrorCode.permissionDenied =>
          'The required media permission was not granted.',
        ChatMediaErrorCode.descriptorUnavailable =>
          'Fresh huddle join material is required.',
        ChatMediaErrorCode.providerUnavailable =>
          'No native media provider is configured.',
        ChatMediaErrorCode.providerFailure =>
          'The native media provider could not complete the operation.',
        ChatMediaErrorCode.huddleFailure =>
          'The huddle could not complete the media operation.',
        ChatMediaErrorCode.notConnected =>
          'The native media session is not connected.',
        ChatMediaErrorCode.closed => 'The native media session is closed.',
      },
      retryable: retryable,
    ));

Stream<T> _currentFirst<T>(Stream<T> changes, T Function() current) =>
    Stream<T>.multi(
      (events) {
        events.add(current());
        final subscription = changes.listen(
          events.add,
          onError: events.addError,
          onDone: events.close,
        );
        events.onCancel = subscription.cancel;
      },
      isBroadcast: true,
    );
