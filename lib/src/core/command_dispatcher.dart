import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../handrail_chat_client.dart';

/// HTTP methods supported by the generic command boundary.
enum ChatCommandMethod {
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE');

  const ChatCommandMethod(this.value);

  final String value;
}

/// Commands are retried only when their descriptor explicitly opts in.
enum ChatCommandRetrySafety { safe, never }

typedef ChatCommandInputValidator<Input, RequestBody> = RequestBody Function(
  Input input,
);
typedef ChatCommandPathBuilder<RequestBody> = String Function(
  RequestBody input,
);
typedef ChatCommandResultParser<Result> = Result Function(Object? value);
typedef ChatCommandErrorResultParser<Result> = Result? Function(
  Object? value,
  int httpStatus,
);

/// One feature-neutral HTTP command contract.
///
/// Feature libraries own descriptors; the dispatcher owns validation order,
/// authentication, idempotency, retries, cancellation, and response parsing.
final class ChatCommandDescriptor<Input, RequestBody, Result> {
  ChatCommandDescriptor({
    required this.name,
    required this.method,
    required String path,
    required this.retrySafety,
    required this.validateInput,
    required this.parseResult,
    this.parseErrorResult,
  })  : _path = path,
        _pathBuilder = null;

  ChatCommandDescriptor.withPathBuilder({
    required this.name,
    required this.method,
    required ChatCommandPathBuilder<RequestBody> pathBuilder,
    required this.retrySafety,
    required this.validateInput,
    required this.parseResult,
    this.parseErrorResult,
  })  : _path = null,
        _pathBuilder = pathBuilder;

  /// Stable, non-sensitive diagnostic name such as `message.send`.
  final String name;
  final ChatCommandMethod method;
  final ChatCommandRetrySafety retrySafety;
  final ChatCommandInputValidator<Input, RequestBody> validateInput;
  final ChatCommandResultParser<Result> parseResult;
  final ChatCommandErrorResultParser<Result>? parseErrorResult;
  final String? _path;
  final ChatCommandPathBuilder<RequestBody>? _pathBuilder;

  String pathFor(RequestBody input) => _pathBuilder?.call(input) ?? _path!;
}

/// A caller-owned cancellation signal passed through dispatch options.
final class ChatCommandCancellationSignal {
  ChatCommandCancellationSignal._(this._controller);

  final StreamController<void> _controller;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  Stream<void> get onCancelled => _controller.stream;
}

/// Cancels commands without depending on Flutter or a particular HTTP client.
final class ChatCommandCancellationController {
  ChatCommandCancellationController()
      : _streamController = StreamController<void>.broadcast(sync: true) {
    signal = ChatCommandCancellationSignal._(_streamController);
  }

  final StreamController<void> _streamController;
  late final ChatCommandCancellationSignal signal;

  void cancel() {
    if (signal._cancelled) return;
    signal._cancelled = true;
    _streamController.add(null);
    unawaited(_streamController.close());
  }
}

/// Per-dispatch command options.
final class ChatCommandDispatchOptions {
  const ChatCommandDispatchOptions({
    this.idempotencyKey,
    this.cancellationSignal,
  });

  final String? idempotencyKey;
  final ChatCommandCancellationSignal? cancellationSignal;
}

typedef ChatCommandBackoff = Duration Function(int retryNumber);
typedef ChatCommandWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);
typedef ChatCommandIdempotencyKeyGenerator = String Function();
typedef ChatCommandDiagnosticCallback = void Function(
  ChatCommandDiagnostic diagnostic,
);

/// Bounded retry and authentication-refresh behavior.
final class ChatCommandRetryOptions {
  const ChatCommandRetryOptions({
    this.maxAttempts = 3,
    this.maxAuthenticationRefreshes = 1,
    this.backoff,
    this.wait,
  });

  /// Total HTTP attempt budget, including an authentication refresh attempt.
  final int maxAttempts;

  /// Must be zero or one. Authentication refresh never loops.
  final int maxAuthenticationRefreshes;
  final ChatCommandBackoff? backoff;
  final ChatCommandWait? wait;
}

