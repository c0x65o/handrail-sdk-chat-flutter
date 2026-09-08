import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:handrail_chat/ui.dart';
import 'package:web/web.dart' as web;

import 'browser_transport.dart';
import 'reply_contexts.dart';
import 'thread_lifecycles.dart';

@JS('handrailBackendLab')
external set backendLabBridge(JSFunction? function);

const _defaultActors = {
  'ada': 'Ada Lovelace',
  'grace': 'Grace Hopper',
  'margaret': 'Margaret Hamilton',
};
const _replyStylesActors = {
  'alice': 'Alice', 'bob': 'Bob', 'carol': 'Carol', 'dave': 'Dave',
};
const _provenance = {
  'sourceRevision': String.fromEnvironment('HANDRAIL_SOURCE_REVISION'),
  'sourceDigest': String.fromEnvironment('HANDRAIL_SOURCE_DIGEST'),
  'builtAt': String.fromEnvironment('HANDRAIL_BUILD_TIME'),
  'packageVersion': handrailChatPackageVersion,
};

class BackendChatLab extends StatefulWidget {
  const BackendChatLab({super.key});

  @override
  State<BackendChatLab> createState() => _BackendChatLabState();
}

class _BackendChatLabState extends State<BackendChatLab> {
  final _workspaceKey = GlobalKey<HandrailChatWorkspaceState>();
  final _transport = BrowserChatTransport();
  final _cursor = LabCursorStorage();
  final _captures = <Map<String, Object?>>[];
  final _diagnostics = <String>[];
  HandrailChatClient? _client;
  BackendLabReplyContexts? _replyContexts;
  BackendLabThreadLifecycles? _threadLifecycles;
  ChatRealtimeSessionTransport? _session;
  ChatConversationListController? _list;
  Timer? _instancePoll;
  String? _instanceId;
  String? _seedProfile;
  Map<String, String> _actors = const {};
  ConversationId? _initialConversationId;
  String _actor = '';
  String? _error;
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    backendLabBridge = ((JSString request) =>
        _command(jsonDecode(request.toDart) as Map<String, dynamic>)
            .then((value) => jsonEncode(value).toJS)
            .toJS).toJS;
    unawaited(_open());
  }

  Future<String> _get(String path) async {
    final response = await _transport.send(HandrailChatHttpRequest(
      method: 'GET',
      uri: Uri.base.resolve(path),
      headers: const {},
    ));
    if (response.statusCode != 200) {
      throw StateError('Chat Lab request failed (${response.statusCode}).');
    }
    return response.body;
  }

  Future<({String id, String? seedProfile})> _readInstance() async {
    final value = jsonDecode(await _get('/__chat-lab/instance'));
    final id = value['instanceId'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw StateError('Invalid Chat Lab instance.');
    }
    return (id: id, seedProfile: value['seedProfile'] as String?);
  }

  void _diagnose(String code) {
    _diagnostics.add(code);
    if (_diagnostics.length > 100) _diagnostics.removeAt(0);
  }

  Future<void> _open() async {
    try {
      final instance = await _readInstance();
      if (!mounted) return;
      _instanceId = instance.id;
      _seedProfile = instance.seedProfile;
      final replyStyles = _seedProfile == 'reply-styles';
      _actors = replyStyles ? _replyStylesActors : _defaultActors;
      _actor = Uri.base.queryParameters['actor'] ??
          (replyStyles ? 'alice' : 'grace');
      if (!_actors.containsKey(_actor)) {
        throw StateError('Unknown Chat Lab actor.');
      }
      final endpoint = Uri.base.resolve('/api/chat');
      Future<String> token() => _get('/__chat-lab/session?actor=$_actor');
      final session = ChatRealtimeSessionTransport(
        endpoint: endpoint,
        clientPackageVersion: handrailChatPackageVersion,
        protocolVersion: handrailChatProtocolVersion,
        tokenProvider: token,
        socketFactory: BrowserChatSocket.open,
        cursorStorage: _cursor,
        cursorStorageScope: 'chat-lab:$_instanceId:$_actor',
        onDiagnostic: (diagnostic) => _diagnose(diagnostic.code),
        onStateChange: (state) {
          if (state is ChatRealtimeHydratingSnapshotState && _list != null) {
            final diagnostic = state.diagnostic;
            if (diagnostic != null) {
              _diagnose('recovery:${diagnostic.code.wireValue}:${diagnostic.eventType}');
            }
            _capture('before-managed-snapshot-hydration');
          }
          if (mounted) setState(() {});
        },
      );
      _session = session;
      final client = HandrailChatClient(
        apiBaseUri: endpoint,
        tokenProvider: token,
        transport: _transport,
        realtimeSession: session,
        requestedCapabilities: {
          messageSearchFeature: true,
          if (replyStyles) ChatReplyThreadFeatures.threadLifecycle: true,
        },
        conversationPreferenceClock: () =>
            const IsoTimestamp('2026-08-28T12:00:00.000Z'),
        onSnapshotQueryDiagnostic: (diagnostic) =>
            _diagnose('${diagnostic.query.value}:${diagnostic.event.value}'),
      );
      _client = client;
      _replyContexts = BackendLabReplyContexts(client, session);
      if (replyStyles) {
        _threadLifecycles = BackendLabThreadLifecycles(client, session);
      }
      if (await client.initialize() is! ChatClientReadyState) {
        throw StateError('Chat Lab client initialization failed.');
      }
      if (!mounted) return;
      final list = ChatConversationListController(
        client: client,
        scope: const OrganizationConversationSnapshotScope(),
      );
      _list = list;
      var state = await list.refresh();
      final requested = Uri.base.queryParameters['conversation'];
      // Resolve IDs from the authenticated backend, including paginated lists.
      bool matches(ChatConversationListItem item) => requested == null
          ? item.displayName ==
              (replyStyles ? 'Launch planning' : 'Chat Lab General')
          : item.conversationId.value == requested;
      while (!state.items.any(matches) && state.hasMore) {
        state = await list.loadMore();
        if (state.error != null) break;
      }
      if (!state.items.any(matches)) {
        throw StateError('The requested Chat Lab conversation is unavailable.');
      }
      _initialConversationId = state.items.firstWhere(matches).conversationId;
      if (!mounted) return;
      _capture('before-parent-hydration');
      await session.start();
      if (!mounted) return;
      setState(() => _ready = true);
      _instancePoll = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          if ((await _readInstance()).id != _instanceId && mounted) {
            web.window.location.reload();
          }
        } catch (_) {
          // A transient server restart must not discard the retained cache.
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not connect to Chat Lab. Check the actor, conversation and backend service, then reload.');
      }
    }
  }

  Map<String, Object?> _status() {
    final client = _client;
    if (client == null) return {'realtime': 'initializing', 'error': _error};
    // This dev-only bridge intentionally uses the workspace's QA selector.
    // ignore: invalid_use_of_visible_for_testing_member
    final selected = _workspaceKey.currentState?.selectedConversationId ??
        _initialConversationId;
    final store = client.normalizedState;
    final canonical = store.canonicalPersistenceSnapshot();
    final identity = switch (_session!.state) {
      ChatRealtimeConnectedState(:final identity) => {
          'tenantId': identity.tenantId.value,
          'userId': identity.userId.value,
          'deviceId': identity.deviceId.value,
        },
      _ => null,
    };
    return {
      'mode': 'shared-backend',
      'actor': _actor,
      'instanceId': _instanceId,
      'seedProfile': _seedProfile,
      'availableActors': _actors,
      'endpoint': client.apiBaseUri.toString(),
      'identity': identity,
      'realtime': _session!.state.state,
      'clientLifecycle': client.state.state,
      'clientDiagnostic': switch (client.state) {
        ChatClientErrorState(:final diagnostic) => diagnostic.code,
        _ => null,
      },
      'listError': _list?.state.error?.code.name,
      'error': _error,
      'selectedConversationId': selected?.value,
      'conversationIds':
          _list?.state.items.map((i) => i.conversationId.value).toList() ?? [],
      'hydratedTimelineIds':
          store.state.timelines.keys.map((id) => id.value).toList(),
      'cursor': _cursor.value == null ? null : jsonDecode(_cursor.value!),
      'timelineReplayCursor': selected == null
          ? null
          : store.timeline(selected).replayCursor?.toJson(),
      'durableStreams': {
        for (final entry in store.state.durableStreams.entries)
          entry.key: {
            'lastEventId': entry.value.lastEventId,
            'lastOccurredAt': entry.value.lastOccurredAt.value
          },
      },
      'messages': [
        if (selected != null)
          for (final message in store.timeline(selected).messages)
            {
              'id': message.id.value,
              'canonicalSummary': canonical
                  .canonicalMessages[message.id]?.threadSummary
                  ?.toJson(),
              'projectedSummary': message.threadSummary?.toJson(),
            },
      ],
      'diagnostics': [..._diagnostics],
      'provenance': _provenance,
    };
  }

  Map<String, Object?> _capture(String label) {
    final result = {
      'label': label,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      ..._status()
    };
    _captures.add(result);
    if (_captures.length > 100) _captures.removeAt(0);
    return result;
  }

  Future<Map<String, Object?>> _command(Map<String, dynamic> request) async {
    switch (request['operation']) {
      case 'status':
        return _status();
      case 'capture':
        return _capture(request['label'] as String? ?? 'manual');
      case 'export':
        return {
          'captures': [..._captures],
          'current': _status()
        };
      case 'suspend':
        _capture('before-disconnect');
        await _session!.suspend();
        return _capture('disconnected');
      case 'reconnect':
        _capture('before-reconnect');
        final connected = await _session!
            .resumeFromCursor()
            .timeout(const Duration(seconds: 30));
        if (!connected) {
          throw StateError('Chat Lab reconnect was not accepted.');
        }
        return _capture('reconnected');
      case 'hydrate':
        final id = ConversationId(request['conversationId'] as String);
        _capture('before-explicit-hydration:${id.value}');
        final state = await _client!.timelines.forConversation(id).refresh();
        final result = {
          ..._capture('after-explicit-hydration:${id.value}'),
          'hydrationStatus': state.status.name,
          'hydrationError': state.error?.code.name,
        };
        _captures[_captures.length - 1] = result;
        return result;
      default:
        throw ArgumentError('Unknown Chat Lab operation.');
    }
  }

  Future<void> _action(String operation) async {
    setState(() => _busy = true);
    try {
      final result = await _command({'operation': operation});
      if (operation == 'export') {
        final url = web.URL.createObjectURL(web.Blob(
          [const JsonEncoder.withIndent('  ').convert(result).toJS].toJS,
          web.BlobPropertyBag(type: 'application/json'),
        ));
        web.HTMLAnchorElement()
          ..href = url
          ..download = 'flutter-backend-evidence.json'
          ..click();
        web.URL.revokeObjectURL(url);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'The lab action failed. Retry or inspect the exported diagnostics.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    backendLabBridge = null;
    _instancePoll?.cancel();
    unawaited(_disposeRuntime());
    super.dispose();
  }

  Future<void> _disposeRuntime() async {
    await _replyContexts?.dispose();
    await _threadLifecycles?.dispose();
    await _session?.dispose();
    await _list?.dispose();
    await _client?.timelines.dispose();
    await _client?.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true, colorSchemeSeed: const Color(0xff4f46e5)),
        home: Scaffold(
          appBar:
              AppBar(title: const Text('Flutter Chat Lab · shared backend')),
          body: Column(children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String>(
                      value: _actors.containsKey(_actor) ? _actor : null,
                      hint: const Text('Fixture actor'),
                      items: _actors.entries
                          .map((entry) => DropdownMenuItem(
                                value: entry.key,
                                child: Text(entry.value),
                              ))
                          .toList(),
                      onChanged: (actor) {
                        if (actor == null) return;
                        web.window.location.href =
                            Uri.base.replace(queryParameters: {
                          ...Uri.base.queryParameters,
                          'actor': actor,
                        }).toString();
                      },
                    ),
                    Text(
                        'Managed realtime: ${_session?.state.state ?? 'connecting'}'),
                    if (_ready) ...[
                      OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _action(_session!.isStarted
                                  ? 'suspend'
                                  : 'reconnect'),
                          child: Text(_session!.isStarted
                              ? 'Disconnect'
                              : 'Reconnect')),
                      OutlinedButton(
                          onPressed: _busy ? null : () => _action('capture'),
                          child: const Text('Capture state')),
                      OutlinedButton(
                          onPressed: _busy ? null : () => _action('export'),
                          child: const Text('Export evidence')),
                    ],
                  ],
                )),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
            Expanded(
                child: _ready
                    ? ChatScope(
                        client: _client!,
                        child: HandrailChatWorkspace(
                          key: _workspaceKey,
                          initialConversationId: _initialConversationId,
                          conversationListController: _list,
                        ))
                    : _error == null
                        ? const Center(child: CircularProgressIndicator())
                        : const SizedBox.shrink()),
          ]),
        ),
      );
}
