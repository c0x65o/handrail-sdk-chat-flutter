import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core.dart';
import 'chat_application_connectivity.dart';
import 'chat_push_token.dart';

/// Immutable values used to create a client owned by a [ChatScope].
final class ChatScopeClientConfig {
  ChatScopeClientConfig({
    required this.apiBaseUri,
    required this.tokenProvider,
    required this.transport,
    Map<String, bool> requestedCapabilities = const <String, bool>{},
    this.onSnapshotQueryDiagnostic,
  }) : requestedCapabilities =
            Map<String, bool>.unmodifiable(requestedCapabilities);

  final Uri apiBaseUri;
  final HandrailChatAccessTokenProvider tokenProvider;
  final HandrailChatHttpTransport transport;
  final Map<String, bool> requestedCapabilities;
  final ChatSnapshotQueryDiagnosticCallback? onSnapshotQueryDiagnostic;

  HandrailChatClient _createClient() => HandrailChatClient(
        apiBaseUri: apiBaseUri,
        tokenProvider: tokenProvider,
        transport: transport,
        requestedCapabilities: requestedCapabilities,
        onSnapshotQueryDiagnostic: onSnapshotQueryDiagnostic,
      );
}

/// Stable readiness categories projected from the client lifecycle.
enum ChatScopeReadiness {
  notReady,
  ready,
  refreshRequired,
  error,
}

/// Readiness of the optional host-delegate and realtime binding.
enum ChatScopeIntegrationReadiness {
  unbound,
  resolving,
  ready,
  error,
}

/// The immutable client and lifecycle view exposed to scope descendants.
final class ChatScopeBinding {
  const ChatScopeBinding._({
    required this.client,
    required this.state,
    required this.integrationReadiness,
    required this.connectivity,
    required this.deviceId,
    required this.integrationDiagnostic,
    required this.realtimeState,
    required Future<ChatCommandResult<DevicePushTokenResult>?> Function()
        unregisterPushTokenForLogout,
  }) : _unregisterPushTokenForLogout = unregisterPushTokenForLogout;

  final HandrailChatClient client;
  final ChatClientLifecycleState state;
  final ChatScopeIntegrationReadiness integrationReadiness;
  final ChatConnectivityStatus connectivity;
  final DeviceId? deviceId;
  final ChatScopeIntegrationDiagnostic? integrationDiagnostic;
  final ChatRealtimeLifecycleState? realtimeState;
  final Future<ChatCommandResult<DevicePushTokenResult>?> Function()
      _unregisterPushTokenForLogout;

  /// Explicitly unregisters the active identity's token during host logout.
  ///
  /// Returns `null` when this scope has no successfully registered token.
  /// Rebuild, delegate replacement, and scope disposal never call this method.
  Future<ChatCommandResult<DevicePushTokenResult>?>
      unregisterPushTokenForLogout() => _unregisterPushTokenForLogout();

  ChatScopeReadiness get readiness => switch (state) {
        ChatClientReadyState() => ChatScopeReadiness.ready,
        ChatClientRefreshRequiredState() => ChatScopeReadiness.refreshRequired,
        ChatClientErrorState() => ChatScopeReadiness.error,
        _ => ChatScopeReadiness.notReady,
      };

  bool get isReady => state is ChatClientReadyState;

  ChatClientRefreshRequiredState? get refreshRequired =>
      state is ChatClientRefreshRequiredState
          ? state as ChatClientRefreshRequiredState
          : null;

  /// A sanitized diagnostic only; startup exceptions and response bodies are
  /// never projected through this binding.
  ChatClientDiagnostic? get error => state is ChatClientErrorState
      ? (state as ChatClientErrorState).diagnostic
      : null;
}

