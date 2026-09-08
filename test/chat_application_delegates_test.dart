import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/ui.dart';

void main() {
  group('ChatApplicationDelegates', () {
    test('omitted delegates are inert and unavailable', () async {
      const delegates = ChatApplicationDelegates();
      const attachment = MessageAttachmentMetadata(
        attachmentId: AttachmentId('attachment/unused'),
        fileName: 'not-opened.txt',
        contentType: 'text/plain',
        sizeBytes: 1,
        downloadUrl: 'https://example.invalid/not-opened',
      );

      expect(
        await delegates.openUser(const UserId('user/unused')),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.openEntity(
          const HostEntityReference(type: 'case', id: 'entity/unused'),
        ),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.openThread(const ConversationId('thread/unused')),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.pickAttachment(),
        isA<ChatAttachmentPickerUnavailable>(),
      );
      expect(
        await delegates.openAttachment(attachment),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.reportMessage(const MessageId('message/unused')),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.showNotificationSettings(),
        ChatApplicationDelegateResult.unavailable,
      );
      expect(
        await delegates.openExternalLink(
          Uri.parse('https://example.invalid/not-opened'),
        ),
        ChatApplicationDelegateResult.unavailable,
      );
    });

    test('forwards every typed value and preserves host outcomes', () async {
      const userId = UserId('employee/a%2Fb?tab=profile#overview');
      const entity = HostEntityReference(
        type: 'sales/order%2Fregional',
        id: 'SO 42/%25?view=full#notes',
      );
      const threadId = ConversationId('thread/root%2F42?pane=side#latest');
      const messageId = MessageId('message/report%2F42?reason=a#fragment');
      const pickedAttachmentId = AttachmentId('attachment/picked%2F42?raw=1');
      const attachment = MessageAttachmentMetadata(
        attachmentId: AttachmentId('attachment/open%2F42?raw=1#page'),
        fileName: 'proposal #42?.pdf',
        contentType: 'application/pdf; profile="archive/special"',
        sizeBytes: 42,
        downloadUrl: 'https://files.example.test/a%2Fb?q=x%2Fy#page=2',
      );
      final externalUri = Uri.parse(
        'https://erp.example.test/docs/a%2Fb?q=x%2Fy#section%201',
      );

      UserId? receivedUserId;
      HostEntityReference? receivedEntity;
      ConversationId? receivedThreadId;
      MessageAttachmentMetadata? receivedAttachment;
      MessageId? receivedMessageId;
      Uri? receivedExternalUri;
      var pickerCalls = 0;
      var settingsCalls = 0;

      final delegates = ChatApplicationDelegates(
        openUser: (value) async {
          receivedUserId = value;
          return ChatApplicationDelegateResult.handled;
        },
        openEntity: (value) async {
          receivedEntity = value;
          return ChatApplicationDelegateResult.cancelled;
        },
        openThread: (value) async {
          receivedThreadId = value;
          return ChatApplicationDelegateResult.handled;
        },
        pickAttachment: () async {
          pickerCalls += 1;
          return ChatAttachmentPickerSelection([pickedAttachmentId]);
        },
        openAttachment: (value) async {
          receivedAttachment = value;
          return ChatApplicationDelegateResult.handled;
        },
        reportMessage: (value) async {
          receivedMessageId = value;
          return ChatApplicationDelegateResult.cancelled;
        },
        showNotificationSettings: () async {
          settingsCalls += 1;
          return ChatApplicationDelegateResult.handled;
        },
        openExternalLink: (value) async {
          receivedExternalUri = value;
          return ChatApplicationDelegateResult.cancelled;
        },
      );

      expect(
        await delegates.openUser(userId),
        ChatApplicationDelegateResult.handled,
      );
      expect(
        await delegates.openEntity(entity),
        ChatApplicationDelegateResult.cancelled,
      );
      expect(
        await delegates.openThread(threadId),
        ChatApplicationDelegateResult.handled,
      );
      final pickerResult = await delegates.pickAttachment();
      expect(
        (pickerResult as ChatAttachmentPickerSelection).attachmentIds,
        [pickedAttachmentId],
      );
      expect(
        await delegates.openAttachment(attachment),
        ChatApplicationDelegateResult.handled,
      );
      expect(
        await delegates.reportMessage(messageId),
        ChatApplicationDelegateResult.cancelled,
      );
      expect(
        await delegates.showNotificationSettings(),
        ChatApplicationDelegateResult.handled,
      );
      expect(
        await delegates.openExternalLink(externalUri),
        ChatApplicationDelegateResult.cancelled,
      );

      expect(identical(receivedUserId, userId), isTrue);
      expect(identical(receivedEntity, entity), isTrue);
      expect(identical(receivedThreadId, threadId), isTrue);
      expect(identical(receivedAttachment, attachment), isTrue);
      expect(identical(receivedMessageId, messageId), isTrue);
      expect(identical(receivedExternalUri, externalUri), isTrue);
      expect(pickerCalls, 1);
      expect(settingsCalls, 1);
    });

    test('attachment picker distinguishes selection and cancellation',
        () async {
      final sourceIds = <AttachmentId>[
        const AttachmentId('attachment-1'),
      ];
      final selection = ChatAttachmentPickerSelection(sourceIds);
      sourceIds.add(const AttachmentId('attachment-2'));

      expect(selection.attachmentIds, [const AttachmentId('attachment-1')]);
      expect(
        () => selection.attachmentIds.add(const AttachmentId('attachment-3')),
        throwsUnsupportedError,
      );
      expect(
        () => ChatAttachmentPickerSelection(const <AttachmentId>[]),
        throwsArgumentError,
      );

      final delegates = ChatApplicationDelegates(
        pickAttachment: () async => const ChatAttachmentPickerCancelled(),
      );
      expect(
        await delegates.pickAttachment(),
        isA<ChatAttachmentPickerCancelled>(),
      );
    });

    test('host errors propagate from every delegate', () async {
      final error = StateError('host behavior failed');
      final delegates = ChatApplicationDelegates(
        openUser: (_) => throw error,
        openEntity: (_) => Future<ChatApplicationDelegateResult>.error(error),
        openThread: (_) => Future<ChatApplicationDelegateResult>.error(error),
        pickAttachment: () => Future<ChatAttachmentPickerResult>.error(error),
        openAttachment: (_) =>
            Future<ChatApplicationDelegateResult>.error(error),
        reportMessage: (_) =>
            Future<ChatApplicationDelegateResult>.error(error),
        showNotificationSettings: () =>
            Future<ChatApplicationDelegateResult>.error(error),
        openExternalLink: (_) =>
            Future<ChatApplicationDelegateResult>.error(error),
      );
      const attachment = MessageAttachmentMetadata(
        attachmentId: AttachmentId('attachment-error'),
        fileName: 'error.txt',
        contentType: 'text/plain',
        sizeBytes: 0,
        downloadUrl: 'https://example.invalid/error',
      );

      await expectLater(
        delegates.openUser(const UserId('user-error')),
        throwsA(same(error)),
      );
      await expectLater(
        delegates.openEntity(
          const HostEntityReference(type: 'case', id: 'entity-error'),
        ),
        throwsA(same(error)),
      );
      await expectLater(
        delegates.openThread(const ConversationId('thread-error')),
        throwsA(same(error)),
      );
      await expectLater(delegates.pickAttachment(), throwsA(same(error)));
      await expectLater(
        delegates.openAttachment(attachment),
        throwsA(same(error)),
      );
      await expectLater(
        delegates.reportMessage(const MessageId('message-error')),
        throwsA(same(error)),
      );
      await expectLater(
        delegates.showNotificationSettings(),
        throwsA(same(error)),
      );
      await expectLater(
        delegates.openExternalLink(Uri.parse('https://example.test/error')),
        throwsA(same(error)),
      );
    });

    testWidgets('fully custom host widgets can invoke the public contract', (
      tester,
    ) async {
      const userId = UserId('employee/custom%2Fwidget?raw=true');
      UserId? receivedUserId;
      ChatApplicationDelegateResult? result;
      final delegates = ChatApplicationDelegates(
        openUser: (value) async {
          receivedUserId = value;
          return ChatApplicationDelegateResult.handled;
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await delegates.openUser(userId);
              },
              child: const Text('Open user'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open user'));
      await tester.pump();

      expect(identical(receivedUserId, userId), isTrue);
      expect(result, ChatApplicationDelegateResult.handled);
    });
  });
}
