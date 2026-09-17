import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:handrail_chat/ui.dart';
import 'package:handrail_chat/media.dart';
import 'package:web/web.dart' as web;

bool get _hostAvailable => globalContext.has('handrailCreateFlutterMediaHost');

@JS('handrailCreateFlutterMediaHost')
external _BrowserMediaHost _createHost(
    web.HTMLElement element, JSFunction changed);

extension type _BrowserMediaHost(JSObject _) implements JSObject {
  external JSPromise<JSAny?> connect(String descriptor, String expiresAt);
  external JSPromise<JSString?> microphone(bool enabled);
  external JSPromise<JSString?> prepareScreen();
  external JSPromise<JSString?> screen(bool enabled);
  external JSPromise<JSString?> input(String? id);
  external JSPromise<JSString?> output(String? id);
  external JSPromise<JSAny?> close();
}

Future<void>? _loading;
Future<void> _loadHost() => _loading ??= (() async {
      if (_hostAvailable) return;
      final script = web.HTMLScriptElement()
        ..type = 'module'
        ..src = Uri.base.resolve('/src/chat-lab-flutter-media.ts').toString();
      final ready = Completer<void>();
      script.onload = ((web.Event _) => ready.complete()).toJS;
      script.onerror = ((web.Event _) =>
          ready.completeError(StateError('Media host unavailable'))).toJS;
      web.document.head!.append(script);
      try {
        await ready.future.timeout(const Duration(seconds: 15));
        if (!_hostAvailable) throw StateError('Media host unavailable');
      } finally {
        script.onload = null;
        script.onerror = null;
        script.remove();
      }
    })()
        .catchError((Object error) {
      _loading = null;
      throw error;
    });

ChatMediaException _failure(ChatMediaOperation operation, String? code) =>
    ChatMediaException(ChatMediaFailure(
      code: code == 'permission_denied'
          ? ChatMediaErrorCode.permissionDenied
          : ChatMediaErrorCode.providerFailure,
      operation: operation,
      message: code == 'permission_denied'
          ? 'The required media permission was not granted.'
          : 'Browser media is unavailable. Leave and join the huddle again.',
      retryable: true,
    ));

/// Browser reference host. Capture, RTP and playback use the same real WebRTC
/// adapter as React; the SDK remains provider-neutral. No native-device claim.
class _BackendLabMediaDelegate implements ChatMediaDelegate {
  _BackendLabMediaDelegate(this.element, this.onState);
  final web.HTMLElement element;
  final void Function(Map<String, dynamic>) onState;
  _BrowserMediaSession? current;

  @override
  Future<ChatMediaPermissionDecision> requestPermission(
      ChatMediaPermission permission) async {
    if (permission == ChatMediaPermission.camera) {
      return ChatMediaPermissionDecision.restricted;
    }
    // Prepare display capture before the canonical ownership HTTP request,
    // while the user's activation is still available. Never publish it yet.
    if (permission == ChatMediaPermission.screenShare) {
      await current!.prepareScreen();
    }
    // Microphone permission is requested by getUserMedia at enable time.
    return ChatMediaPermissionDecision.granted;
  }

  @override
  Future<ChatMediaProviderSession> connect(
      HuddleMediaJoinDescriptor descriptor) async {
    _BrowserMediaSession? session;
    try {
      element.setAttribute('data-media-phase', 'loading');
      await _loadHost();
      element.setAttribute('data-media-phase', 'creating');
      await current?.close();
      session = _BrowserMediaSession(element, onState);
      current = session;
      element.setAttribute('data-media-phase', 'connecting');
      await session.host
          .connect(descriptor.descriptor, descriptor.expiresAt.value)
          .toDart;
      element.setAttribute('data-media-phase', 'connected');
      return session;
    } catch (_) {
      element.setAttribute('data-media-phase',
          '${element.getAttribute('data-media-phase')}-failed');
      await session?.close();
      throw _failure(ChatMediaOperation.connect, null);
    }
  }
}

