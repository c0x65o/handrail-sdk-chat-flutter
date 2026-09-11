import 'dart:ui' show SemanticsAction, SemanticsFlag;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

import 'reply_style_runtime_test.dart' as f;
import 'widget_evidence.dart';

void main() {
  testWidgets('saves only on confirmation and reloads saved choice',
      (tester) async {
    final http = f.Http();
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(find.text('No saved choice.'), findsOneWidget);
    final write = Completer<HandrailChatHttpResponse>();
    http.write = (_) => write.future;
    await tester.tap(find.text('Discord-style'));
    await _pump(tester);
    expect(find.text('Saving: Discord-style.'), findsOneWidget);
    expect(
        find.text('Effective style: Current — SDK default.'), findsOneWidget);
    expect(
        client.replyStyles.state.confirmed, isA<AbsentReplyStylePreference>());
    http.preference = f.saved(1);
    write.complete(f.response(f.result(http.writes.single)));
    await _pump(tester);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    expect(find.text('Saving: Discord-style.'), findsNothing);
    await captureWidgetEvidence(
        tester, 'reply-settings-confirmed-discord-widget.png');
    final reloaded = _client(tester, http);
    await tester.runAsync(reloaded.initialize);
    await _mount(tester, reloaded);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    expect(http.writes, hasLength(1));
  });

  testWidgets(
      'absent preference uses editable host default and explicit Current wins',
      (tester) async {
    final http = f.Http();
    final client = _client(tester, http,
        configuration: const ChatReplyStyleConfiguration(
            defaultStyle: ReplyStyle.discord));
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(find.text('Effective style: Discord-style — app default.'),
        findsOneWidget);
    expect(find.text('No saved choice.'), findsOneWidget);
    expect(_choice(tester, 'current').onChanged, isNotNull);
    await tester.tap(find.text('Current'));
    await _pump(tester);
    expect(find.text('Effective style: Current — saved preference.'),
        findsOneWidget);
  });

  testWidgets('loading is provisional and failed read refresh recovers',
      (tester) async {
    final http = f.Http();
    final read = Completer<HandrailChatHttpResponse>();
    http.read = (_) => read.future;
    final client = _client(tester, http);
    unawaited(client.initialize());
    await _mount(tester, client);
    await _pump(tester);
    expect(find.text('Loading your saved reply style…'), findsOneWidget);
    expect(find.textContaining('The displayed style is provisional.'),
        findsOneWidget);
    expect(find.text('No saved choice.'), findsNothing);
    expect(_choice(tester, 'discord').onChanged, isNull);
    read.complete(f.response({'error': 'private server details'}, 403));
    await _pump(tester);
    expect(find.textContaining('private server details'), findsNothing);
    http.read = null;
    http.preference = f.saved(1);
    await tester.ensureVisible(find.text('Retry loading reply style'));
    await tester.tap(find.text('Retry loading reply style'));
    await _pump(tester);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    expect(_choice(tester, 'discord').onChanged, isNotNull);
    expect(http.writes, isEmpty);
  });

  testWidgets(
      'failed save retains confirmed choice and explicitly retries exact request',
      (tester) async {
    final http = f.Http()..preference = f.saved(1, 'current');
    http.write = (_) async => f.response({'error': 'secret diagnostic'}, 403);
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    await tester.tap(find.text('Discord-style'));
    await _pump(tester);
    expect(find.text('Effective style: Current — saved preference.'),
        findsOneWidget);
    expect(find.text('Requested choice (unconfirmed): Discord-style.'),
        findsOneWidget);
    expect(find.textContaining('secret diagnostic'), findsNothing);
    expect(_choice(tester, 'current').onChanged, isNull);
    expect(http.writes, hasLength(1));
    await captureWidgetEvidence(
        tester, 'reply-settings-failed-save-widget.png');
    http.write = null;
    await tester.ensureVisible(find.text('Retry saving reply style'));
    await tester.tap(find.text('Retry saving reply style'));
    await _pump(tester);
    expect(http.reads, hasLength(2));
    expect(http.writes, hasLength(2));
    expect(http.writes.last, http.writes.first);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    expect(find.text('Retry saving reply style'), findsNothing);
    await captureWidgetEvidence(
        tester, 'reply-settings-recovered-save-widget.png');
  });

  testWidgets('host enforcement preserves and reveals differing saved choice',
      (tester) async {
    final http = f.Http()..preference = f.saved(3);
    final client = _client(tester, http,
        configuration:
            const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(find.text('Effective style: Current — enforced by this app.'),
        findsOneWidget);
    expect(find.text('Saved choice: Discord-style.'), findsOneWidget);
    expect(_choice(tester, 'discord').onChanged, isNull);
    client.replyStyles.configure(const ChatReplyStyleConfiguration());
    await _pump(tester);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    expect(_choice(tester, 'current').onChanged, isNotNull);
    expect(http.writes, isEmpty);
  });

  testWidgets('unsupported saved value is explained without rewriting it',
      (tester) async {
    final http = f.Http()..preference = f.saved(3, 'future-style');
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(find.text('An unsupported style value is using Current.'),
        findsOneWidget);
    expect(find.text('Saved choice: Unsupported choice.'), findsOneWidget);
    expect(http.writes, isEmpty);
  });

  testWidgets(
      'preference API absence is independent of supported reply actions',
      (tester) async {
    final http = _CapabilitiesHttp(preference: false, actions: true);
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(_choice(tester, 'discord').onChanged, isNull);
    expect(find.text('Reply style preferences are unavailable on this server.'),
        findsOneWidget);
    expect(find.textContaining('Inline replies are unavailable'), findsNothing);
    expect(find.textContaining('Named-thread creation is unavailable'),
        findsNothing);
    expect(find.text('No saved choice.'), findsNothing);
    expect(http.reads, isEmpty);
  });

  testWidgets(
      'missing action capabilities allow preference saving without rerouting',
      (tester) async {
    final http = _CapabilitiesHttp(preference: true, actions: false);
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    await _mount(tester, client);
    expect(
        find.textContaining('Inline replies are unavailable'), findsOneWidget);
    expect(find.textContaining('Named-thread creation is unavailable'),
        findsOneWidget);
    await tester.tap(find.text('Discord-style'));
    await _pump(tester);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
    expect(
        http.requests.every((r) =>
            r.uri.path.endsWith('/_meta') ||
            r.uri.path.endsWith('/preferences/reply-style')),
        isTrue);
  });

  testWidgets('rebinding and disposal detach without disposing runtimes',
      (tester) async {
    final first = _client(tester, f.Http());
    final second = _client(tester, f.Http()..preference = f.saved(1));
    await tester.runAsync(first.initialize);
    await tester.runAsync(second.initialize);
    await _mount(tester, first);
    await _mount(tester, second);
    first.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    await _pump(tester);
    expect(find.text('Effective style: Discord-style — saved preference.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => second.replyStyles.select(ReplyStyle.current));
    await _pump(tester);
    expect(first.replyStyles.state.isDisposed, isFalse);
    expect(second.replyStyles.state.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'large text at 320 pixels wraps with keyboard operable radio semantics',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final http = f.Http();
    final client = _client(tester, http);
    await tester.runAsync(client.initialize);
    final semantics = tester.ensureSemantics();
    await _mount(tester, client, scale: 2);
    await tester.ensureVisible(find.text('Discord-style'));
    await tester.pump();
    final radio = tester.getSemantics(find.descendant(
        of: find.byKey(const ValueKey('handrail-reply-style-discord')),
        matching: find.byType(Radio<ReplyStyle>))).getSemanticsData();
    // Check stable semantics; newer Flutter adds hasSelectedState to Radio.
    expect(radio.label, 'Discord-style');
    for (final flag in [
      SemanticsFlag.hasCheckedState,
      SemanticsFlag.isInMutuallyExclusiveGroup,
      SemanticsFlag.hasEnabledState,
      SemanticsFlag.isEnabled,
      SemanticsFlag.isFocusable,
    ]) {
      expect(radio.hasFlag(flag), isTrue, reason: flag.toString());
    }
    expect(radio.hasFlag(SemanticsFlag.isChecked), isFalse);
    expect(radio.hasAction(SemanticsAction.tap), isTrue);
    final radioElement = tester.element(
        find.byKey(const ValueKey('handrail-reply-style-discord')));
    bool radioHasFocus() {
      var found = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        found = identical(e, radioElement);
        return !found;
      });
      return found;
    }
    // Tab traversal entry differs across framework versions. Assert that the
    // radio is reachable, then activate it using the keyboard on both SDKs.
    for (var i = 0; i < 6 && !radioHasFocus(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(radioHasFocus(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pump(tester);
    expect(http.writes.single['style'], 'discord');
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
}

RadioListTile<ReplyStyle> _choice(WidgetTester tester, String style) =>
    tester.widget(find.byKey(ValueKey('handrail-reply-style-$style')));

HandrailChatClient _client(WidgetTester tester, f.Http http,
    {ChatReplyStyleConfiguration configuration =
        const ChatReplyStyleConfiguration()}) {
  var keys = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.test/api/chat'),
    tokenProvider: () async => 'token',
    transport: http,
    requestedCapabilities: const {
      ChatReplyThreadFeatures.inlineReplies: true,
      ChatReplyThreadFeatures.namedThreads: true,
    },
    replyStyleIdentity: f.actor,
    replyStyleConfiguration: configuration,
    generateIdempotencyKey: () => 'settings-${++keys}',
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var disposed = false;
    unawaited(client.dispose().then((_) => disposed = true));
    for (var i = 0; i < 50 && !disposed; i++) {
      await _pump(tester);
    }
    expect(disposed, isTrue);
  });
  return client;
}

Future<void> _mount(WidgetTester tester, HandrailChatClient client,
    {double scale = 1}) async {
  await prepareWidgetEvidence(tester);
  await tester.pumpWidget(widgetEvidenceBoundary(MaterialApp(
      theme: widgetEvidenceTheme,
      home: Scaffold(
          body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: HandrailReplyStyleSettings(client: client)),
      )))));
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

class _CapabilitiesHttp extends f.Http {
  _CapabilitiesHttp({required bool preference, required this.actions}) {
    support = preference;
  }
  final bool actions;
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    if (request.uri.path.endsWith('/_meta')) {
      requests.add(request);
      return f.response({
        ...f.metadata(support),
        'enabledFeatures': {
          replyStylePreferenceFeature: support,
          ChatReplyThreadFeatures.inlineReplies: actions,
          ChatReplyThreadFeatures.namedThreads: actions,
        }
      });
    }
    return super.send(request);
  }
}