/// Binds one [HandrailChatClient] to the nearest descendant widget subtree.
///
/// Pass [client] for an externally owned client. The scope observes that
/// client's states but never initializes or disposes it. Pass [config] to let
/// the scope create, initialize, and dispose a client for this mount. A binding
/// remains stable across ordinary rebuilds; use a new key to replace it.
final class ChatScope extends StatefulWidget {
  ChatScope({
    required this.child,
    this.client,
    this.config,
    this.connectivityDelegate,
    this.deviceIdentityDelegate,
    this.identityScopeKey,
    this.realtimeSessionFactory,
    this.pushTokenDelegate,
    this.onIntegrationDiagnostic,
    super.key,
  }) {
    if (client != null && config != null) {
      throw ArgumentError(
        'ChatScope accepts either client or config, not both.',
      );
    }
    if (client == null && config == null) {
      throw ArgumentError('ChatScope requires either client or config.');
    }
    final integrationValueCount = <Object?>[
      connectivityDelegate,
      deviceIdentityDelegate,
      realtimeSessionFactory,
    ].where((value) => value != null).length;
    if (integrationValueCount != 0 && integrationValueCount != 3) {
      throw ArgumentError(
        'ChatScope connectivity, device identity, and realtime session '
        'bindings must be supplied together.',
      );
    }
    if (pushTokenDelegate != null && connectivityDelegate == null) {
      throw ArgumentError(
        'ChatScope push-token binding requires connectivity, device identity, '
        'and realtime session bindings.',
      );
    }
  }

  final Widget child;
  final HandrailChatClient? client;
  final ChatScopeClientConfig? config;
  final ChatConnectivityDelegate? connectivityDelegate;
  final ChatDeviceIdentityDelegate? deviceIdentityDelegate;

  /// Trusted login/account scope used to invalidate stale host-owned state.
  ///
  /// Keep this stable for one login identity and include any account/device
  /// boundary required by host persistence. Never use a token, credential, or
  /// other secret. Realtime factories with cursor persistence must map this to
  /// a bounded nonblank [ChatRealtimeSessionTransport.cursorStorageScope].
  final Object? identityScopeKey;
  final ChatScopeRealtimeSessionFactory? realtimeSessionFactory;
  final ChatPushTokenDelegate? pushTokenDelegate;
  final ChatScopeIntegrationDiagnosticListener? onIntegrationDiagnostic;

  bool get _hasIntegration => connectivityDelegate != null;

  /// Returns the nearest binding and registers this context as a dependent.
  static ChatScopeBinding of(BuildContext context) {
    final binding = maybeOf(context);
    if (binding != null) return binding;

    throw FlutterError.fromParts(<DiagnosticsNode>[
      ErrorSummary('No ChatScope found in context.'),
      ErrorDescription(
        'ChatScope.of() requires a ChatScope ancestor for this context.',
      ),
    ]);
  }

  /// Returns the nearest binding, or `null` when no scope is present.
  static ChatScopeBinding? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_InheritedChatScope>()
      ?.binding;

  @override
  State<ChatScope> createState() => _ChatScopeState();
}

final class _ChatScopeState extends State<ChatScope> {
  late final HandrailChatClient _client;
  late final bool _ownsClient;
  late ChatClientLifecycleState _state;
  late final StreamSubscription<ChatClientLifecycleState> _subscription;
  late final AppLifecycleListener _applicationLifecycleListener;
  ChatScopeIntegrationReadiness _integrationReadiness =
      ChatScopeIntegrationReadiness.unbound;
  ChatConnectivityStatus _connectivity = ChatConnectivityStatus.unknown;
  DeviceId? _deviceId;
  ChatScopeIntegrationDiagnostic? _integrationDiagnostic;
  ChatRealtimeLifecycleState? _realtimeState;
  _ChatScopeIntegrationRuntime? _integration;
  var _integrationGeneration = 0;
  bool _active = true;
  bool _initializationStarted = false;
  bool _disposeStarted = false;
  late bool _applicationForeground;

