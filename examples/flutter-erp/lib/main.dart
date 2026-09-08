import 'package:flutter/material.dart';

import 'erp_chat_app.dart';
import 'erp_chat_host.dart';

export 'custom_timeline.dart';
export 'erp_chat_app.dart';
export 'erp_chat_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    ErpChatBootstrap(
      sessionTokenProvider: const UnconfiguredErpSessionTokenProvider(),
      child: const ErpExampleApp(),
    ),
  );
}
