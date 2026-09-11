import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// Native ColorScheme members take precedence on Flutter 3.22 and later,
// preserving host overrides. Flutter 3.19 uses its existing surface roles.
extension HandrailCompatibleSurfaceColors on ColorScheme {
  Color get surfaceContainer => surface;
  Color get surfaceContainerLow => surface;
  // ignore: deprecated_member_use
  Color get surfaceContainerHigh => surfaceVariant;
  // ignore: deprecated_member_use
  Color get surfaceContainerHighest => surfaceVariant;
}

/// Typography tokens used by Handrail Chat UI implementations.
@immutable
class HandrailChatTypography {
  const HandrailChatTypography({
    required this.message,
    required this.metadata,
    required this.conversationTitle,
    required this.composer,
  });

  /// Creates chat typography from the host application's text theme.
  factory HandrailChatTypography.fromTheme(TextTheme textTheme) {
    return HandrailChatTypography(
      message: textTheme.bodyMedium ?? const TextStyle(fontSize: 14),
      metadata: textTheme.bodySmall ?? const TextStyle(fontSize: 12),
      conversationTitle: textTheme.titleMedium ?? const TextStyle(fontSize: 16),
      composer: textTheme.bodyLarge ?? const TextStyle(fontSize: 16),
    );
  }

  final TextStyle message;
  final TextStyle metadata;
  final TextStyle conversationTitle;
  final TextStyle composer;

  HandrailChatTypography copyWith({
    TextStyle? message,
    TextStyle? metadata,
    TextStyle? conversationTitle,
    TextStyle? composer,
  }) {
    return HandrailChatTypography(
      message: message ?? this.message,
      metadata: metadata ?? this.metadata,
      conversationTitle: conversationTitle ?? this.conversationTitle,
      composer: composer ?? this.composer,
    );
  }

  HandrailChatTypography lerp(HandrailChatTypography other, double t) {
    return HandrailChatTypography(
      message: TextStyle.lerp(message, other.message, t)!,
      metadata: TextStyle.lerp(metadata, other.metadata, t)!,
      conversationTitle:
          TextStyle.lerp(conversationTitle, other.conversationTitle, t)!,
      composer: TextStyle.lerp(composer, other.composer, t)!,
    );
  }
}

/// Layout spacing tokens used by Handrail Chat UI implementations.
@immutable
class HandrailChatSpacing {
  const HandrailChatSpacing({
    this.extraSmall = 4,
    this.small = 8,
    this.medium = 12,
    this.large = 16,
    this.extraLarge = 24,
  });

  final double extraSmall;
  final double small;
  final double medium;
  final double large;
  final double extraLarge;

  HandrailChatSpacing copyWith({
    double? extraSmall,
    double? small,
    double? medium,
    double? large,
    double? extraLarge,
  }) {
    return HandrailChatSpacing(
      extraSmall: extraSmall ?? this.extraSmall,
      small: small ?? this.small,
      medium: medium ?? this.medium,
      large: large ?? this.large,
      extraLarge: extraLarge ?? this.extraLarge,
    );
  }

  HandrailChatSpacing lerp(HandrailChatSpacing other, double t) {
    return HandrailChatSpacing(
      extraSmall: lerpDouble(extraSmall, other.extraSmall, t)!,
      small: lerpDouble(small, other.small, t)!,
      medium: lerpDouble(medium, other.medium, t)!,
      large: lerpDouble(large, other.large, t)!,
      extraLarge: lerpDouble(extraLarge, other.extraLarge, t)!,
    );
  }
}

/// Corner-radius tokens used by Handrail Chat UI implementations.
@immutable
class HandrailChatRadii {
  const HandrailChatRadii({
    this.small = 4,
    this.medium = 8,
    this.large = 16,
    this.messageBubble = 12,
  });

  final double small;
  final double medium;
  final double large;
  final double messageBubble;