  @override
  void initState() {
    super.initState();
    _applicationForeground = _isApplicationForeground(
      WidgetsBinding.instance.lifecycleState,
    );
    _ownsClient = widget.client == null;
    _client = widget.client ?? widget.config!._createClient();
    _client.setApplicationForeground(_applicationForeground);
    _state = _client.state;
    _subscription = _client.states.listen(_handleState);
    _applicationLifecycleListener = AppLifecycleListener(
      onStateChange: _handleApplicationLifecycleState,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active) return;
      if (widget._hasIntegration) {
        _restartIntegration();
      } else if (_ownsClient) {
        _initializeOwnedClient();
      }
    });
  }

  void _handleState(ChatClientLifecycleState nextState) {
    if (!_active) return;
    if (!identical(_state, nextState)) {
      setState(() => _state = nextState);
    }
    _maybeStartRealtime(_integrationGeneration);
    _maybeStartPushToken(_integrationGeneration);
  }

  Future<void> _initializeOwnedClient() async {
    if (_initializationStarted) return;
    _initializationStarted = true;

    // State emissions drive rebuilds. Handling the returned future prevents a
    // late completion after unmount from becoming an unhandled async error.
    try {
      await _client.initialize();
    } catch (_) {
      // Client lifecycle state contains the stable sanitized failure.
    }
  }

  @override
  void didUpdateWidget(ChatScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectivityDelegate != widget.connectivityDelegate ||
        oldWidget.deviceIdentityDelegate != widget.deviceIdentityDelegate ||
        oldWidget.identityScopeKey != widget.identityScopeKey ||
        oldWidget.realtimeSessionFactory != widget.realtimeSessionFactory ||
        oldWidget.pushTokenDelegate != widget.pushTokenDelegate) {
      if (widget._hasIntegration) {
        _restartIntegration();
      } else {
        _clearIntegration();
        if (_ownsClient) _initializeOwnedClient();
      }
    }
  }

  void _restartIntegration() {
    final generation = ++_integrationGeneration;
    final previous = _integration;
    _integration = null;
    if (previous != null) unawaited(previous.dispose());
    if (!_active) return;
    setState(() {
      _integrationReadiness = ChatScopeIntegrationReadiness.resolving;
      _connectivity = ChatConnectivityStatus.unknown;
      _deviceId = null;
      _integrationDiagnostic = null;
      _realtimeState = null;
    });
    unawaited(_bootstrapIntegration(generation));
  }

  void _clearIntegration() {
    ++_integrationGeneration;
    final previous = _integration;
    _integration = null;
    if (previous != null) unawaited(previous.dispose());
    if (!_active) return;
    setState(() {
      _integrationReadiness = ChatScopeIntegrationReadiness.unbound;
      _connectivity = ChatConnectivityStatus.unknown;
      _deviceId = null;
      _integrationDiagnostic = null;
      _realtimeState = null;
    });
  }

  Future<void> _bootstrapIntegration(int generation) async {
    final connectivityDelegate = widget.connectivityDelegate;
    final identityDelegate = widget.deviceIdentityDelegate;
    if (connectivityDelegate == null || identityDelegate == null) return;

    late final _ChatScopeIntegrationRuntime runtime;
    runtime = _ChatScopeIntegrationRuntime(
      network: ChatRealtimeNetworkAdapter(
        delegate: connectivityDelegate,
        onStatusChanged: (status) => _handleConnectivity(generation, status),
        onDiagnostic: (diagnostic) =>
            _handleIntegrationDiagnostic(generation, diagnostic),
      ),
      client: _client,
      initialForeground: _applicationForeground,
      isAuthoritative: () =>
          _hasIntegrationAuthority(generation) &&
          identical(_integration, runtime),
      onRealtimeState: (state) =>
          _handleRealtimeState(generation, runtime, state),
    );
    if (!_hasIntegrationAuthority(generation)) {
      await runtime.dispose();
      return;
    }
    _integration = runtime;
    await runtime.network.initialize();
    if (!_hasIntegrationAuthority(generation) ||
        !identical(_integration, runtime)) {
      await runtime.dispose();
      return;
    }

    late final String rawDeviceId;
    try {
      rawDeviceId = await identityDelegate.getOrCreateDeviceId(
        identityScopeKey: widget.identityScopeKey,
      );
    } catch (_) {
      _failIdentity(
        generation,
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.deviceIdentityFailed,
          message: 'The chat device identity could not be resolved.',
        ),
      );
      return;
    }

    late final DeviceId deviceId;
    try {
      deviceId = _validatedDeviceId(rawDeviceId);
    } catch (_) {
      _failIdentity(
        generation,
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.invalidDeviceIdentity,
          message: 'The chat device identity is invalid.',
        ),
      );
      return;
    }
    if (!_hasIntegrationAuthority(generation) ||
        !identical(_integration, runtime)) {
      return;
    }

    setState(() {
      _deviceId = deviceId;
      _integrationReadiness = ChatScopeIntegrationReadiness.ready;
      if (_integrationDiagnostic?.code ==
              ChatScopeIntegrationDiagnosticCode.deviceIdentityFailed ||
          _integrationDiagnostic?.code ==
              ChatScopeIntegrationDiagnosticCode.invalidDeviceIdentity) {
        _integrationDiagnostic = null;
      }
    });

    if (_ownsClient) await _initializeOwnedClient();
    _maybeStartRealtime(generation);
    _maybeStartPushToken(generation);
  }

  void _failIdentity(
    int generation,
    ChatScopeIntegrationDiagnostic diagnostic,
  ) {
    if (!_hasIntegrationAuthority(generation)) return;
    setState(() {
      _integrationReadiness = ChatScopeIntegrationReadiness.error;
      _integrationDiagnostic = diagnostic;
    });
    _notifyIntegrationDiagnostic(diagnostic);
  }

  void _handleConnectivity(
    int generation,
    ChatConnectivityStatus status,
  ) {
    if (!_hasIntegrationAuthority(generation)) return;
    final connectivityDiagnostic = switch (_integrationDiagnostic?.code) {
      ChatScopeIntegrationDiagnosticCode.connectivityQueryFailed ||
      ChatScopeIntegrationDiagnosticCode.connectivityStreamFailed =>
        true,
      _ => false,
    };
    if (_connectivity != status || connectivityDiagnostic) {
      setState(() {
        _connectivity = status;
        if (connectivityDiagnostic) _integrationDiagnostic = null;
      });
    }
    _maybeStartRealtime(generation);
    _integration?.pushToken?.updateConnectivity(status);
    _maybeStartPushToken(generation);
    scheduleMicrotask(() {
      final runtime = _integration;
      final state = runtime?.session?.state;
      if (_hasIntegrationAuthority(generation) &&
          state != null &&
          !identical(_realtimeState, state)) {
        setState(() => _realtimeState = state);
      }
    });
  }

  void _handleIntegrationDiagnostic(
    int generation,
    ChatScopeIntegrationDiagnostic diagnostic,
  ) {
    if (!_hasIntegrationAuthority(generation)) return;
    setState(() => _integrationDiagnostic = diagnostic);
    _notifyIntegrationDiagnostic(diagnostic);
  }

  void _handleRealtimeState(
    int generation,
    _ChatScopeIntegrationRuntime runtime,
    ChatRealtimeLifecycleState state,
  ) {
    if (!_hasIntegrationAuthority(generation) ||
        !identical(_integration, runtime) ||
        identical(_realtimeState, state)) {
      return;
    }
    setState(() => _realtimeState = state);
  }

  void _notifyIntegrationDiagnostic(
    ChatScopeIntegrationDiagnostic diagnostic,
  ) {
    try {
      widget.onIntegrationDiagnostic?.call(diagnostic);
    } catch (_) {
      // Host diagnostics cannot alter scope orchestration.
    }
  }

  void _maybeStartRealtime(int generation) {
    final runtime = _integration;
    final deviceId = _deviceId;
    final factory = widget.realtimeSessionFactory;
    if (!_hasIntegrationAuthority(generation) ||
        runtime == null ||
        runtime.starting ||
        runtime.session != null ||
        deviceId == null ||
        factory == null ||
        _state is! ChatClientReadyState) {
      return;
    }
    runtime.starting = true;
    unawaited(_startRealtime(generation, runtime, deviceId, factory));
  }

  Future<void> _startRealtime(
    int generation,
    _ChatScopeIntegrationRuntime runtime,
    DeviceId deviceId,
    ChatScopeRealtimeSessionFactory factory,
  ) async {
    late final ChatRealtimeSessionTransport session;
    try {
      session = factory(
        ChatScopeRealtimeSessionConfig(
          client: _client,
          deviceId: deviceId,
          network: runtime.network,
          identityScopeKey: widget.identityScopeKey,
        ),
      );
    } catch (_) {
      runtime.starting = false;
      _failRealtime(generation);
      return;
    }
    if (!_hasIntegrationAuthority(generation) ||
        !identical(_integration, runtime)) {
      await session.dispose();
      return;
    }
    try {
      await runtime.attachSession(session);
      if (_hasIntegrationAuthority(generation) &&
          identical(_integration, runtime)) {
        setState(() => _realtimeState = session.state);
      }
    } catch (_) {
      _failRealtime(generation);
    } finally {
      runtime.starting = false;
    }
  }

  void _failRealtime(int generation) {
    if (!_hasIntegrationAuthority(generation)) return;
    const diagnostic = ChatScopeIntegrationDiagnostic(
      code: ChatScopeIntegrationDiagnosticCode.realtimeSessionFailed,
      message: 'The chat realtime session could not be started.',
    );
    setState(() => _integrationDiagnostic = diagnostic);
    _notifyIntegrationDiagnostic(diagnostic);
  }

  bool _hasIntegrationAuthority(int generation) =>
      _active && generation == _integrationGeneration;

  void _handleApplicationLifecycleState(AppLifecycleState state) {
    if (!_active) return;
    final foreground = _isApplicationForeground(state);
    if (_applicationForeground == foreground) return;
    _applicationForeground = foreground;
    if (foreground) {
      _client.setApplicationForeground(false);
      _integration?.setApplicationForeground(true);
    } else {
      _integration?.setApplicationForeground(false);
      _client.setApplicationForeground(false);
    }
    _integration?.pushToken?.updateForeground(foreground);
    if (foreground) {
      if (_integration == null) _client.setApplicationForeground(true);
      _maybeStartRealtime(_integrationGeneration);
      _maybeStartPushToken(_integrationGeneration);
    }
  }

  void _maybeStartPushToken(int generation) {
    final runtime = _integration;
    final delegate = widget.pushTokenDelegate;
    final deviceId = _deviceId;
    if (!_hasIntegrationAuthority(generation) ||
        runtime == null ||
        runtime.pushToken != null ||
        delegate == null ||
        deviceId == null ||
        _state is! ChatClientReadyState) {
      return;
    }
    final pushToken = _ChatScopePushTokenRuntime(
      client: _client,
      delegate: delegate,
      deviceId: deviceId,
      identityScopeKey: widget.identityScopeKey,
      isAuthoritative: () =>
          _hasIntegrationAuthority(generation) &&
          identical(_integration, runtime),
      onDiagnostic: (diagnostic) =>
          _handleIntegrationDiagnostic(generation, diagnostic),
      initialConnectivity: _connectivity,
      initialForeground: _applicationForeground,
    );
    runtime.pushToken = pushToken;
    unawaited(pushToken.start());
  }

  Future<ChatCommandResult<DevicePushTokenResult>?>
      _unregisterPushTokenForLogout() async {
    final generation = _integrationGeneration;
    final runtime = _integration?.pushToken;
    if (!_hasIntegrationAuthority(generation) || runtime == null) return null;
    return runtime.unregisterForLogout();
  }

  @override
  Widget build(BuildContext context) => _InheritedChatScope(
        binding: ChatScopeBinding._(
          client: _client,
          state: _state,
          integrationReadiness: _integrationReadiness,
          connectivity: _connectivity,
          deviceId: _deviceId,
          integrationDiagnostic: _integrationDiagnostic,
          realtimeState: _realtimeState,
          unregisterPushTokenForLogout: _unregisterPushTokenForLogout,
        ),
        child: widget.child,
      );

  @override
  void dispose() {
    _active = false;
    _applicationLifecycleListener.dispose();
    _client.setApplicationForeground(false);
    ++_integrationGeneration;
    final integration = _integration;
    _integration = null;
    if (integration != null) unawaited(integration.dispose());
    unawaited(_subscription.cancel());
    if (_ownsClient && !_disposeStarted) {
      _disposeStarted = true;
      unawaited(
        _client.dispose().then<void>(
              (_) {},
              onError: (Object _, StackTrace __) {},
            ),
      );
    }
    super.dispose();
  }
}

