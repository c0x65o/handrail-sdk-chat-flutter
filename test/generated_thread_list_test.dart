import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:handrail_chat/core.dart';

void main() {
  final f = jsonDecode(File('test/shared-fixtures/thread-list.json').readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> clone(Object? value) => jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  Map<String, dynamic> wire(Map<String, dynamic> entry) {
    final value = clone(f['base']);
    dynamic parent(List<String> parts) {
      dynamic target = value;
      for (final key in parts) { target = target is List ? target[int.parse(key)] : target[key]; }
      return target;
    }
    for (final change in entry['changes'] as List) {
      final parts = (change['path'] as String).split('.'); final key = parts.removeLast();
      parent(parts)[key] = change['value'];
    }
    for (final path in entry['remove'] as List) {
      final parts = (path as String).split('.'); final key = parts.removeLast();
      (parent(parts) as Map).remove(key);
    }
    return value;
  }
  final request = ThreadListRequest.fromJson(f['request']);
  for (final entry in f['valid'] as List) {
    test('round trip: ${entry['name']}', () {
      final value = wire(entry as Map<String, dynamic>);
      final r = ThreadListRequest.fromJson(entry['request'] ?? f['request']);
      final result = ThreadListResult.fromJson(value, expectedRequest: r);
      expect(result.toJson(), value);
      expect(ThreadListResult.fromJson(clone(result.toJson()), expectedRequest: r).toJson(), value);
    });
  }
  for (final entry in f['invalid'] as List) {
    test('reject response: ${entry['name']}', () {
      final r = ThreadListRequest.fromJson(entry['request'] ?? f['request']);
      expect(() => ThreadListResult.fromJson(wire(entry as Map<String, dynamic>), expectedRequest: r), throwsA(isA<ThreadListFormatException>()));
    });
  }
  test('invalid parent, selector, cursor, limit and caller identity input', () {
    for (final input in f['invalidRequests'] as List) {
      expect(() => ThreadListRequest.fromJson(input), throwsA(isA<ThreadListFormatException>()));
    }
    expect(request.toJson(), {'parentConversationId': 'parent-1', 'view': 'active', 'limit': 50});
    for (final limit in [double.nan, double.infinity]) {
      expect(() => ThreadListRequest.fromJson({'parentConversationId':'parent-1', 'limit':limit}), throwsFormatException);
    }
  });
  test('HTTP parsing and query serialization', () {
    expect(parseThreadListHttpRequest('parent-1', {'limit':'100', 'view':'all'}).toJson(), {'parentConversationId':'parent-1','limit':100,'view':'all'});
    expect(request.toQuery(), {'view':'active','limit':'50'});
    for (final query in [{'limit':'01'}, {'limit':'1.0'}, {'limit':['1']}, {'view':['all']}, {'tenantId':'x'}]) {
      expect(() => parseThreadListHttpRequest('parent-1', query), throwsFormatException);
    }
  });
  Map<String, dynamic> item(String id) {
    final i = clone(f['base']['items'][0]); i['thread']['id'] = id;
    for (final key in ['currentMember','currentReadState','currentPreference']) { i['thread'][key]['conversationId'] = id; }
    i['currentThreadFollow']['follow']['target']['id'] = id;
    return i;
  }
  test('deterministic creation ties, Unicode C collation, exclusive scoped cursor and continuation', () {
    final position = ThreadListCursorPosition.fromJson(f['cursor']['position']);
    final token = f['cursor']['token'] as String;
    expect(encodeThreadListCursor(position), token);
    expect(decodeThreadListCursor(token, request).toJson(), position.toJson());
    final ids = ['thread-a','thread-b','é','\ue000','😀'];
    final items = ids.map(item).toList();
    final last = ThreadListCursorPosition.fromJson({...position.toJson(),'threadId':ids.last});
    final page = {...clone(f['base']), 'items':items, 'nextCursor':encodeThreadListCursor(last)};
    final r = ThreadListRequest(parentConversationId:request.parentConversationId,limit:5);
    expect(ThreadListResult.fromJson(page, expectedRequest:r).items.length,5);
    expect(() => ThreadListResult.fromJson({...page,'items':items.reversed.toList()},expectedRequest:r),throwsFormatException);
    expect(() => ThreadListResult.fromJson({...page,'items':[items[0],items[0]]},expectedRequest:r),throwsFormatException);
    expect(() => ThreadListResult.fromJson(page,expectedRequest:ThreadListRequest(parentConversationId:request.parentConversationId,limit:4)),throwsFormatException);
    final continued = ThreadListRequest(parentConversationId:request.parentConversationId,cursor:token);
    expect(ThreadListResult.fromJson({...clone(f['base']),'items':[item('thread-b')]},expectedRequest:continued).items.single.conversation.id.value,'thread-b');
    expect(() => ThreadListResult.fromJson(f['base'],expectedRequest:continued),throwsFormatException);
    expect(() => ThreadListResult.fromJson({...clone(f['base']),'nextCursor':token},expectedRequest:request),throwsFormatException);
    expect(() => ThreadListResult.fromJson({...clone(f['base']),'items':[],'nextCursor':token},expectedRequest:ThreadListRequest(parentConversationId:request.parentConversationId,limit:1)),throwsFormatException);
    final newer = ThreadListCursorPosition.fromJson({...position.toJson(),'createdAt':'2026-09-06T11:01:00.000Z'});
    expect(compareThreadListPositions(newer,position),lessThan(0));
  });
  test('invalid non-finite policy and UTF-8 identifier bounds', () {
    for (final duration in [double.nan,double.infinity,double.negativeInfinity]) {
      expect(() => ThreadListResult.fromJson({...clone(f['base']),'inactivityPolicy':{'hideAfterMs':duration}},expectedRequest:request),throwsFormatException);
    }
    for (final id in ['x'*255,'${'é'*127}x']) { expect(ThreadListRequest(parentConversationId:ConversationId(id)).parentConversationId.value,id); }
    expect(() => ThreadListRequest(parentConversationId:const ConversationId('\ud800')),throwsFormatException);
  });
}