  HandrailChatRadii copyWith({
    double? small,
    double? medium,
    double? large,
    double? messageBubble,
  }) {
    return HandrailChatRadii(
      small: small ?? this.small,
      medium: medium ?? this.medium,
      large: large ?? this.large,
      messageBubble: messageBubble ?? this.messageBubble,
    );
  }

  HandrailChatRadii lerp(HandrailChatRadii other, double t) {
    return HandrailChatRadii(
      small: lerpDouble(small, other.small, t)!,
      medium: lerpDouble(medium, other.medium, t)!,
      large: lerpDouble(large, other.large, t)!,
      messageBubble: lerpDouble(messageBubble, other.messageBubble, t)!,
    );
  }
}

/// Animation timing tokens used by Handrail Chat UI implementations.
///
/// [HandrailChatTheme.of] returns zero durations and sets [animationsEnabled]
/// to false when Flutter reports that animations should be disabled.
@immutable
class HandrailChatMotion {
  const HandrailChatMotion({
    this.messageTransitionDuration = const Duration(milliseconds: 180),
    this.panelTransitionDuration = const Duration(milliseconds: 240),
    this.animationsEnabled = true,
  });

  final Duration messageTransitionDuration;
  final Duration panelTransitionDuration;
  final bool animationsEnabled;

  HandrailChatMotion copyWith({
    Duration? messageTransitionDuration,
    Duration? panelTransitionDuration,
    bool? animationsEnabled,
  }) {
    return HandrailChatMotion(
      messageTransitionDuration:
          messageTransitionDuration ?? this.messageTransitionDuration,
      panelTransitionDuration:
          panelTransitionDuration ?? this.panelTransitionDuration,
      animationsEnabled: animationsEnabled ?? this.animationsEnabled,
    );
  }

  HandrailChatMotion lerp(HandrailChatMotion other, double t) {
    return HandrailChatMotion(
      messageTransitionDuration: _lerpDuration(
        messageTransitionDuration,
        other.messageTransitionDuration,
        t,
      ),
      panelTransitionDuration: _lerpDuration(
        panelTransitionDuration,
        other.panelTransitionDuration,
        t,
      ),
      animationsEnabled: t < 0.5 ? animationsEnabled : other.animationsEnabled,
    );
  }
}

