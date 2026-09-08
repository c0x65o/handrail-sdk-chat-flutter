import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final projectRoot = Directory.current;

  String readProjectFile(String path) {
    return File('${projectRoot.path}/$path').readAsStringSync();
  }

  test('uses the in-repository handrail_chat package', () {
    final pubspec = readProjectFile('pubspec.yaml');

    expect(
      pubspec,
      matches(
        RegExp(
          r'^  handrail_chat:\s*\n    path: ../../flutter/handrail_chat\s*$',
          multiLine: true,
        ),
      ),
    );
  });

  test('declares exempt iOS encryption without biometric permissions', () {
    final infoPlist = readProjectFile('ios/Runner/Info.plist');

    expect(
      infoPlist,
      matches(
        RegExp(
          r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false\s*/>',
        ),
      ),
    );
    expect(infoPlist, isNot(contains('NSFaceIDUsageDescription')));
  });

  test('uses iOS 15.0 for every Runner build configuration', () {
    final xcodeProject = readProjectFile(
      'ios/Runner.xcodeproj/project.pbxproj',
    );
    final deploymentTargets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
    ).allMatches(xcodeProject).map((match) => match.group(1)).toList();
    final infoPlist = readProjectFile('ios/Runner/Info.plist');

    expect(deploymentTargets, hasLength(3));
    expect(deploymentTargets, everyElement('15.0'));
    expect(infoPlist, isNot(contains('MinimumOSVersion')));
  });

  test('declares manifest-level internet access without cleartext overrides', () {
    final manifest = readProjectFile(
      'android/app/src/main/AndroidManifest.xml',
    );

    expect(
      manifest,
      matches(
        RegExp(
          r'<manifest\b[^>]*>\s*'
          r'<uses-permission android:name="android\.permission\.INTERNET"\s*/>\s*'
          r'<application\b',
        ),
      ),
    );
    expect(manifest, isNot(contains('android:usesCleartextTraffic')));
    expect(manifest, isNot(contains('android:networkSecurityConfig')));
    expect(manifest, isNot(contains('android.permission.USE_BIOMETRIC')));
    expect(manifest, isNot(contains('android.permission.USE_FINGERPRINT')));
  });
}
