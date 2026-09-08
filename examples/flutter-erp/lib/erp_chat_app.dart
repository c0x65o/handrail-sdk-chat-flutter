import 'package:flutter/material.dart';
import 'package:handrail_chat/ui.dart';

import 'custom_timeline.dart';

const ConversationId erpExampleConversationId = ConversationId(
  'erp-example-general',
);

/// Host-owned attachment selection boundary.
abstract interface class ErpAttachmentPicker {
  Future<ChatAttachmentPickerResult> pickAttachments();
}

final class UnconfiguredErpAttachmentPicker implements ErpAttachmentPicker {
  const UnconfiguredErpAttachmentPicker();

  @override
  Future<ChatAttachmentPickerResult> pickAttachments() async =>
      const ChatAttachmentPickerUnavailable();
}

final class ErpExampleApp extends StatelessWidget {
  const ErpExampleApp({
    this.attachmentPicker = const UnconfiguredErpAttachmentPicker(),
    super.key,
  });

  final ErpAttachmentPicker attachmentPicker;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Handrail ERP Example',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    ),
    home: ErpChatGate(attachmentPicker: attachmentPicker),
  );
}

/// Projects the public client lifecycle into host-owned application states.
final class ErpChatGate extends StatelessWidget {
  const ErpChatGate({required this.attachmentPicker, super.key});

  final ErpAttachmentPicker attachmentPicker;

  @override
  Widget build(BuildContext context) {
    final binding = ChatScope.of(context);
    return switch (binding.readiness) {
      ChatScopeReadiness.ready => ErpWorkspaceScreen(
        attachmentPicker: attachmentPicker,
      ),
      ChatScopeReadiness.refreshRequired => _ErpStatusScreen(
        key: const ValueKey<String>('erp-chat-refresh-required'),
        icon: Icons.system_update,
        title: 'Chat update required',
        message: binding.refreshRequired!.message,
      ),
      ChatScopeReadiness.error => _ErpStatusScreen(
        key: const ValueKey<String>('erp-chat-error'),
        icon: Icons.cloud_off,
        title: 'Chat is unavailable',
        message: binding.error!.message,
        action: FilledButton(
          onPressed: () => binding.client.initialize(),
          child: const Text('Try again'),
        ),
      ),
      ChatScopeReadiness.notReady => const _ErpStatusScreen(
        key: ValueKey<String>('erp-chat-loading'),
        icon: Icons.forum_outlined,
        title: 'Connecting to Handrail Chat',
        message: 'Preparing your ERP chat workspace…',
        showProgress: true,
      ),
    };
  }
}

final class ErpWorkspaceScreen extends StatelessWidget {
  const ErpWorkspaceScreen({required this.attachmentPicker, super.key});

  final ErpAttachmentPicker attachmentPicker;

  @override
  Widget build(BuildContext context) {
    final delegates = ChatApplicationDelegates(
      openUser: (userId) =>
          _openHostDestination(context, title: 'Employee ${userId.value}'),
      openEntity: (reference) => _openHostDestination(
        context,
        title: '${reference.type} ${reference.id}',
      ),
      pickAttachment: attachmentPicker.pickAttachments,
      showNotificationSettings: () =>
          _openHostDestination(context, title: 'ERP notification settings'),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Handrail ERP Chat'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('erp-notification-settings'),
            tooltip: 'Notification settings',
            onPressed: () => delegates.showNotificationSettings(),
            icon: const Icon(Icons.notifications_outlined),
          ),
          IconButton(
            key: const ValueKey<String>('erp-open-custom-timeline'),
            tooltip: 'Custom timeline example',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const ErpCustomTimelineScreen(
                  conversationId: erpExampleConversationId,
                ),
              ),
            ),
            icon: const Icon(Icons.dashboard_customize_outlined),
          ),
        ],
      ),
      body: HandrailChatWorkspace(delegates: delegates),
    );
  }

  Future<ChatApplicationDelegateResult> _openHostDestination(
    BuildContext context, {
    required String title,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _ErpHostDestinationScreen(title: title),
      ),
    );
    return ChatApplicationDelegateResult.handled;
  }
}

final class _ErpHostDestinationScreen extends StatelessWidget {
  const _ErpHostDestinationScreen({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: Text(
        '$title is owned by the ERP host application.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

final class _ErpStatusScreen extends StatelessWidget {
  const _ErpStatusScreen({
    required super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool showProgress;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 48),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              if (showProgress) ...<Widget>[
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
              ],
              if (action case final action?) ...<Widget>[
                const SizedBox(height: 20),
                action,
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