/// Color, border, and inset tokens for sent and received message bubbles.
@immutable
class HandrailChatMessageBubbleStyle {
  const HandrailChatMessageBubbleStyle({
    required this.sentBackgroundColor,
    required this.sentForegroundColor,
    required this.receivedBackgroundColor,
    required this.receivedForegroundColor,
    required this.borderColor,
    this.borderWidth = 1,
    this.sentPadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.receivedPadding =
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  /// Creates message-bubble tokens from a host color scheme.
  factory HandrailChatMessageBubbleStyle.fromColorScheme(
    ColorScheme colorScheme, {
    bool highContrast = false,
  }) {
    return HandrailChatMessageBubbleStyle(
      sentBackgroundColor: colorScheme.primary,
      sentForegroundColor: colorScheme.onPrimary,
      receivedBackgroundColor: highContrast
          ? colorScheme.surface
          : colorScheme.surfaceContainerHighest,
      receivedForegroundColor:
          highContrast ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
      borderColor:
          highContrast ? colorScheme.onSurface : colorScheme.outlineVariant,
      borderWidth: highContrast ? 2 : 1,
    );
  }

  final Color sentBackgroundColor;
  final Color sentForegroundColor;
  final Color receivedBackgroundColor;
  final Color receivedForegroundColor;
  final Color borderColor;
  final double borderWidth;
  final EdgeInsets sentPadding;
  final EdgeInsets receivedPadding;

  HandrailChatMessageBubbleStyle copyWith({
    Color? sentBackgroundColor,
    Color? sentForegroundColor,
    Color? receivedBackgroundColor,
    Color? receivedForegroundColor,
    Color? borderColor,
    double? borderWidth,
    EdgeInsets? sentPadding,
    EdgeInsets? receivedPadding,
  }) {
    return HandrailChatMessageBubbleStyle(
      sentBackgroundColor: sentBackgroundColor ?? this.sentBackgroundColor,
      sentForegroundColor: sentForegroundColor ?? this.sentForegroundColor,
      receivedBackgroundColor:
          receivedBackgroundColor ?? this.receivedBackgroundColor,
      receivedForegroundColor:
          receivedForegroundColor ?? this.receivedForegroundColor,
      borderColor: borderColor ?? this.borderColor,
      borderWidth: borderWidth ?? this.borderWidth,
      sentPadding: sentPadding ?? this.sentPadding,
      receivedPadding: receivedPadding ?? this.receivedPadding,
    );
  }

  HandrailChatMessageBubbleStyle lerp(
    HandrailChatMessageBubbleStyle other,
    double t,
  ) {
    return HandrailChatMessageBubbleStyle(
      sentBackgroundColor:
          Color.lerp(sentBackgroundColor, other.sentBackgroundColor, t)!,
      sentForegroundColor:
          Color.lerp(sentForegroundColor, other.sentForegroundColor, t)!,
      receivedBackgroundColor: Color.lerp(
        receivedBackgroundColor,
        other.receivedBackgroundColor,
        t,
      )!,
      receivedForegroundColor: Color.lerp(
        receivedForegroundColor,
        other.receivedForegroundColor,
        t,
      )!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t)!,
      sentPadding: EdgeInsets.lerp(sentPadding, other.sentPadding, t)!,
      receivedPadding:
          EdgeInsets.lerp(receivedPadding, other.receivedPadding, t)!,
    );
  }
}

/// Fully resolved chat design tokens for the current Flutter build context.
@immutable
class HandrailChatThemeData {
  const HandrailChatThemeData({
    required this.typography,
    required this.spacing,
    required this.radii,
    required this.messageBubbleStyle,
    required this.motion,
    required this.brightness,
    required this.highContrast,
  });

  final HandrailChatTypography typography;
  final HandrailChatSpacing spacing;
  final HandrailChatRadii radii;
  final HandrailChatMessageBubbleStyle messageBubbleStyle;
  final HandrailChatMotion motion;
  final Brightness brightness;
  final bool highContrast;

  HandrailChatThemeData copyWith({
    HandrailChatTypography? typography,
    HandrailChatSpacing? spacing,
    HandrailChatRadii? radii,
    HandrailChatMessageBubbleStyle? messageBubbleStyle,
    HandrailChatMotion? motion,
    Brightness? brightness,
    bool? highContrast,
  }) {
    return HandrailChatThemeData(
      typography: typography ?? this.typography,
      spacing: spacing ?? this.spacing,
      radii: radii ?? this.radii,
      messageBubbleStyle: messageBubbleStyle ?? this.messageBubbleStyle,
      motion: motion ?? this.motion,
      brightness: brightness ?? this.brightness,
      highContrast: highContrast ?? this.highContrast,
    );
  }

  HandrailChatThemeData lerp(HandrailChatThemeData other, double t) {
    return HandrailChatThemeData(
      typography: typography.lerp(other.typography, t),
      spacing: spacing.lerp(other.spacing, t),
      radii: radii.lerp(other.radii, t),
      messageBubbleStyle: messageBubbleStyle.lerp(other.messageBubbleStyle, t),
      motion: motion.lerp(other.motion, t),
      brightness: t < 0.5 ? brightness : other.brightness,
      highContrast: t < 0.5 ? highContrast : other.highContrast,
    );
  }
}

/// Optional Handrail Chat overrides stored in Flutter's [ThemeData].
///
/// Omitted token groups are resolved from the nearest host [ThemeData]. Add an
/// instance to [ThemeData.extensions], then use [HandrailChatTheme.of] to read
/// fully resolved tokens. The lookup also honors the nearest [MediaQuery]'s
/// high-contrast and reduced-motion accessibility settings.
@immutable
class HandrailChatTheme extends ThemeExtension<HandrailChatTheme> {
  const HandrailChatTheme({
    this.typography,
    this.spacing,
    this.radii,
    this.messageBubbleStyle,
    this.motion,
  });

