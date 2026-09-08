import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'package:flutter/material.dart';
import 'controller.dart';
import 'indexed_db_storage.dart';

@JS('handrailStorageLab')
external set storageLabBridge(JSFunction? function);

const _provenance = {
  'sourceRevision': String.fromEnvironment('HANDRAIL_SOURCE_REVISION',
      defaultValue: 'unattested'),
  'sourceDigest': String.fromEnvironment('HANDRAIL_SOURCE_DIGEST',
      defaultValue: 'unattested'),
  'builtAt':
      String.fromEnvironment('HANDRAIL_BUILD_TIME', defaultValue: 'unattested'),
};

class SharedStorageLab extends StatefulWidget {
  const SharedStorageLab({super.key});
  @override
  State<SharedStorageLab> createState() => _SharedStorageLabState();
}

class _SharedStorageLabState extends State<SharedStorageLab> {
  StorageLabController? _controller;
  Map<String, Object?> _status = {};
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final query = Uri.base.queryParameters;
      final namespace = query['namespace'] ?? 'round12';
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(namespace)) {
        throw ArgumentError(
            'Use a namespace of 1–80 letters, digits, underscores or hyphens');
      }
      final writer =
          '${query['writer'] ?? 'writer'}-${DateTime.now().microsecondsSinceEpoch}';
      final storage = await IndexedDbChatStorage.open(namespace, writer);
      final controller = StorageLabController(storage);
      _controller = controller;
      await controller.start();
      await storage.note({
        'operation': 'build',
        ..._provenance,
        'adapter': IndexedDbChatStorage.adapterId,
        'namespace': namespace
      });
      // A narrow JSON bridge lets browser QA drive real Dart clients in two
      // engines without depending on canvas coordinates or private SDK state.
      storageLabBridge = ((JSString request) {
        return _run(jsonDecode(request.toDart) as Map<String, dynamic>)
            .then((result) => jsonEncode(result).toJS)
            .toJS;
      }).toJS;
      await _refresh();
      _poll = Timer.periodic(
          const Duration(seconds: 1), (_) => unawaited(_refresh()));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<Map<String, Object?>> _run(Map<String, dynamic> request) async {
    final result = {
      ...await _controller!.command(request),
      'provenance': _provenance
    };
    if (mounted) setState(() => _status = result);
    return result;
  }

  Future<void> _refresh() async {
    try {
      final status = await _controller!.status();
      if (mounted) setState(() => _status = status);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _action(Map<String, dynamic> command) async {
    try {
      await _run(command);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _export() async {
    final evidence = await _run({'operation': 'export'});
    final url = web.URL.createObjectURL(web.Blob(
        [
          const JsonEncoder.withIndent('  ').convert(evidence).toJS,
        ].toJS,
        web.BlobPropertyBag(type: 'application/json')));
    web.HTMLAnchorElement()
      ..href = url
      ..download = 'shared-storage-evidence.json'
      ..click();
    web.URL.revokeObjectURL(url);
  }

  @override
  void dispose() {
    _poll?.cancel();
    storageLabBridge = null;
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true, colorSchemeSeed: const Color(0xff4f46e5)),
        home: Scaffold(
          appBar: AppBar(title: const Text('Flutter shared-storage lab')),
          body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Durable IndexedDB · two independent Flutter writers'),
                  const SizedBox(height: 8),
                  const Text(
                      'Open this URL in two tabs of the same browser profile. '
                      'Both use the same namespace and tenant/user/device fixture. '
                      'Starts offline on every engine restart. Network and canonical '
                      'responses are controlled fixtures; storage is real IndexedDB.'),
                  const SizedBox(height: 12),
                  SelectableText('Adapter: ${IndexedDbChatStorage.adapterId}\n'
                      'Revision: ${_provenance['sourceRevision']}\n'
                      'Source SHA-256: ${_provenance['sourceDigest']}\n'
                      'Built: ${_provenance['builtAt']}'),
                  const SizedBox(height: 12),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  if (_status.isEmpty)
                    const CircularProgressIndicator()
                  else ...[
                    Text(
                        'Network: ${_status['online'] == true ? 'online' : 'offline'} · '
                        'Recovery: ${_status['recovery']}'),
                    Text(
                        'Database: ${_status['database']}\nWriter: ${_status['writer']}'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton(
                          onPressed: () => _action({'operation': 'send'}),
                          child: const Text('Queue send')),
                      OutlinedButton(
                          onPressed: () => _action({'operation': 'read'}),
                          child: const Text('Mark read through 4')),
                      OutlinedButton(
                          onPressed: () => _action({
                                'operation': 'online',
                                'value': _status['online'] != true
                              }),
                          child: Text(_status['online'] == true
                              ? 'Go offline'
                              : 'Reconnect')),
                      OutlinedButton(
                          onPressed: () => web.window.open(
                              Uri.base.replace(queryParameters: {
                                ...Uri.base.queryParameters,
                                'writer': 'second'
                              }).toString(),
                              '_blank'),
                          child: const Text('Open second writer')),
                      OutlinedButton(
                          onPressed: _export,
                          child: const Text('Export evidence')),
                    ]),
                    for (final id in (_status['queuedSendIds'] as List? ?? []))
                      TextButton(
                          onPressed: () =>
                              _action({'operation': 'cancel', 'id': id}),
                          child: Text('Cancel $id')),
                    const SizedBox(height: 12),
                    SelectableText(const JsonEncoder.withIndent('  ').convert({
                      'records': _status['records'],
                      'canonicalLedger': _status['ledger'],
                    })),
                  ],
                ],
              )),
        ),
      );
}
