import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _evidenceKey = ValueKey('handrail-widget-fixture-evidence');
const _fontFamily = 'HandrailWidgetEvidence';
bool _fontsLoaded = false;

bool get _enabled =>
    Platform.environment['HANDRAIL_WIDGET_EVIDENCE_DIR']?.isNotEmpty == true;

ThemeData? get widgetEvidenceTheme =>
    _enabled ? ThemeData(fontFamily: _fontFamily) : null;

/// Use fonts already installed with Flutter; never fetch fonts for evidence.
Future<void> prepareWidgetEvidence(WidgetTester tester) async {
  if (!_enabled || _fontsLoaded) return;
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final directory = Platform.environment['HANDRAIL_WIDGET_FONT_DIR'] ??
      (flutterRoot == null
          ? null
          : '$flutterRoot/bin/cache/artifacts/material_fonts');
  if (directory == null || directory.isEmpty) {
    throw StateError('Widget evidence requires HANDRAIL_WIDGET_FONT_DIR or '
        'FLUTTER_ROOT pointing to existing local Flutter fonts.');
  }
  await tester.runAsync(() async {
    for (final entry in {
      _fontFamily: [
        'Roboto-Regular.ttf',
        'Roboto-Medium.ttf',
        'Roboto-Bold.ttf'
      ],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final filename in entry.value) {
        final bytes = await File('$directory/$filename').readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
    _fontsLoaded = true;
  });
}

/// Optional inspectable renders of tested widgets using transport fixtures.
/// These are neither golden assertions nor evidence of a running backend host.
Widget widgetEvidenceBoundary(Widget child) =>
    _enabled ? RepaintBoundary(key: _evidenceKey, child: child) : child;

Future<void> captureWidgetEvidence(WidgetTester tester, String filename) async {
  final directory = Platform.environment['HANDRAIL_WIDGET_EVIDENCE_DIR'];
  if (directory == null || directory.isEmpty) return;
  await tester.pump();
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_evidenceKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw StateError('Widget evidence PNG encoding failed.');
      }
      final file = File('$directory/$filename');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      // ignore: avoid_print
      print('Widget fixture render (not runtime UI): ${file.path}');
    } finally {
      image.dispose();
    }
  });
}