  final HandrailChatTypography? typography;
  final HandrailChatSpacing? spacing;
  final HandrailChatRadii? radii;
  final HandrailChatMessageBubbleStyle? messageBubbleStyle;
  final HandrailChatMotion? motion;

  /// Resolves defaults and overrides for [themeData].
  HandrailChatThemeData resolve(
    ThemeData themeData, {
    bool highContrast = false,
    bool disableAnimations = false,
  }) {
    final resolvedMotion = motion ?? const HandrailChatMotion();

    return HandrailChatThemeData(
      typography:
          typography ?? HandrailChatTypography.fromTheme(themeData.textTheme),
      spacing: spacing ?? const HandrailChatSpacing(),
      radii: radii ?? const HandrailChatRadii(),
      messageBubbleStyle: messageBubbleStyle ??
          HandrailChatMessageBubbleStyle.fromColorScheme(
            themeData.colorScheme,
            highContrast: highContrast,
          ),
      motion: disableAnimations
          ? resolvedMotion.copyWith(
              messageTransitionDuration: Duration.zero,
              panelTransitionDuration: Duration.zero,
              animationsEnabled: false,
            )
          : resolvedMotion,
      brightness: themeData.brightness,
      highContrast: highContrast,
    );
  }

  /// Returns fully resolved chat tokens for the nearest Flutter theme.
  static HandrailChatThemeData of(BuildContext context) {
    final themeData = Theme.of(context);
    final mediaQuery = MediaQuery.maybeOf(context);
    final extension = themeData.extension<HandrailChatTheme>();

    return (extension ?? const HandrailChatTheme()).resolve(
      themeData,
      highContrast: mediaQuery?.highContrast ?? false,
      disableAnimations: mediaQuery?.disableAnimations ?? false,
    );
  }

  @override
  HandrailChatTheme copyWith({
    HandrailChatTypography? typography,
    HandrailChatSpacing? spacing,
    HandrailChatRadii? radii,
    HandrailChatMessageBubbleStyle? messageBubbleStyle,
    HandrailChatMotion? motion,
  }) {
    return HandrailChatTheme(
      typography: typography ?? this.typography,
      spacing: spacing ?? this.spacing,
      radii: radii ?? this.radii,
      messageBubbleStyle: messageBubbleStyle ?? this.messageBubbleStyle,
      motion: motion ?? this.motion,
    );
  }

  @override
  HandrailChatTheme lerp(covariant HandrailChatTheme? other, double t) {
    if (other == null) return this;

    return HandrailChatTheme(
      typography: _lerpNullable(
        typography,
        other.typography,
        t,
        (a, b, value) => a.lerp(b, value),
      ),
      spacing: _lerpNullable(
        spacing,
        other.spacing,
        t,
        (a, b, value) => a.lerp(b, value),
      ),
      radii: _lerpNullable(
        radii,
        other.radii,
        t,
        (a, b, value) => a.lerp(b, value),
      ),
      messageBubbleStyle: _lerpNullable(
        messageBubbleStyle,
        other.messageBubbleStyle,
        t,
        (a, b, value) => a.lerp(b, value),
      ),
      motion: _lerpNullable(
        motion,
        other.motion,
        t,
        (a, b, value) => a.lerp(b, value),
      ),
    );
  }
}

Duration _lerpDuration(Duration a, Duration b, double t) {
  return Duration(
    microseconds: lerpDouble(a.inMicroseconds, b.inMicroseconds, t)!.round(),
  );
}

T? _lerpNullable<T>(
  T? a,
  T? b,
  double t,
  T Function(T a, T b, double t) lerp,
) {
  if (a == null || b == null) return t < 0.5 ? a : b;
  return lerp(a, b, t);
}