class _BrowserMediaSession implements ChatMediaProviderSession {
  _BrowserMediaSession(
      web.HTMLElement element, void Function(Map<String, dynamic>) changed) {
    host = _createHost(
        element,
        ((JSString json) {
          if (_closed) return;
          final state = jsonDecode(json.toDart) as Map<String, dynamic>;
          final inventory = state['devices'] as Map<String, dynamic>;
          final encodedInventory = jsonEncode(inventory);
          if (_lastDeviceInventory != encodedInventory) {
            _lastDeviceInventory = encodedInventory;
            _devices = ChatMediaDeviceState(
              devices: (inventory['devices'] as List)
                  .map((dynamic device) => ChatMediaDevice(
                        id: device['id'] as String,
                        label: device['label'] as String,
                        kind: switch (device['kind']) {
                          'audio_input' => ChatMediaDeviceKind.audioInput,
                          'audio_output' => ChatMediaDeviceKind.audioOutput,
                          _ => ChatMediaDeviceKind.videoInput,
                        },
                        isDefault: device['isDefault'] == true,
                      )),
              selectedAudioInputId:
                  inventory['selectedAudioInputId'] as String?,
              selectedAudioOutputId:
                  inventory['selectedAudioOutputId'] as String?,
            );
            _changes.add(_devices);
          }
          changed(state);
        }).toJS);
  }
  late final _BrowserMediaHost host;
  final _changes = StreamController<ChatMediaDeviceState>.broadcast();
  ChatMediaDeviceState _devices = ChatMediaDeviceState(devices: const []);
  bool _closed = false;
  String? _lastDeviceInventory;
  Future<void> _run(
      ChatMediaOperation operation, JSPromise<JSString?> result) async {
    final error = (await result.toDart)?.toDart;
    if (error != null) throw _failure(operation, error);
  }

  Future<void> prepareScreen() =>
      _run(ChatMediaOperation.screenShare, host.prepareScreen());
  @override
  ChatMediaProviderState get initialState =>
      ChatMediaProviderState(devices: _devices);
  @override
  Stream<ChatMediaDeviceState> get deviceChanges => _changes.stream;
  @override
  Stream<List<ChatMediaActiveSpeaker>> get activeSpeakerChanges =>
      const Stream.empty();
  @override
  Future<void> setMicrophoneEnabled(bool enabled) =>
      _run(ChatMediaOperation.microphone, host.microphone(enabled));
  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (enabled) throw _failure(ChatMediaOperation.camera, null);
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) =>
      _run(ChatMediaOperation.screenShare, host.screen(enabled));
  @override
  Future<void> selectAudioInput(String? deviceId) =>
      _run(ChatMediaOperation.audioInput, host.input(deviceId));
  @override
  Future<void> selectAudioOutput(String? deviceId) =>
      _run(ChatMediaOperation.audioOutput, host.output(deviceId));
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await host.close().toDart;
    await _changes.close();
  }
}

/// Owns media independently of the details sheet, so closing controls does not
/// interrupt audio. The canonical controller remains owned by the SDK client.
class BackendLabHuddle extends StatefulWidget {
  const BackendLabHuddle(
      {required this.controller,
      required this.label,
      required this.actor,
      super.key});
  final ChatHuddleController controller;
  final String label;
  final UserId actor;
  @override
  State<BackendLabHuddle> createState() => _BackendLabHuddleState();
}

class _BackendLabHuddleState extends State<BackendLabHuddle> {
  final _element = web.HTMLDivElement()..style.overflow = 'auto';
  late final _BackendLabMediaDelegate _delegate;
  late final ChatHuddleMediaSession _session;
  StreamSubscription<ChatMediaSessionState>? _subscription;
  StreamSubscription<ChatHuddleState>? _huddleSubscription;
  bool _closed = false;
  bool _muted = true;
  bool _sharing = false;
  ChatMediaFailure? _lastFailure;
  bool _hydrating = false;

