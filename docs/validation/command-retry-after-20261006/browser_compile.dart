// Compile-only qualification of the shipped browser header adapter and core.
// No requests are issued by this entry point.
import '../../../example/lib/backend_lab/browser_transport.dart';
void main() {
  print(BrowserChatTransport().send);
}
