import 'dart:convert';
import 'package:handrail_chat/core.dart';

class FixtureTransport implements HandrailChatHttpTransport {
  int calls = 0;
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    calls++;
    // The baseline public response cannot represent the wire Retry-After header.
    return const HandrailChatHttpResponse(statusCode: 429, body: '{}');
  }
}
Future<void> main() async {
  final waits = <int>[];
  final transport = FixtureTransport();
  final dispatcher = ChatCommandDispatcher(
    apiBaseUri: Uri.parse('https://fixture.invalid'), tokenProvider: () async => 'fixture-token', transport: transport,
    generateIdempotencyKey: () => 'fixture-key',
    retryOptions: ChatCommandRetryOptions(wait: (delay, _) async { waits.add(delay.inMilliseconds); }),
  );
  final result = await dispatcher.dispatch(ChatCommandDescriptor<Object?,Object?,Object?>(name:'fixture.command', method:ChatCommandMethod.post, path:'/commands', retrySafety:ChatCommandRetrySafety.safe, validateInput:(x)=>x, parseResult:(x)=>x), {});
  print(jsonEncode({'calls':transport.calls,'waits':waits,'status':result.status,'expectedMinimumWaitMs':60000,'reproduced':waits.any((ms)=>ms<60000)}));
}