  @override
  void initState() {
    super.initState();
    _delegate = _BackendLabMediaDelegate(_element, _providerChanged);
    _session = ChatHuddleMediaSession(
        controller: widget.controller, delegate: _delegate);
    _subscription = _session.states.listen((state) {
      if (_closed) return;
      _element.setAttribute('data-session-status', state.status.name);
      _element.setAttribute(
          'data-session-failure',
          state.lastFailure == null
              ? ''
              : '${state.lastFailure!.code.name}:${state.lastFailure!.operation.name}');
      final failure = state.lastFailure;
      if (failure != null &&
          !identical(failure, _lastFailure) &&
          failure.operation == ChatMediaOperation.screenShare) {
        // Also releases prepared, unpublished capture after an ownership denial.
        unawaited(_releaseShare());
      }
      _lastFailure = failure;
      setState(() {});
    });
    _huddleSubscription = widget.controller.states.listen((state) {
      _element.setAttribute('data-controller-media', state.media.state);
      if (state.hydrationStatus == ChatHuddleHydrationStatus.idle) _hydrate();
      final canonical = state.canonicalState;
      if (_sharing &&
          canonical is LiveHuddleState &&
          canonical.screenShareOwnerUserId != widget.actor) {
        unawaited(
            _delegate.current?.setScreenShareEnabled(false).catchError((_) {}));
      }
    });
    _hydrate();
  }

  void _hydrate() {
    if (_closed || _hydrating) return;
    _hydrating = true;
    Timer.run(() async {
      try {
        if (!_closed) await widget.controller.hydrate();
      } finally {
        _hydrating = false;
        // Accepted session activation can cancel the first in-flight read.
        // Hydrate again only when that authority reset left it idle.
        if (!_closed &&
            widget.controller.state.hydrationStatus ==
                ChatHuddleHydrationStatus.idle &&
            widget.controller.state.media is! ChatHuddleMediaUnavailableState) {
          _hydrate();
        }
      }
    });
  }

  Future<void> _releaseShare() async {
    final canonical = widget.controller.state.canonicalState;
    final provider = _delegate.current;
    await provider?.setScreenShareEnabled(false).catchError((_) {});
    final current = widget.controller.state.canonicalState;
    if (!_closed &&
        identical(provider, _delegate.current) &&
        canonical is LiveHuddleState &&
        current is LiveHuddleState &&
        canonical.huddleSessionId == current.huddleSessionId &&
        current.screenShareOwnerUserId == widget.actor) {
      await widget.controller.clearScreenShare();
    }
  }

  void _providerChanged(Map<String, dynamic> state) {
    final wasMuted = _muted, wasSharing = _sharing;
    final provider = _delegate.current;
    _muted = state['microphoneMuted'] == true;
    _sharing = state['screenShareActive'] == true;
    // Keep provider callbacks out of the SDK's synchronous stream dispatch.
    scheduleMicrotask(() async {
      if (_closed || !identical(provider, _delegate.current)) return;
      if (state['connectionStatus'] == 'disconnected') {
        await _releaseShare();
        if (!_closed && identical(provider, _delegate.current)) {
          await _session.disconnect();
        }
      } else {
        if (!wasMuted && _muted) {
          await _session.setMicrophoneEnabled(false).catchError((_) {});
        }
        if (!_closed &&
            identical(provider, _delegate.current) &&
            wasSharing &&
            !_sharing) {
          await _session.setScreenShareEnabled(false).catchError((_) {});
        }
      }
    });
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_subscription?.cancel());
    unawaited(_huddleSubscription?.cancel());
    unawaited(_session.close().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        TextButton.icon(
          icon: const Icon(Icons.headset_mic_outlined),
          label: Text('Huddle · ${widget.label} · browser WebRTC'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => SafeArea(
                child: SizedBox(
                    height: 540,
                    child: SingleChildScrollView(
                      child: HandrailHuddlePanel(
                          controller: widget.controller,
                          mediaSession: _session),
                    ))),
          ),
        ),
        SizedBox(
          height: _session.state.status == ChatMediaSessionStatus.connected
              ? 110
              : 1,
          child: HtmlElementView.fromTagName(
              tagName: 'div',
              onElementCreated: (element) {
                (element as web.HTMLElement).append(_element);
              }),
        ),
      ]);
}