/// Stable diagnostic events emitted by command dispatch.
enum ChatCommandDiagnosticEvent {
  validationFailed('validation_failed'),
  tokenFailed('token_failed'),
  requestFailed('request_failed'),
  retryScheduled('retry_scheduled'),
  authenticationRefresh('auth_refresh'),
  responseRejected('response_rejected'),
  responseMalformed('response_malformed'),
  completed('completed'),
  aborted('aborted'),
  closed('closed');

  const ChatCommandDiagnosticEvent(this.value);
  final String value;
}

/// Result categories shared with the JavaScript command dispatcher.
enum ChatCommandResultCategory {
  success('success'),
  queued('queued'),
  validation('validation'),
  authentication('authentication'),
  conflict('conflict'),
  featureDisabled('feature_disabled'),
  unsupported('unsupported'),
  rejected('rejected'),
  malformedResponse('malformed_response'),
  transport('transport'),
  aborted('aborted'),
  closed('closed');

  const ChatCommandResultCategory(this.value);
  final String value;
}

/// Structurally safe command telemetry.
///
/// This type deliberately has no token, header, body, or thrown-value fields.
final class ChatCommandDiagnostic {
  const ChatCommandDiagnostic({
    required this.event,
    required this.command,
    required this.attempt,
    this.category,
    this.httpStatus,
    this.delay,
  });

  final ChatCommandDiagnosticEvent event;
  final String command;
  final int attempt;
  final ChatCommandResultCategory? category;
  final int? httpStatus;
  final Duration? delay;

  @override
  String toString() =>
      'ChatCommandDiagnostic(event: ${event.value}, command: $command, '
      'attempt: $attempt, category: ${category?.value}, '
      'httpStatus: $httpStatus, delayMs: ${delay?.inMilliseconds})';
}

/// Base result for every command outcome.
sealed class ChatCommandResult<Result> {
  const ChatCommandResult();

  ChatCommandResultCategory get category;
  String get status => category.value;

  @override
  String toString() => '$runtimeType(status: $status)';
}

final class ChatCommandSuccess<Result> extends ChatCommandResult<Result> {
  const ChatCommandSuccess(this.value);

  final Result value;

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.success;
}

/// A retry-stable command intent durably accepted for later dispatch.
///
/// This result carries only opaque command identity and FIFO metadata. Feature
/// state such as authored content remains available from the feature's public
/// queued-state API rather than leaking into the generic dispatcher boundary.
final class ChatCommandQueued<Result> extends ChatCommandResult<Result> {
  const ChatCommandQueued({
    required this.commandId,
    required this.idempotencyKey,
    required this.enqueueOrder,
    required this.enqueuedAt,
  });

  final String commandId;
  final String idempotencyKey;
  final int enqueueOrder;
  final DateTime enqueuedAt;

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.queued;
}

sealed class ChatCommandFailure<Result> extends ChatCommandResult<Result> {
  const ChatCommandFailure(this.message, {this.httpStatus});

  final String message;
  final int? httpStatus;
}

final class ChatCommandValidationFailure<Result>
    extends ChatCommandFailure<Result> {
  const ChatCommandValidationFailure() : super('The command input is invalid.');

  @override
  ChatCommandResultCategory get category =>
      ChatCommandResultCategory.validation;
}

final class ChatCommandAuthenticationFailure<Result>
    extends ChatCommandFailure<Result> {
  const ChatCommandAuthenticationFailure({super.httpStatus})
      : super('Chat authentication failed.');

  @override
  ChatCommandResultCategory get category =>
      ChatCommandResultCategory.authentication;
}

final class ChatCommandConflict<Result> extends ChatCommandFailure<Result> {
  const ChatCommandConflict({required int httpStatus})
      : super(
          'The command conflicts with current server state.',
          httpStatus: httpStatus,
        );

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.conflict;
}

final class ChatCommandFeatureDisabled<Result>
    extends ChatCommandFailure<Result> {
  const ChatCommandFeatureDisabled({required int httpStatus})
      : super(
          'The requested chat feature is disabled.',
          httpStatus: httpStatus,
        );

  @override
  ChatCommandResultCategory get category =>
      ChatCommandResultCategory.featureDisabled;
}

final class ChatCommandUnsupported<Result> extends ChatCommandFailure<Result> {
  const ChatCommandUnsupported({required int httpStatus})
      : super(
          'The requested chat command is unsupported.',
          httpStatus: httpStatus,
        );