final class _InheritedChatScope extends InheritedWidget {
  const _InheritedChatScope({
    required this.binding,
    required super.child,
  });

  final ChatScopeBinding binding;

  @override
  bool updateShouldNotify(_InheritedChatScope oldWidget) =>
      !identical(binding.client, oldWidget.binding.client) ||
      !identical(binding.state, oldWidget.binding.state) ||
      binding.integrationReadiness != oldWidget.binding.integrationReadiness ||
      binding.connectivity != oldWidget.binding.connectivity ||
      binding.deviceId != oldWidget.binding.deviceId ||
      !identical(
        binding.integrationDiagnostic,
        oldWidget.binding.integrationDiagnostic,
      ) ||
      !identical(binding.realtimeState, oldWidget.binding.realtimeState);
}

final class _ChatScopeIntegrationRuntime {
  _ChatScopeIntegrationRuntime({
    required this.network,
    required this.client,
    required bool initialForeground,
    required this.isAuthoritative,
    required this.onRealtimeState,
  }) : _applicationForeground = initialForeground;

  final ChatRealtimeNetworkAdapter network;
  final HandrailChatClient client;
  final bool Function() isAuthoritative;
  final void Function(ChatRealtimeLifecycleState state) onRealtimeState;
  ChatRealtimeSessionTransport? session;
  _ChatScopePushTokenRuntime? pushToken;
  StreamSubscription<ChatRealtimeLifecycleState>? _stateSubscription;
  Future<void>? _suspendOperation;
  Future<void>? _recoveryOperation;
  int _lifecycleGeneration = 0;
  bool _applicationForeground;
  bool starting = false;
  bool _disposed = false;

