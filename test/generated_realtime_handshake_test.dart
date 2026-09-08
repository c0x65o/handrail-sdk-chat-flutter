import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('reserved capability names preserve compatibility and absent means false', () {
    expect(ChatReplyThreadFeatures.savedReplyStyle, replyStylePreferenceFeature);
    final features = EnabledFeatures({ChatReplyThreadFeatures.inlineReplies: true});
    expect(features.values[ChatReplyThreadFeatures.inlineReplies], true);
    expect(features.values[ChatReplyThreadFeatures.namedThreads] == true, false);
    expect(ChatReplyThreadFeatures.threadDiscovery, 'threadDiscovery');
    expect(ChatReplyThreadFeatures.threadLifecycle, 'threadLifecycle');
    expect(ChatReplyThreadFeatures.threadInactivity, 'threadInactivity');
  });

  test('server handshake metadata round-trips every wire field', () {
    final metadata = ServerHandshakeMetadata(
      packageVersion: '1.1.3',
      protocolVersion: 4,
      schemaVersion: 9,
      enabledFeatures: EnabledFeatures({
        'threads': true,
        'huddles': false,
      }),
      supportedProtocolRange: const SupportedProtocolRange(
        minimumVersion: 3,
        maximumVersion: 4,
      ),
    );

    final wireJson = jsonDecode(jsonEncode(metadata.toJson()));
    final decoded = ServerHandshakeMetadata.fromJson(wireJson);

    expect(decoded.packageVersion, '1.1.3');
    expect(decoded.protocolVersion, 4);
    expect(decoded.schemaVersion, 9);
    expect(decoded.enabledFeatures.values, {
      'threads': true,
      'huddles': false,
    });
    expect(decoded.supportedProtocolRange.minimumVersion, 3);
    expect(decoded.supportedProtocolRange.maximumVersion, 4);
    expect(decoded.toJson(), metadata.toJson());
  });

  test('metadata input and enabled features are immutable JSON models', () {
    final sourceFeatures = {'threads': true};
    final input = ServerHandshakeMetadataInput(
      packageVersion: '1.1.3',
      protocolVersion: 4,
      schemaVersion: 9,
      enabledFeatures: EnabledFeatures(sourceFeatures),
    );
    sourceFeatures['threads'] = false;

    final decoded = ServerHandshakeMetadataInput.fromJson(
      jsonDecode(jsonEncode(input.toJson())),
    );

    expect(decoded.packageVersion, '1.1.3');
    expect(decoded.protocolVersion, 4);
    expect(decoded.schemaVersion, 9);
    expect(decoded.enabledFeatures['threads'], isTrue);
    expect(
      () => decoded.enabledFeatures.values['threads'] = false,
      throwsUnsupportedError,
    );
  });

  test('deserialization rejects malformed scalar JSON types', () {
    final valid = <String, Object?>{
      'packageVersion': '1.1.3',
      'protocolVersion': 4,
      'schemaVersion': 9,
      'enabledFeatures': <String, Object?>{
        'threads': true,
        'huddles': false,
      },
      'supportedProtocolRange': <String, Object?>{
        'minimumVersion': 3,
        'maximumVersion': 4,
      },
    };

    final malformedValues = <Map<String, Object?>>[
      {...valid, 'packageVersion': 113},
      {...valid, 'protocolVersion': '4'},
      {...valid, 'schemaVersion': 9.0},
      {
        ...valid,
        'enabledFeatures': <String, Object?>{'threads': 'true'},
      },
      {
        ...valid,
        'supportedProtocolRange': <String, Object?>{
          'minimumVersion': '3',
          'maximumVersion': 4,
        },
      },
      {
        ...valid,
        'supportedProtocolRange': <String, Object?>{
          'minimumVersion': 3,
          'maximumVersion': false,
        },
      },
    ];

    for (final malformed in malformedValues) {
      expect(
        () => ServerHandshakeMetadata.fromJson(malformed),
        throwsFormatException,
      );
    }
  });
}
