import 'dart:async';

import '../core.dart';

/// One provider-issued token and the non-secret routing values it requires.
///
/// The token is wrapped immediately so ordinary diagnostics and string
/// interpolation cannot reveal the provider credential.
final class ChatPushToken {
  ChatPushToken({
    required String token,
    required this.platform,
    required this.provider,
    required this.environment,
  }) : token = OpaquePushToken(token);

  final OpaquePushToken token;
  final DevicePlatform platform;
  final DevicePushProvider provider;
  final DevicePushProviderEnvironment environment;

  @override
  bool operator ==(Object other) =>
      other is ChatPushToken &&
      other.token == token &&
      other.platform == platform &&
      other.provider == provider &&
      other.environment == environment;

  @override
  int get hashCode => Object.hash(token, platform, provider, environment);

  @override
  String toString() => 'ChatPushToken(token: $token, '
      'platform: ${platform.wireValue}, provider: ${provider.wireValue}, '
      'environment: ${environment.wireValue})';
}

/// Supplies push credentials without coupling Handrail Chat to a provider SDK.
///
/// Implementations own notification permission and provider initialization.
/// ChatScope only reads the current value and observes rotations.
abstract interface class ChatPushTokenDelegate {
  FutureOr<ChatPushToken?> getInitialPushToken({
    required Object? identityScopeKey,
  });

  Stream<ChatPushToken> get pushTokenRotations;
}