  @override
  ChatCommandResultCategory get category =>
      ChatCommandResultCategory.unsupported;
}

final class ChatCommandRejected<Result> extends ChatCommandFailure<Result> {
  const ChatCommandRejected({required int httpStatus})
      : super('The chat server rejected the command.', httpStatus: httpStatus);

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.rejected;
}

final class ChatCommandMalformedResponse<Result>
    extends ChatCommandFailure<Result> {
  const ChatCommandMalformedResponse({super.httpStatus})
      : super('The chat server returned an invalid command response.');

  @override
  ChatCommandResultCategory get category =>
      ChatCommandResultCategory.malformedResponse;
}

final class ChatCommandTransportFailure<Result>
    extends ChatCommandFailure<Result> {
  const ChatCommandTransportFailure({super.httpStatus})
      : super('The chat command could not be completed.');

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.transport;
}

final class ChatCommandAborted<Result> extends ChatCommandFailure<Result> {
  const ChatCommandAborted() : super('The chat command was aborted.');

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.aborted;
}

final class ChatCommandClosed<Result> extends ChatCommandFailure<Result> {
  const ChatCommandClosed() : super('The chat client was closed.');

  @override
  ChatCommandResultCategory get category => ChatCommandResultCategory.closed;
}

final class _CommandInterrupted implements Exception {
  const _CommandInterrupted();
}

final class _ParsedServerError {
  const _ParsedServerError({required this.code, required this.refreshable});

  final String code;
  final bool refreshable;
}

final class _ActiveCommand {
  _ActiveCommand() : controller = ChatCommandCancellationController();

  final ChatCommandCancellationController controller;
  bool closed = false;
}

const Set<int> _transientHttpStatuses = <int>{408, 425, 429, 502, 503, 504};
final RegExp _commandNamePattern = RegExp(r'^[a-z][a-z0-9._-]{0,79}$');
final RegExp _idempotencyKeyPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$',
);

/// Injectable, Flutter-independent authenticated HTTP command dispatcher.
final class ChatCommandDispatcher {
  ChatCommandDispatcher({
    required this.apiBaseUri,
    required this.tokenProvider,
    required this.transport,
    this.retryOptions = const ChatCommandRetryOptions(),
    ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
    ChatCommandDiagnosticCallback? onDiagnostic,
  })  : _generateIdempotencyKey =
            generateIdempotencyKey ?? _generateSecureIdempotencyKey,
        _onDiagnostic = onDiagnostic {
    if (retryOptions.maxAttempts < 1 || retryOptions.maxAttempts > 10) {
      throw ArgumentError.value(
        retryOptions.maxAttempts,
        'retryOptions.maxAttempts',
        'must be from 1 to 10',
      );
    }
    if (retryOptions.maxAuthenticationRefreshes != 0 &&
        retryOptions.maxAuthenticationRefreshes != 1) {
      throw ArgumentError.value(
        retryOptions.maxAuthenticationRefreshes,
        'retryOptions.maxAuthenticationRefreshes',
        'must be zero or one',
      );
    }
  }

  final Uri apiBaseUri;
  final HandrailChatAccessTokenProvider tokenProvider;
  final HandrailChatHttpTransport transport;
  final ChatCommandRetryOptions retryOptions;
  final ChatCommandIdempotencyKeyGenerator _generateIdempotencyKey;
  final ChatCommandDiagnosticCallback? _onDiagnostic;
  final Set<_ActiveCommand> _activeCommands = <_ActiveCommand>{};

