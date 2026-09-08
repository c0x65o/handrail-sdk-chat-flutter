import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/huddle_session_fixtures.dart';

void main() {
  test('all states and both participant statuses round-trip immutably', () {
    final fixtures = [inactiveHuddle, startingHuddle, activeAliceHuddle, bobLeftHuddle, endedHuddle];
    final types = [isA<InactiveHuddleState>(), isA<StartingHuddleState>(), isA<ActiveHuddleState>(), isA<ActiveHuddleState>(), isA<EndedHuddleState>()];
    for (var index = 0; index < fixtures.length; index++) {
      final state = HuddleSessionState.fromJson(_roundTrip(fixtures[index]));
      expect(state, types[index]); expect(state.toJson(), fixtures[index]);
    }
    expect(HuddleParticipant.fromJson(aliceParticipant), isA<HuddleJoinedParticipant>());
    expect(HuddleParticipant.fromJson((bobLeftHuddle['participants']! as List)[1]), isA<HuddleLeftParticipant>());
    final parsed = HuddleSessionState.fromJson(activeBothHuddle) as ActiveHuddleState;
    expect(() => parsed.participants.add(HuddleParticipant.fromJson(aliceParticipant)), throwsUnsupportedError);
  });

  test('all five command inputs and results round-trip with coherent states', () {
    final cases = <(Map<String, Object?>, Map<String, Object?>, Map<String, Object?>?, HuddleSessionState, Matcher)>[
      (startInput, startingHuddle, mediaJoin, HuddleSessionState.fromJson(inactiveHuddle), isA<StartHuddleResult>()),
      (joinInput, activeAliceHuddle, mediaJoin, HuddleSessionState.fromJson(startingHuddle), isA<JoinHuddleResult>()),
      (leaveInput, bobLeftHuddle, null, HuddleSessionState.fromJson(sharingHuddle), isA<LeaveHuddleResult>()),
      (setShareInput, sharingHuddle, null, HuddleSessionState.fromJson(activeBothHuddle), isA<SetHuddleScreenShareResult>()),
      (endInput, endedHuddle, null, HuddleSessionState.fromJson(activeBothHuddle), isA<EndHuddleResult>()),
    ];
    for (final (inputJson, state, descriptor, previous, matcher) in cases) {
      final input = HuddleCommandInput.fromJson(_roundTrip(inputJson));
      expect(input.toJson(), inputJson);
      final json = success(inputJson, state, descriptor: descriptor);
      final result = parseHuddleCommandResult(_roundTrip(json), input, now: fixtureNow, previousState: previous);
      expect(result, matcher); expect(result.toJson(), json);
    }
    final clear = HuddleCommandInput.fromJson(clearShareInput);
    expect(parseHuddleCommandResult(success(clearShareInput, activeBothHuddle), clear, previousState: HuddleSessionState.fromJson(sharingHuddle)), isA<SetHuddleScreenShareResult>());
  });

  test('the complete lifecycle table and operation-specific deltas are enforced', () {
    const allowed = {'inactive:inactive', 'inactive:starting', 'starting:starting', 'starting:active', 'starting:ended', 'active:active', 'active:ended', 'ended:ended'};
    for (final from in HuddleSessionStatus.values) for (final to in HuddleSessionStatus.values) {
      expect(isAllowedHuddleLifecycleTransition(from, to), allowed.contains('${from.name}:${to.name}'));
    }
    expect(() => validateHuddleStateTransition(HuddleSessionState.fromJson(endedHuddle), HuddleSessionState.fromJson(startingHuddle), HuddleCommandInput.fromJson(startInput)), throwsA(_code(HuddleContractErrorCode.invalidTransition)));
    expect(() => validateHuddleStateTransition(HuddleSessionState.fromJson(startingHuddle), HuddleSessionState.fromJson(activeAliceHuddle), HuddleCommandInput.fromJson(joinInput), reconciliationStatus: HuddleReconciliationStatus.replayed), throwsA(_code(HuddleContractErrorCode.replayMismatch)));
  });

  test('feature-disabled start and join preserve state', () {
    for (final (inputJson, stateJson) in [(startInput, inactiveHuddle), (joinInput, activeAliceHuddle)]) {
      final input = HuddleCommandInput.fromJson(inputJson);
      final previous = HuddleSessionState.fromJson(stateJson);
      final result = parseHuddleCommandResult(disabled(inputJson, stateJson), input, previousState: previous);
      expect(result, isA<HuddleFeatureDisabledResult>()); expect(result.toJson(), disabled(inputJson, stateJson));
    }
    expect(() => parseHuddleCommandResult(disabled(leaveInput, activeAliceHuddle), HuddleCommandInput.fromJson(leaveInput)), throwsA(_code(HuddleContractErrorCode.incoherentResult)));
  });

  test('stale, excessive, malformed, provider, trusted-identity, and incoherent shapes are rejected', () {
    for (final invalid in [
      {...mediaJoin, 'expiresAt': fixtureNow},
      {...mediaJoin, 'expiresAt': '2026-08-25T20:05:00.001Z'},
      {...mediaJoin, 'descriptor': 'x' * (maxHuddleMediaJoinDescriptorUtf8Bytes + 1)},
      {...mediaJoin, 'roomToken': 'secret'},
    ]) { expect(() => HuddleMediaJoinDescriptor.fromJson(invalid, now: fixtureNow), throwsA(isA<HuddleContractException>())); }
    for (final entry in [('actorUserId', 'spoof'), ('providerConfiguration', {'roomId': 'secret'}), ('accessToken', 'secret')]) {
      expect(() => HuddleCommandInput.fromJson({...startInput, 'nested': {entry.$1: entry.$2}}), throwsA(isA<HuddleContractException>()));
    }
    expect(() => HuddleSessionState.fromJson({...activeAliceHuddle, 'screenShareOwnerUserId': 'user-bob'}), throwsA(_code(HuddleContractErrorCode.incoherentState)));
    expect(() => HuddleSessionState.fromJson({...endedHuddle, 'participants': [aliceParticipant]}), throwsA(isA<HuddleContractException>()));
  });

  test('replayed results must match the original canonical outcome and state', () {
    final input = HuddleCommandInput.fromJson(joinInput);
    final original = parseHuddleCommandResult(success(joinInput, activeAliceHuddle, descriptor: mediaJoin), input, now: fixtureNow);
    final replay = {...success(joinInput, activeAliceHuddle, descriptor: mediaJoin), 'reconciliationStatus': 'replayed'};
    expect(parseHuddleCommandResult(replay, input, now: fixtureNow, replayOf: original), isA<JoinHuddleResult>());
    expect(() => parseHuddleCommandResult({...replay, 'state': sharingHuddle}, input, now: fixtureNow, replayOf: original), throwsA(_code(HuddleContractErrorCode.replayMismatch)));
  });
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
Matcher _code(HuddleContractErrorCode code) => isA<HuddleContractException>().having((error) => error.code, 'code', code);