  Future<void> attachSession(ChatRealtimeSessionTransport value) async {
    if (_disposed || !isAuthoritative()) {
      await value.dispose();
      return;
    }
    session = value;
    _stateSubscription = value.states.listen(onRealtimeState);
    if (_applicationForeground) {
      await _resume();
    } else {
      await _suspend();
    }
  }

  void setApplicationForeground(bool foreground) {
    if (_disposed || _applicationForeground == foreground) return;
    _applicationForeground = foreground;
    ++_lifecycleGeneration;
    if (foreground) {
      unawaited(_resume());
    } else {
      final suspension = _suspend();
      client.setApplicationForeground(false);
      unawaited(suspension);
    }
  }

  Future<void> _suspend() {
    final realtimeSession = session;
    if (realtimeSession == null) return Future<void>.value();
    final operation = _safelySuspendRealtime(realtimeSession);
    _suspendOperation = operation;
    return operation;
  }

  Future<void> _resume() {
    if (_disposed || !_applicationForeground || !isAuthoritative()) {
      return Future<void>.value();
    }
    final active = _recoveryOperation;
    if (active != null) return active;
    final lifecycleGeneration = _lifecycleGeneration;
    late final Future<void> operation;
    operation = _recover(lifecycleGeneration).whenComplete(() {
      if (identical(_recoveryOperation, operation)) {
        _recoveryOperation = null;
        if (_applicationForeground &&
            lifecycleGeneration != _lifecycleGeneration) {
          unawaited(_resume());
        }
      }
    });
    _recoveryOperation = operation;
    return operation;
  }