  Future<ChatCommandResult<Result>> dispatch<Input, RequestBody, Result>(
    ChatCommandDescriptor<Input, RequestBody, Result> descriptor,
    Input input, {
    ChatCommandDispatchOptions options = const ChatCommandDispatchOptions(),
  }) async {
    final diagnosticName = _commandNamePattern.hasMatch(descriptor.name)
        ? descriptor.name
        : 'invalid.command';

    late final RequestBody validatedInput;
    late final String body;
    late final String path;
    late final String idempotencyKey;
    try {
      if (!_commandNamePattern.hasMatch(descriptor.name)) {
        throw const FormatException();
      }
      validatedInput = descriptor.validateInput(input);
      body = jsonEncode(validatedInput);
      path = descriptor.pathFor(validatedInput);
      if (!_isValidPath(path)) throw const FormatException();
      idempotencyKey = options.idempotencyKey ?? _generateIdempotencyKey();
      if (!_idempotencyKeyPattern.hasMatch(idempotencyKey)) {
        throw const FormatException();
      }
    } catch (_) {
      _diagnose(
        ChatCommandDiagnostic(
          event: ChatCommandDiagnosticEvent.validationFailed,
          command: diagnosticName,
          attempt: 0,
          category: ChatCommandResultCategory.validation,
        ),
      );
      return ChatCommandValidationFailure<Result>();
    }

    final active = _ActiveCommand();
    StreamSubscription<void>? callerCancellation;
    final callerSignal = options.cancellationSignal;
    if (callerSignal != null) {
      callerCancellation = callerSignal.onCancelled.listen((_) {
        active.controller.cancel();
      });
      if (callerSignal.isCancelled) active.controller.cancel();
    }
    _activeCommands.add(active);

    var attempt = 0;
    var retryNumber = 0;
    var authenticationRefreshes = 0;
    var accessToken = '';
    var interruptionDiagnosed = false;

    ChatCommandResult<Result>? interruption() {
      if (!active.controller.signal.isCancelled) return null;
      final result = active.closed
          ? ChatCommandClosed<Result>()
          : ChatCommandAborted<Result>();
      if (!interruptionDiagnosed) {
        interruptionDiagnosed = true;
        _diagnose(
          ChatCommandDiagnostic(
            event: active.closed
                ? ChatCommandDiagnosticEvent.closed
                : ChatCommandDiagnosticEvent.aborted,
            command: diagnosticName,
            attempt: attempt,
            category: result.category,
          ),
        );
      }
      return result;
    }

    Future<bool> obtainToken() async {
      try {
        final token = await _raceWithCancellation(
          Future<String>.sync(tokenProvider),
          active.controller.signal,
        );
        if (token.trim().isEmpty) throw const FormatException();
        accessToken = token;
        return true;
      } catch (_) {
        if (interruption() != null) return false;
        _diagnose(
          ChatCommandDiagnostic(
            event: ChatCommandDiagnosticEvent.tokenFailed,
            command: diagnosticName,
            attempt: attempt,
            category: ChatCommandResultCategory.authentication,
          ),
        );
        return false;
      }
    }

    Future<bool> scheduleRetry() async {
      retryNumber += 1;
      late final Duration delay;
      try {
        delay = (retryOptions.backoff ?? _defaultBackoff)(retryNumber);
        if (delay.isNegative || delay > const Duration(seconds: 60)) {
          throw const FormatException();
        }
      } catch (_) {
        return false;
      }
      _diagnose(
        ChatCommandDiagnostic(
          event: ChatCommandDiagnosticEvent.retryScheduled,
          command: diagnosticName,
          attempt: attempt,
          category: ChatCommandResultCategory.transport,
          delay: delay,
        ),
      );
      try {
        await _raceWithCancellation(
          Future<void>.sync(
            () => (retryOptions.wait ?? _defaultWait)(
              delay,
              active.controller.signal,
            ),
          ),
          active.controller.signal,
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      if (!await obtainToken()) {
        return interruption() ?? ChatCommandAuthenticationFailure<Result>();
      }

      while (attempt < retryOptions.maxAttempts) {
        final beforeAttempt = interruption();
        if (beforeAttempt != null) return beforeAttempt;
        attempt += 1;

        late final HandrailChatHttpResponse response;
        try {
          response = await _raceWithCancellation(
            transport.send(
              HandrailChatHttpRequest(
                method: descriptor.method.value,
                uri: _commandUri(apiBaseUri, path),
                headers: <String, String>{
                  'Accept': 'application/json',
                  'Authorization': 'Bearer $accessToken',
                  'Idempotency-Key': idempotencyKey,
                  'Content-Type': 'application/json',
                },
                body: body,
                cancellationSignal: active.controller.signal,
              ),
            ),
            active.controller.signal,
          );
        } catch (_) {
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnose(
            ChatCommandDiagnostic(
              event: ChatCommandDiagnosticEvent.requestFailed,
              command: diagnosticName,
              attempt: attempt,
              category: ChatCommandResultCategory.transport,
            ),
          );
          if (descriptor.retrySafety == ChatCommandRetrySafety.safe &&
              attempt < retryOptions.maxAttempts &&
              await scheduleRetry()) {
            continue;
          }
          return interruption() ?? ChatCommandTransportFailure<Result>();
        }

        if (response.statusCode < 100 || response.statusCode > 599) {
          _diagnoseMalformed(diagnosticName, attempt);
          return ChatCommandMalformedResponse<Result>();
        }

        if (_transientHttpStatuses.contains(response.statusCode)) {
          if (descriptor.retrySafety == ChatCommandRetrySafety.safe &&
              attempt < retryOptions.maxAttempts &&
              await scheduleRetry()) {
            continue;
          }
          return interruption() ??
              ChatCommandTransportFailure<Result>(
                httpStatus: response.statusCode,
              );
        }

        late final Object? decoded;
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {
          final stopped = interruption();
          if (stopped != null) return stopped;
          _diagnoseMalformed(
            diagnosticName,
            attempt,
            httpStatus: response.statusCode,
          );
          return ChatCommandMalformedResponse<Result>(
            httpStatus: response.statusCode,
          );
        }
        final afterDecode = interruption();
        if (afterDecode != null) return afterDecode;

        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            final value = descriptor.parseResult(decoded);
            final stopped = interruption();
            if (stopped != null) return stopped;
            _diagnose(
              ChatCommandDiagnostic(
                event: ChatCommandDiagnosticEvent.completed,
                command: diagnosticName,
                attempt: attempt,
              ),
            );
            return ChatCommandSuccess<Result>(value);
          } catch (_) {
            final stopped = interruption();
            if (stopped != null) return stopped;
            _diagnoseMalformed(
              diagnosticName,
              attempt,
              httpStatus: response.statusCode,
            );
            return ChatCommandMalformedResponse<Result>(
              httpStatus: response.statusCode,
            );
          }
        }

        final parseErrorResult = descriptor.parseErrorResult;
        if (parseErrorResult != null) {
          try {
            final value = parseErrorResult(decoded, response.statusCode);
            final stopped = interruption();
            if (stopped != null) return stopped;
            if (value != null) {
              _diagnose(
                ChatCommandDiagnostic(
                  event: ChatCommandDiagnosticEvent.completed,
                  command: diagnosticName,
                  attempt: attempt,
                ),
              );
              return ChatCommandSuccess<Result>(value);
            }
          } catch (_) {
            final stopped = interruption();
            if (stopped != null) return stopped;
            _diagnoseMalformed(
              diagnosticName,
              attempt,
              httpStatus: response.statusCode,
            );
            return ChatCommandMalformedResponse<Result>(
              httpStatus: response.statusCode,
            );
          }
        }

        final serverError = _parseServerError(decoded);
        if (serverError == null) {
          _diagnoseMalformed(
            diagnosticName,
            attempt,
            httpStatus: response.statusCode,
          );
          return ChatCommandMalformedResponse<Result>(
            httpStatus: response.statusCode,
          );
        }

        if (response.statusCode == 401 &&
            serverError.refreshable &&
            authenticationRefreshes < retryOptions.maxAuthenticationRefreshes &&
            attempt < retryOptions.maxAttempts) {
          authenticationRefreshes += 1;
          _diagnose(
            ChatCommandDiagnostic(
              event: ChatCommandDiagnosticEvent.authenticationRefresh,
              command: diagnosticName,
              attempt: attempt,
              category: ChatCommandResultCategory.authentication,
              httpStatus: response.statusCode,
            ),
          );
          if (await obtainToken()) continue;
          return interruption() ??
              ChatCommandAuthenticationFailure<Result>(
                httpStatus: response.statusCode,
              );
        }

        final result = _classifyHttpFailure<Result>(
          response.statusCode,
          serverError.code,
        );
        _diagnose(
          ChatCommandDiagnostic(
            event: ChatCommandDiagnosticEvent.responseRejected,
            command: diagnosticName,
            attempt: attempt,
            category: result.category,
            httpStatus: response.statusCode,
          ),
        );
        return result;
      }
      return ChatCommandTransportFailure<Result>();
    } finally {
      await callerCancellation?.cancel();
      _activeCommands.remove(active);
    }
  }

