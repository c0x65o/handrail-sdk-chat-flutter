part of '../handrail_chat_client.dart';

/// Serializes every read-modify-write transaction against the one shared
/// identity-scoped message-mutation record.
///
/// Feature runtimes deliberately retain only their own typed projections, so
/// they must re-read the complete record while holding this gate before
/// replacing it. This prevents concurrent edit/delete persistence from
/// dropping unrelated mutation intents.
final class _MessageMutationIntentStorageCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
