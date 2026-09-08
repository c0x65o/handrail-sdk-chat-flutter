import 'package:flutter/material.dart';

class SharedStorageLab extends StatelessWidget {
  const SharedStorageLab({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
            body: Center(
                child: Text(
                    'Shared-storage integration requires the chat-lab browser host.'))),
      );
}