  /// Cancels all currently active commands as `closed` without making this
  /// reusable dispatcher terminal.
  void closeActive() {
    for (final active in _activeCommands.toList(growable: false)) {
      active.closed = true;
      active.controller.cancel();
    }
  }

  void _diagnose(ChatCommandDiagnostic diagnostic) {
    try {
      _onDiagnostic?.call(diagnostic);
    } catch (_) {
      // Diagnostics are observational; thrown values may contain secrets.
    }
  }

  void _diagnoseMalformed(
    String command,
    int attempt, {
    int? httpStatus,
  }) {
    _diagnose(
      ChatCommandDiagnostic(
        event: ChatCommandDiagnosticEvent.responseMalformed,
        command: command,
        attempt: attempt,
        category: ChatCommandResultCategory.malformedResponse,
        httpStatus: httpStatus,
      ),
    );
  }
}

Duration _defaultBackoff(int retryNumber) => Duration(
      milliseconds: min(1000, 100 * pow(2, retryNumber - 1).toInt()),
    );

Future<void> _defaultWait(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
) =>
    _raceWithCancellation(
      Future<void>.delayed(delay),
      cancellationSignal,
    );

Future<Value> _raceWithCancellation<Value>(
  Future<Value> future,
  ChatCommandCancellationSignal signal,
) {
  if (signal.isCancelled) {
    return Future<Value>.error(const _CommandInterrupted());
  }
  final completer = Completer<Value>();
  late final StreamSubscription<void> subscription;
  subscription = signal.onCancelled.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(const _CommandInterrupted());
    }
  });
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  ).whenComplete(subscription.cancel);
  return completer.future;
}

