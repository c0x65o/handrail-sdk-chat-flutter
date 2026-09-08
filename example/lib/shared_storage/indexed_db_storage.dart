// Browser-only dev adapter. Keep the SDK itself platform independent.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'package:handrail_chat/core.dart';

/// Separate connections/Flutter engines serialize through IndexedDB itself.
/// Completion means the strict read/write transaction has committed. No
/// process-local mutex or read/modify/write across transactions is used.
final class IndexedDbChatStorage implements AtomicApplicationChatStorage {
  IndexedDbChatStorage._(this.database, this.writer);
  static const adapterId = 'indexeddb-exact-cas-strict-v1';
  final web.IDBDatabase database;
  final String writer;
  String? pauseKind;
  String? pausePhase;
  Completer<void>? _gate;
  bool get paused => _gate != null;

  static Future<IndexedDbChatStorage> open(
      String namespace, String writer) async {
    final request =
        web.window.indexedDB.open('handrail-shared-storage-$namespace', 1);
    request.onupgradeneeded = ((web.Event event) {
      final db = request.result as web.IDBDatabase;
      for (final name in ['records', 'trace', 'ledger']) {
        db.createObjectStore(
            name, web.IDBObjectStoreParameters(autoIncrement: name == 'trace'));
      }
    }).toJS;
    final db = await requestValue(request) as web.IDBDatabase;
    return IndexedDbChatStorage._(db, writer);
  }

  web.IDBTransaction transaction(List<String> stores) {
    final tx = database.transaction(stores.map((s) => s.toJS).toList().toJS,
        'readwrite', web.IDBTransactionOptions(durability: 'strict'));
    if (tx.durability != 'strict') {
      tx.abort();
      throw StateError(
          'This browser does not support strict IndexedDB durability');
    }
    return tx;
  }

  String key(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      jsonEncode([
        identity.tenantId.value,
        identity.userId.value,
        identity.deviceId.value,
        kind.name
      ]);

  Future<void> _pause(
      String phase, ApplicationChatStorageRecordKind kind) async {
    if (pauseKind != kind.name || pausePhase != phase) return;
    pauseKind = null;
    pausePhase = null;
    final gate = _gate = Completer<void>();
    await gate.future;
    _gate = null;
  }

  void release() => _gate?.complete();

  void trace(web.IDBTransaction tx, Map<String, Object?> entry) {
    tx.objectStore('trace').add(jsonEncode({
          'writer': writer,
          'at': DateTime.now().toUtc().toIso8601String(),
          ...entry,
        }).toJS);
  }

  Future<void> note(Map<String, Object?> entry) async {
    final tx = transaction(['trace']);
    final committed = transactionComplete(tx);
    trace(tx, entry);
    await committed;
  }

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final tx = transaction(['records', 'trace']);
    final committed = transactionComplete(tx);
    final value = (await requestValue(
            tx.objectStore('records').get(key(identity, kind).toJS)))
        ?.dartify() as String?;
    trace(tx, {'operation': 'read', 'kind': kind.name, 'value': value});
    await committed;
    // Gates are deliberately outside the database transaction: another engine
    // can replace the value while this reader holds its stale observation.
    await _pause('read', kind);
    return value;
  }

  @override
  Future<bool> compareExchange(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind,
      String? expected,
      String? replacement) async {
    if (replacement != null) _validate(identity, kind, replacement);
    await _pause('cas', kind);
    final tx = transaction(['records', 'trace']);
    final committed = transactionComplete(tx);
    final store = tx.objectStore('records');
    final address = key(identity, kind);
    final actual =
        (await requestValue(store.get(address.toJS)))?.dartify() as String?;
    final exchanged = actual == expected;
    if (exchanged) {
      if (replacement == null) {
        store.delete(address.toJS);
      } else {
        store.put(replacement.toJS, address.toJS);
      }
    }
    trace(tx, {
      'operation': 'cas',
      'kind': kind.name,
      'expected': expected,
      'actual': actual,
      'replacement': replacement,
      'exchanged': exchanged
    });
    await committed;
    return exchanged;
  }

  void _validate(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind, String encoded) {
    final record = ApplicationChatStorageRecord.decode(encoded);
    if (record.identity != identity || record.kind != kind) {
      throw const FormatException('Storage identity/kind mismatch');
    }
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
      ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final value = await readEncoded(identity, kind);
    if (value == null) return null;
    _validate(identity, kind, value);
    return ApplicationChatStorageRecord.decode(value);
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      writeFixture(record.identity, record.kind, record.encode());

  /// Explicit fault injection, available only inside this dev lab.
  Future<void> writeFixture(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind, String? value) async {
    final tx = transaction(['records', 'trace']);
    final committed = transactionComplete(tx);
    if (value == null) {
      tx.objectStore('records').delete(key(identity, kind).toJS);
    } else {
      tx.objectStore('records').put(value.toJS, key(identity, kind).toJS);
    }
    trace(
        tx, {'operation': 'fixture-write', 'kind': kind.name, 'value': value});
    await committed;
  }

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
          ApplicationChatStorageRecordKind kind) =>
      writeFixture(identity, kind, null);

  @override
  Future<void> clearForLogout(
      ApplicationChatStorageIdentity previousIdentity) async {
    final tx = transaction(['records', 'trace']);
    final committed = transactionComplete(tx);
    for (final kind in ApplicationChatStorageRecordKind.values) {
      tx.objectStore('records').delete(key(previousIdentity, kind).toJS);
    }
    trace(tx,
        {'operation': 'clear-identity', 'identity': previousIdentity.toJson()});
    await committed;
  }

  @override
  Future<void> clearForIdentityChange(
      {required ApplicationChatStorageIdentity previousIdentity,
      required ApplicationChatStorageIdentity nextIdentity}) async {
    if (previousIdentity != nextIdentity) {
      await clearForLogout(previousIdentity);
    }
  }

  Future<List<Object?>> entries(String store) async {
    final tx = database.transaction(store.toJS, 'readonly');
    final committed = transactionComplete(tx);
    final values =
        (await requestValue(tx.objectStore(store).getAll()) as JSArray).toDart;
    await committed;
    return values.map((value) {
      try {
        return jsonDecode((value as JSString).toDart);
      } on FormatException {
        return {'malformed': true};
      }
    }).toList();
  }
}

Future<JSAny?> requestValue(web.IDBRequest request) {
  final result = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => result.complete(request.result)).toJS;
  request.onerror = ((web.Event _) => result.completeError(
      StateError(request.error?.name ?? 'IndexedDB request failed'))).toJS;
  return result.future;
}

Future<void> transactionComplete(web.IDBTransaction tx) {
  final result = Completer<void>();
  tx.oncomplete = ((web.Event _) => result.complete()).toJS;
  tx.onabort = ((web.Event _) {
    if (!result.isCompleted) {
      result.completeError(
          StateError(tx.error?.name ?? 'IndexedDB transaction aborted'));
    }
  }).toJS;
  return result.future;
}