  Future<void> _recover(int lifecycleGeneration) async {
    await _suspendOperation;
    if (!_hasLifecycleAuthority(lifecycleGeneration)) return;
    final realtimeSession = session;
    if (realtimeSession == null) return;
    final connected = await realtimeSession.resumeFromCursor();
    if (!connected || !_hasLifecycleAuthority(lifecycleGeneration)) return;
    client.setApplicationForeground(true);
  }

  bool _hasLifecycleAuthority(int lifecycleGeneration) =>
      !_disposed &&
      _applicationForeground &&
      lifecycleGeneration == _lifecycleGeneration &&
      isAuthoritative();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _applicationForeground = false;
    ++_lifecycleGeneration;
    final realtimeSession = session;
    session = null;
    final pushTokenRuntime = pushToken;
    pushToken = null;
    final stateSubscription = _stateSubscription;
    _stateSubscription = null;
    if (stateSubscription != null) {
      try {
        await stateSubscription.cancel();
      } catch (_) {
        // Listener cleanup cannot prevent the owned runtime from closing.
      }
    }
    await Future.wait<void>(<Future<void>>[
      _safelyDisposeRealtime(realtimeSession),
      if (pushTokenRuntime != null) pushTokenRuntime.dispose(),
      network.dispose(),
    ]);
  }
}

final class _PendingPushToken {
  const _PendingPushToken(this.value, this.sequence);

  final ChatPushToken value;
  final int sequence;
}

final class _ChatScopePushTokenRuntime {
  _ChatScopePushTokenRuntime({
    required this.client,
    required this.delegate,
    required this.deviceId,
    required this.identityScopeKey,
    required this.isAuthoritative,
    required this.onDiagnostic,
    required ChatConnectivityStatus initialConnectivity,
    required bool initialForeground,
  })  : _connectivity = initialConnectivity,
        _foreground = initialForeground;

  final HandrailChatClient client;
  final ChatPushTokenDelegate delegate;
  final DeviceId deviceId;
  final Object? identityScopeKey;
  final bool Function() isAuthoritative;
  final ChatScopeIntegrationDiagnosticListener onDiagnostic;

  final List<_PendingPushToken> _pending = <_PendingPushToken>[];
  final List<ChatPushToken> _initialRotations = <ChatPushToken>[];
  StreamSubscription<ChatPushToken>? _subscription;
  Future<void>? _drain;
  ChatCommandCancellationController? _activeCancellation;
  ChatPushToken? _registered;
  ChatConnectivityStatus _connectivity;
  bool _foreground;
  bool _loadingInitial = true;
  bool _sawRotation = false;
  bool _initialRetryRequired = false;
  bool _retryRequired = false;
  bool _offlineObservedForRetry = false;
  bool _disposed = false;
  bool _logoutStarted = false;
  int _revision = 0;
  int _sequence = 0;