bool _isValidPath(String path) {
  if (!path.startsWith('/') || path.startsWith('//')) return false;
  if (path.contains(RegExp(r'[\s?#]'))) return false;
  return !path.split('/').contains('..');
}

Uri _commandUri(Uri baseUri, String commandPath) {
  var endpoint = baseUri.toString();
  final fragmentStart = endpoint.indexOf('#');
  if (fragmentStart >= 0) endpoint = endpoint.substring(0, fragmentStart);
  final queryStart = endpoint.indexOf('?');
  if (queryStart >= 0) endpoint = endpoint.substring(0, queryStart);
  while (endpoint.endsWith('/')) {
    endpoint = endpoint.substring(0, endpoint.length - 1);
  }
  return Uri.parse('$endpoint$commandPath');
}

_ParsedServerError? _parseServerError(Object? value) {
  if (value is! Map || value.length != 1 || !value.containsKey('error')) {
    return null;
  }
  final error = value['error'];
  if (error is! Map ||
      (error.length != 2 && error.length != 3) ||
      !error.containsKey('code') ||
      !error.containsKey('message') ||
      (error.length == 3 && !error.containsKey('refreshable'))) {
    return null;
  }
  final code = error['code'];
  final message = error['message'];
  final refreshable = error['refreshable'];
  if (code is! String ||
      code.trim().isEmpty ||
      message is! String ||
      message.trim().isEmpty ||
      (error.containsKey('refreshable') && refreshable is! bool)) {
    return null;
  }
  return _ParsedServerError(
    code: code,
    refreshable: refreshable == true,
  );
}

ChatCommandResult<Result> _classifyHttpFailure<Result>(
  int httpStatus,
  String errorCode,
) {
  final normalizedCode = errorCode.toUpperCase();
  if (httpStatus == 409) {
    return ChatCommandConflict<Result>(httpStatus: httpStatus);
  }
  if (normalizedCode.contains('FEATURE_DISABLED')) {
    return ChatCommandFeatureDisabled<Result>(httpStatus: httpStatus);
  }
  if (httpStatus == 404 ||
      httpStatus == 405 ||
      httpStatus == 501 ||
      normalizedCode.contains('UNSUPPORTED')) {
    return ChatCommandUnsupported<Result>(httpStatus: httpStatus);
  }
  if (httpStatus == 401 || httpStatus == 403) {
    return ChatCommandAuthenticationFailure<Result>(httpStatus: httpStatus);
  }
  if (httpStatus >= 400 && httpStatus < 500) {
    return ChatCommandRejected<Result>(httpStatus: httpStatus);
  }
  return ChatCommandTransportFailure<Result>(httpStatus: httpStatus);
}

String _generateSecureIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
