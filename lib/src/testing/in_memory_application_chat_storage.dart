import 'dart:convert';

import '../core/application_chat_storage.dart';

/// Deterministic storage adapter for focused tests only.
///
/// Applications must provide their own durable [ApplicationChatStorage]
/// implementation. This helper deliberately makes no production database
/// choice.
final class InMemoryApplicationChatStorage
    implements AtomicApplicationChatStorage {
  final Map<String, String> _records = {};

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    final encoded = _records[_key(identity, kind)];
    if (encoded == null) return null;
    final record = ApplicationChatStorageRecord.decode(encoded);
    if (record.identity != identity || record.kind != kind) {
      throw const FormatException(
        'Stored application chat record does not match its storage scope.',
      );
    }
    return record;
  }

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    final encoded = record.encode();
    _records[_key(record.identity, record.kind)] = encoded;
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async {
    _records.remove(_key(identity, kind));
  }

  @override
  Future<String?> readEncoded(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) async =>
      _records[_key(identity, kind)];

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expectedEncodedRecord,
    String? replacementEncodedRecord,
  ) async {
    final expected = _validateExpectedEncodedRecordForKey(
      expectedEncodedRecord,
      identity,
      kind,
      'expected value',
    );
    final replacement = _validateEncodedRecordForKey(
      replacementEncodedRecord,
      identity,
      kind,
      'replacement',
    );
    final key = _key(identity, kind);
    if (_records[key] != expected) return false;
    if (replacement == null) {
      _records.remove(key);
    } else {
      _records[key] = replacement;
    }
    return true;
  }

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) async {
    _removeIdentity(previousIdentity);
  }

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) async {
    if (previousIdentity != nextIdentity) _removeIdentity(previousIdentity);
  }

  /// Installs raw JSON under an explicit scope to test corrupt-record handling.
  void putRawRecordForTesting(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    Object? json,
  ) {
    _records[_key(identity, kind)] = jsonEncode(json);
  }

  /// Returns a detached raw JSON value for schema assertions in tests.
  Object? rawRecordForTesting(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) {
    final encoded = _records[_key(identity, kind)];
    return encoded == null ? null : jsonDecode(encoded);
  }

  void _removeIdentity(ApplicationChatStorageIdentity identity) {
    final prefix = '${jsonEncode(identity.toJson())}\u0000';
    _records.removeWhere((key, _) => key.startsWith(prefix));
  }
}

String _key(
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
) =>
    '${jsonEncode(identity.toJson())}\u0000${kind.wireValue}';

String? _validateEncodedRecordForKey(
  String? encoded,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
  String role,
) {
  if (encoded == null) return null;
  final record = ApplicationChatStorageRecord.decode(encoded);
  if (record.identity != identity || record.kind != kind) {
    throw FormatException(
      'Application chat storage compareExchange $role does not match its key.',
    );
  }
  return encoded;
}

String? _validateExpectedEncodedRecordForKey(
  String? encoded,
  ApplicationChatStorageIdentity identity,
  ApplicationChatStorageRecordKind kind,
  String role,
) {
  if (encoded == null) return null;
  ApplicationChatStorageRecord record;
  try {
    record = ApplicationChatStorageRecord.decode(encoded);
  } on FormatException {
    return encoded;
  }
  if (record.identity != identity || record.kind != kind) {
    throw FormatException(
      'Application chat storage compareExchange $role does not match its key.',
    );
  }
  return encoded;
}