  Future<void> start() async {
    if (!_hasAuthority) return;
    try {
      _subscription = delegate.pushTokenRotations.listen(
        _handleRotation,
        onError: (Object _, StackTrace __) => _report(
          const ChatScopeIntegrationDiagnostic(
            code: ChatScopeIntegrationDiagnosticCode.pushTokenStreamFailed,
            message: 'Push-token changes could not be observed.',
          ),
        ),
      );
    } catch (_) {
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.pushTokenStreamFailed,
          message: 'Push-token changes could not be observed.',
        ),
      );
    }
    await _loadInitialToken();
  }

  void updateConnectivity(ChatConnectivityStatus status) {
    if (!_hasAuthority) return;
    _connectivity = status;
    if (status != ChatConnectivityStatus.online) {
      if (_retryRequired || _initialRetryRequired) {
        _offlineObservedForRetry = true;
      }
      return;
    }
    if (_initialRetryRequired && _offlineObservedForRetry && !_sawRotation) {
      _initialRetryRequired = false;
      _loadingInitial = true;
      unawaited(_loadInitialToken());
    }
    if (_retryRequired && _offlineObservedForRetry) {
      _retryRequired = false;
      _offlineObservedForRetry = false;
    }
    _scheduleDrain();
  }

  void updateForeground(bool foreground) {
    if (!_hasAuthority) return;
    _foreground = foreground;
    if (foreground) _scheduleDrain();
  }

  Future<ChatCommandResult<DevicePushTokenResult>?>
      unregisterForLogout() async {
    if (!_hasAuthority || _logoutStarted) return null;
    _logoutStarted = true;
    _activeCancellation?.cancel();
    await _drain;
    if (!_hasAuthority) return null;
    final registered = _registered;
    if (registered == null) return null;

    final cancellation = ChatCommandCancellationController();
    _activeCancellation = cancellation;
    final revision = _revision + 1;
    final result = await client.unregisterPushTokenForLogout(
      UnregisterDevicePushTokenInput(
        deviceId: deviceId,
        tokenRevision: revision,
        idempotencyKey: _key('logout', ++_sequence),
      ),
      cancellationSignal: cancellation.signal,
    );
    if (!_hasAuthority) return result;
    if (result case ChatCommandSuccess<DevicePushTokenResult>(:final value)) {
      _registered = null;
      _revision = value.devicePushToken.tokenRevision;
    } else {
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.pushTokenLogoutFailed,
          message: 'The chat push token could not be unregistered for logout.',
        ),
      );
    }
    return result;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _activeCancellation?.cancel();
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Cancellation still removes this runtime's authority.
    }
  }

  Future<void> _loadInitialToken() async {
    ChatPushToken? initial;
    try {
      initial = await delegate.getInitialPushToken(
        identityScopeKey: identityScopeKey,
      );
    } catch (_) {
      if (!_hasAuthority) return;
      _initialRetryRequired = true;
      _offlineObservedForRetry = _connectivity != ChatConnectivityStatus.online;
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.pushTokenInitialFailed,
          message: 'The current push token could not be obtained.',
        ),
      );
    }
    if (!_hasAuthority) return;
    _loadingInitial = false;
    if (initial != null && !_sawRotation) _enqueue(initial);
    final rotations = List<ChatPushToken>.of(_initialRotations);
    _initialRotations.clear();
    for (final rotation in rotations) {
      _enqueue(rotation);
    }
  }

  void _handleRotation(ChatPushToken token) {
    if (!_hasAuthority) return;
    _sawRotation = true;
    _initialRetryRequired = false;
    if (_loadingInitial) {
      if (!_initialRotations.contains(token)) _initialRotations.add(token);
      return;
    }
    _enqueue(token);
  }

  void _enqueue(ChatPushToken token) {
    if (!_hasAuthority || _logoutStarted || token == _registered) return;
    if (_pending.any((pending) => pending.value == token)) return;
    _pending.add(_PendingPushToken(token, ++_sequence));
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (!_canDispatch || _drain != null || _pending.isEmpty) return;
    late final Future<void> drain;
    drain = _drainPending().whenComplete(() {
      if (identical(_drain, drain)) _drain = null;
      if (_canDispatch && _pending.isNotEmpty) _scheduleDrain();
    });
    _drain = drain;
  }

  Future<void> _drainPending() async {
    while (_canDispatch && _pending.isNotEmpty) {
      final pending = _pending.first;
      final cancellation = ChatCommandCancellationController();
      _activeCancellation = cancellation;
      final result = await _dispatch(pending, cancellation.signal);
      if (!_hasAuthority || _logoutStarted) return;
      if (result == null) return;
      if (result.success) {
        _registered = pending.value;
        _revision = result.revision;
        _pending.removeAt(0);
        continue;
      }
      _retryRequired = true;
      _offlineObservedForRetry = _connectivity != ChatConnectivityStatus.online;
      _report(
        const ChatScopeIntegrationDiagnostic(
          code: ChatScopeIntegrationDiagnosticCode.pushTokenRegistrationFailed,
          message: 'The chat push token could not be synchronized.',
        ),
      );
      return;
    }
  }

  Future<_PushDispatchResult?> _dispatch(
    _PendingPushToken pending,
    ChatCommandCancellationSignal cancellationSignal,
  ) async {
    final token = pending.value;
    if (_registered == null) {
      final result = await client.registerPushToken(
        RegisterDevicePushTokenInput(
          deviceId: deviceId,
          platform: token.platform,
          provider: token.provider,
          environment: token.environment,
          token: token.token,
          tokenRevision: _revision + 1,
          idempotencyKey: _key('register', pending.sequence),
        ),
        cancellationSignal: cancellationSignal,
      );
      return switch (result) {
        ChatCommandSuccess<DevicePushTokenResult>(:final value) =>
          _PushDispatchResult.success(value.devicePushToken.tokenRevision),
        ChatCommandAborted<DevicePushTokenResult>() when !_hasAuthority => null,
        _ => const _PushDispatchResult.failure(),
      };
    }

    final result = await client.rotatePushToken(
      unregister: UnregisterDevicePushTokenInput(
        deviceId: deviceId,
        tokenRevision: _revision + 1,
        idempotencyKey: _key('rotate-unregister', pending.sequence),
      ),
      replacement: RegisterDevicePushTokenInput(
        deviceId: deviceId,
        platform: token.platform,
        provider: token.provider,
        environment: token.environment,
        token: token.token,
        tokenRevision: _revision + 2,
        idempotencyKey: _key('rotate-register', pending.sequence),
      ),
      cancellationSignal: cancellationSignal,
    );
    return switch (result) {
      ChatCommandSuccess<ChatPushTokenRotationResult>(:final value) =>
        _PushDispatchResult.success(
          value.registered.devicePushToken.tokenRevision,
        ),
      ChatCommandAborted<ChatPushTokenRotationResult>() when !_hasAuthority =>
        null,
      _ => const _PushDispatchResult.failure(),
    };
  }

  String _key(String operation, int sequence) =>
      'chat-scope-push-$operation-$sequence';

  bool get _hasAuthority => !_disposed && isAuthoritative();

  bool get _canDispatch =>
      _hasAuthority &&
      !_logoutStarted &&
      _foreground &&
      _connectivity == ChatConnectivityStatus.online &&
      !_retryRequired;

  void _report(ChatScopeIntegrationDiagnostic diagnostic) {
    if (!_hasAuthority) return;
    try {
      onDiagnostic(diagnostic);
    } catch (_) {
      // Diagnostics never alter push-token orchestration.
    }
  }
}

final class _PushDispatchResult {
  const _PushDispatchResult.success(this.revision) : success = true;
  const _PushDispatchResult.failure()
      : success = false,
        revision = 0;

  final bool success;
  final int revision;
}

Future<void> _safelyDisposeRealtime(
  ChatRealtimeSessionTransport? session,
) async {
  try {
    await session?.dispose();
  } catch (_) {
    // Owned realtime resources are considered released after disposal.
  }
}

Future<void> _safelySuspendRealtime(
  ChatRealtimeSessionTransport session,
) async {
  try {
    await session.suspend();
  } catch (_) {
    // Suspension is best-effort; lifecycle authority still prevents recovery.
  }
}

DeviceId _validatedDeviceId(String value) {
  if (value.isEmpty ||
      value != value.trim() ||
      value.length > 256 ||
      RegExp(r'[\u0000-\u0020\u007f]').hasMatch(value)) {
    throw const FormatException('Invalid device ID.');
  }
  return DeviceId(value);
}

bool _isApplicationForeground(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed;
