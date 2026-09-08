import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/core.dart' as core;
import 'package:test/test.dart';

void main() {
  test('core.dart has a pure-Dart import graph', () async {
    expect(core.handrailChatPackageName, 'handrail_chat');
    expect(core.handrailChatPackageVersion, '0.1.19');
    expect(
      core.composerMarkdownToRichTextDocument('**pure Dart**').blocks,
      hasLength(1),
    );

    final packageRoot = Directory.current.absolute.uri;
    final packageConfigFile = File.fromUri(
      packageRoot.resolve('.dart_tool/package_config.json'),
    );
    expect(
      await packageConfigFile.exists(),
      isTrue,
      reason: 'Run `flutter pub get` before this boundary test.',
    );

    final packageRoots = await _loadPackageRoots(packageConfigFile);
    await _expectFlutterFreeGraph(
      packageRoot.resolve('lib/core.dart'),
      packageRoots,
    );
  });
}

Future<Map<String, Uri>> _loadPackageRoots(File packageConfigFile) async {
  final config = jsonDecode(await packageConfigFile.readAsString())
      as Map<String, Object?>;
  final packages = config['packages']! as List<Object?>;
  final configRoot = packageConfigFile.parent.uri;
  final packageRoots = <String, Uri>{};

  for (final packageJson in packages) {
    final package = packageJson! as Map<String, Object?>;
    final resolvedRoot = configRoot.resolve(package['rootUri']! as String);
    final directoryRoot = resolvedRoot.path.endsWith('/')
        ? resolvedRoot
        : resolvedRoot.replace(path: '${resolvedRoot.path}/');
    packageRoots[package['name']! as String] =
        directoryRoot.resolve(package['packageUri']! as String);
  }

  return packageRoots;
}

Future<void> _expectFlutterFreeGraph(
  Uri entryPoint,
  Map<String, Uri> packageRoots,
) async {
  final pending = <Uri>[entryPoint];
  final visited = <Uri>{};

  while (pending.isNotEmpty) {
    final sourceUri = File.fromUri(pending.removeLast()).absolute.uri;
    if (!visited.add(sourceUri)) continue;

    final source = await File.fromUri(sourceUri).readAsString();
    for (final directive in _directives.allMatches(source)) {
      final directiveBody = directive.group(1)!;
      for (final uriMatch in _quotedUris.allMatches(directiveBody)) {
        final importedUri = uriMatch.group(1)!;
        expect(
          importedUri.startsWith('package:flutter/'),
          isFalse,
          reason: '$sourceUri imports Flutter through $importedUri',
        );

        final resolved = _resolveImport(importedUri, sourceUri, packageRoots);
        if (resolved != null) pending.add(resolved);
      }
    }
  }
}

Uri? _resolveImport(
  String importedUri,
  Uri sourceUri,
  Map<String, Uri> packageRoots,
) {
  final uri = Uri.parse(importedUri);
  if (uri.scheme == 'dart') return null;

  if (uri.scheme == 'package') {
    final segments = uri.pathSegments;
    final packageRoot = packageRoots[segments.first];
    expect(
      packageRoot,
      isNotNull,
      reason: 'Could not resolve $importedUri from the package config.',
    );
    return packageRoot!.resolve(segments.skip(1).join('/'));
  }

  expect(
    uri.hasScheme,
    isFalse,
    reason: 'Unsupported URI $importedUri in $sourceUri.',
  );
  return sourceUri.resolve(importedUri);
}

final _directives = RegExp(
  r'^\s*(?:import|export|part)\s+([^;]+);',
  multiLine: true,
);
final _quotedUris = RegExp(r'''['"]([^'"]+)['"]''');
