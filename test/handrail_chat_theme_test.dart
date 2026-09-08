import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

void main() {
  group('HandrailChatTheme resolution', () {
    testWidgets('inherits defaults from the host ThemeData', (tester) async {
      const messageStyle = TextStyle(fontSize: 21, color: Colors.deepOrange);
      final colorScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final theme = ThemeData(
        colorScheme: colorScheme,
        textTheme: ThemeData.light().textTheme.copyWith(
              bodyMedium: messageStyle,
            ),
      );

      final resolved = await _resolveInWidget(tester, theme: theme);

      expect(resolved.typography.message.fontSize, 21);
      expect(resolved.typography.message.color, Colors.deepOrange);
      expect(
          resolved.messageBubbleStyle.sentBackgroundColor, colorScheme.primary);
      expect(
        resolved.messageBubbleStyle.receivedBackgroundColor,
        colorScheme.surfaceContainerHighest,
      );
      expect(resolved.spacing.medium, const HandrailChatSpacing().medium);
      expect(resolved.brightness, Brightness.light);
    });

    testWidgets('applies explicit overrides and derives omitted groups', (
      tester,
    ) async {
      const spacing = HandrailChatSpacing(medium: 30);
      const bubbleStyle = HandrailChatMessageBubbleStyle(
        sentBackgroundColor: Colors.purple,
        sentForegroundColor: Colors.white,
        receivedBackgroundColor: Colors.amber,
        receivedForegroundColor: Colors.black,
        borderColor: Colors.red,
        borderWidth: 3,
      );
      const hostMessageStyle = TextStyle(fontSize: 19);
      final theme = ThemeData(
        textTheme: ThemeData.light().textTheme.copyWith(
              bodyMedium: hostMessageStyle,
            ),
        extensions: const [
          HandrailChatTheme(
            spacing: spacing,
            messageBubbleStyle: bubbleStyle,
          ),
        ],
      );

      final resolved = await _resolveInWidget(tester, theme: theme);

      expect(identical(resolved.spacing, spacing), isTrue);
      expect(identical(resolved.messageBubbleStyle, bubbleStyle), isTrue);
      expect(resolved.typography.message.fontSize, 19);
      expect(resolved.radii.messageBubble,
          const HandrailChatRadii().messageBubble);
    });

    test('resolves light, dark, and high-contrast color behavior', () {
      final lightTheme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
      );
      final darkTheme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      );
      const extension = HandrailChatTheme();

      final light = extension.resolve(lightTheme);
      final dark = extension.resolve(darkTheme);
      final highContrast = extension.resolve(
        darkTheme,
        highContrast: true,
      );

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(
        light.messageBubbleStyle.sentBackgroundColor,
        lightTheme.colorScheme.primary,
      );
      expect(
        dark.messageBubbleStyle.sentBackgroundColor,
        darkTheme.colorScheme.primary,
      );
      expect(
        dark.messageBubbleStyle.receivedBackgroundColor,
        darkTheme.colorScheme.surfaceContainerHighest,
      );
      expect(highContrast.highContrast, isTrue);
      expect(
        highContrast.messageBubbleStyle.receivedBackgroundColor,
        darkTheme.colorScheme.surface,
      );
      expect(
        highContrast.messageBubbleStyle.receivedForegroundColor,
        darkTheme.colorScheme.onSurface,
      );
      expect(highContrast.messageBubbleStyle.borderWidth, 2);
      expect(
        highContrast.messageBubbleStyle.borderColor,
        darkTheme.colorScheme.onSurface,
      );
    });

    testWidgets('disables animation tokens when reduced motion is requested', (
      tester,
    ) async {
      final theme = ThemeData(
        extensions: const [
          HandrailChatTheme(
            motion: HandrailChatMotion(
              messageTransitionDuration: Duration(seconds: 1),
              panelTransitionDuration: Duration(seconds: 2),
            ),
          ),
        ],
      );

      final resolved = await _resolveInWidget(
        tester,
        theme: theme,
        mediaQueryData: const MediaQueryData(disableAnimations: true),
      );

      expect(resolved.motion.animationsEnabled, isFalse);
      expect(resolved.motion.messageTransitionDuration, Duration.zero);
      expect(resolved.motion.panelTransitionDuration, Duration.zero);
    });

    testWidgets('the nearest nested Theme extension overrides its parent', (
      tester,
    ) async {
      const outerSpacing = HandrailChatSpacing(medium: 20);
      const innerSpacing = HandrailChatSpacing(medium: 32);
      const hostMessageStyle = TextStyle(fontSize: 18);
      final outerTheme = ThemeData(
        textTheme: ThemeData.light().textTheme.copyWith(
              bodyMedium: hostMessageStyle,
            ),
        extensions: const [HandrailChatTheme(spacing: outerSpacing)],
      );
      final innerTheme = outerTheme.copyWith(
        extensions: const [HandrailChatTheme(spacing: innerSpacing)],
      );
      late HandrailChatThemeData outer;
      late HandrailChatThemeData inner;

      await tester.pumpWidget(
        MaterialApp(
          theme: outerTheme,
          home: Column(
            children: [
              Builder(
                builder: (context) {
                  outer = HandrailChatTheme.of(context);
                  return const SizedBox.shrink();
                },
              ),
              Theme(
                data: innerTheme,
                child: Builder(
                  builder: (context) {
                    inner = HandrailChatTheme.of(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        ),
      );

      expect(outer.spacing.medium, 20);
      expect(inner.spacing.medium, 32);
      expect(inner.typography.message.fontSize, 18);
    });
  });

  group('theme token value behavior', () {
    test('copyWith retains omitted values and replaces selected values', () {
      const spacing = HandrailChatSpacing(medium: 12, large: 16);
      final changedSpacing = spacing.copyWith(medium: 28);
      expect(changedSpacing.medium, 28);
      expect(changedSpacing.large, 16);

      const theme = HandrailChatTheme(
        spacing: spacing,
        radii: HandrailChatRadii(messageBubble: 14),
      );
      final changedTheme = theme.copyWith(
        motion:
            const HandrailChatMotion(panelTransitionDuration: Duration.zero),
      );
      expect(identical(changedTheme.spacing, spacing), isTrue);
      expect(changedTheme.radii?.messageBubble, 14);
      expect(changedTheme.motion?.panelTransitionDuration, Duration.zero);
    });

    test('lerp interpolates extension and token values', () {
      const start = HandrailChatTheme(
        spacing: HandrailChatSpacing(medium: 0),
        radii: HandrailChatRadii(messageBubble: 4),
        motion: HandrailChatMotion(
          messageTransitionDuration: Duration(milliseconds: 100),
        ),
      );
      const end = HandrailChatTheme(
        spacing: HandrailChatSpacing(medium: 20),
        radii: HandrailChatRadii(messageBubble: 12),
        motion: HandrailChatMotion(
          messageTransitionDuration: Duration(milliseconds: 300),
        ),
      );

      final middle = start.lerp(end, 0.5);

      expect(middle.spacing?.medium, 10);
      expect(middle.radii?.messageBubble, 8);
      expect(
        middle.motion?.messageTransitionDuration,
        const Duration(milliseconds: 200),
      );
    });

    test('token objects are immutable const values', () {
      const spacingA = HandrailChatSpacing();
      const spacingB = HandrailChatSpacing();
      const radiiA = HandrailChatRadii();
      const radiiB = HandrailChatRadii();
      const motionA = HandrailChatMotion();
      const motionB = HandrailChatMotion();
      const typographyA = HandrailChatTypography(
        message: TextStyle(fontSize: 14),
        metadata: TextStyle(fontSize: 12),
        conversationTitle: TextStyle(fontSize: 16),
        composer: TextStyle(fontSize: 16),
      );
      const typographyB = HandrailChatTypography(
        message: TextStyle(fontSize: 14),
        metadata: TextStyle(fontSize: 12),
        conversationTitle: TextStyle(fontSize: 16),
        composer: TextStyle(fontSize: 16),
      );
      const bubbleA = HandrailChatMessageBubbleStyle(
        sentBackgroundColor: Colors.blue,
        sentForegroundColor: Colors.white,
        receivedBackgroundColor: Colors.grey,
        receivedForegroundColor: Colors.black,
        borderColor: Colors.black,
      );
      const bubbleB = HandrailChatMessageBubbleStyle(
        sentBackgroundColor: Colors.blue,
        sentForegroundColor: Colors.white,
        receivedBackgroundColor: Colors.grey,
        receivedForegroundColor: Colors.black,
        borderColor: Colors.black,
      );

      expect(identical(spacingA, spacingB), isTrue);
      expect(identical(radiiA, radiiB), isTrue);
      expect(identical(motionA, motionB), isTrue);
      expect(identical(typographyA, typographyB), isTrue);
      expect(identical(bubbleA, bubbleB), isTrue);
    });
  });
}

Future<HandrailChatThemeData> _resolveInWidget(
  WidgetTester tester, {
  required ThemeData theme,
  MediaQueryData mediaQueryData = const MediaQueryData(),
}) async {
  late HandrailChatThemeData resolved;

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: mediaQueryData,
        child: Builder(
          builder: (context) {
            resolved = HandrailChatTheme.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );

  return resolved;
}
