import '../../core.dart';
import '../../media.dart';
import '../chat_application_connectivity.dart';

/// A structurally redacted diagnostic captured by test code.
final class RecordedChatDiagnostic {
  RecordedChatDiagnostic({
    required this.source,
    required this.code,
    Map<String, Object?> fields = const <String, Object?>{},
  }) : fields = Map<String, Object?>.unmodifiable(fields);

  final String source;
  final String code;
  final Map<String, Object?> fields;

  @override
  String toString() =>
      'RecordedChatDiagnostic(source: $source, code: $code, fields: $fields)';
}

/// Records only stable diagnostic structure, never messages or thrown values.
final class CredentialSafeDiagnosticRecorder {
  final List<RecordedChatDiagnostic> _records = <RecordedChatDiagnostic>[];

  List<RecordedChatDiagnostic> get records =>
      List<RecordedChatDiagnostic>.unmodifiable(_records);

  void recordClient(ChatClientDiagnostic diagnostic) => _add(
        'client',
        diagnostic.code,
        <String, Object?>{'httpStatus': diagnostic.httpStatus},
      );

  void recordCommand(ChatCommandDiagnostic diagnostic) => _add(
        'command',
        diagnostic.event.value,
        <String, Object?>{
          'command': diagnostic.command,
          'attempt': diagnostic.attempt,
          'category': diagnostic.category?.value,
          'httpStatus': diagnostic.httpStatus,
          'delayMs': diagnostic.delay?.inMilliseconds,
        },
      );

  void recordSnapshot(ChatSnapshotQueryDiagnostic diagnostic) => _add(
        'snapshot',
        diagnostic.event.value,
        <String, Object?>{
          'query': diagnostic.query.value,
          'attempt': diagnostic.attempt,
          'httpStatus': diagnostic.httpStatus,
        },
      );

  void recordRealtime(ChatRealtimeDiagnostic diagnostic) =>
      _add('realtime', diagnostic.code);

  void recordIntegration(ChatScopeIntegrationDiagnostic diagnostic) =>
      _add('integration', diagnostic.code);

  void recordMedia(ChatMediaFailure failure) => _add(
        'media',
        failure.code.name,
        <String, Object?>{
          'operation': failure.operation.name,
          'retryable': failure.retryable,
        },
      );

  /// Records only descriptor presence and expiry, never opaque join material.
  void recordMediaDescriptor(HuddleMediaJoinDescriptor? descriptor) => _add(
        'mediaDescriptor',
        descriptor == null ? 'absent' : 'present',
        <String, Object?>{'expiresAt': descriptor?.expiresAt.value},
      );

  void reset() => _records.clear();

  void _add(
    String source,
    String code, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) =>
      _records.add(
        RecordedChatDiagnostic(source: source, code: code, fields: fields),
      );

  @override
  String toString() => 'CredentialSafeDiagnosticRecorder(records: $_records)';
}
