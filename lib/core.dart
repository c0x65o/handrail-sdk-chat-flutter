/// The pure-Dart public API for Handrail Chat.
///
/// Flutter integrations are exposed from separate library entry points. Every
/// export added here must remain usable without importing `package:flutter`.
library;

export 'src/generated/attachment_transport.dart';
export 'src/generated/conversation.dart';
export 'src/generated/conversation_archive.dart';
export 'src/generated/conversation_creation.dart';
export 'src/generated/conversation_membership.dart';
export 'src/generated/conversation_preference.dart';
export 'src/generated/reply_style_preference.dart';
export 'src/generated/conversation_snapshot.dart';
export 'src/generated/delete_message.dart';
export 'src/generated/device_push_token.dart';
export 'src/generated/draft_mutation.dart';
export 'src/generated/durable_events.dart';
export 'src/generated/edit_message.dart';
export 'src/generated/ephemeral_signals.dart';
export 'src/generated/forward_message.dart';
export 'src/generated/identifiers.dart';
export 'src/generated/huddle_session.dart';
export 'src/generated/message.dart';
export 'src/generated/message_reminder.dart';
export 'src/generated/message_search.dart';
export 'src/generated/message_timeline.dart';
export 'src/generated/read_cursor_mutation.dart';
export 'src/generated/reaction_mutations.dart';
export 'src/generated/realtime_handshake.dart';
export 'src/generated/realtime_session.dart';
export 'src/generated/send_message.dart';
export 'src/generated/thread_creation.dart';
export 'src/generated/thread_follow_mutation.dart';
export 'src/core/command_dispatcher.dart';
export 'src/core/attachment_upload_manager.dart';
export 'src/core/application_chat_storage.dart';
export 'src/core/composer_rich_text.dart';
export 'src/core/conversation_controller.dart';
export 'src/core/conversation_list_controller.dart';
export 'src/core/ephemeral_signal_state.dart';
export 'src/core/message_search_controller.dart';
export 'src/core/normalized_snapshot_state.dart';
export 'src/core/timeline_controller.dart';
export 'src/handrail_chat_client.dart';
export 'src/chat_deep_link.dart';
export 'src/message_search.dart';
export 'src/package_metadata.dart'
    show handrailChatPackageName, handrailChatPackageVersion;
export 'src/realtime_session_transport.dart';
export 'src/generated/message_context.dart';
export 'src/generated/thread_list.dart';
export 'src/generated/thread_lifecycle.dart';
