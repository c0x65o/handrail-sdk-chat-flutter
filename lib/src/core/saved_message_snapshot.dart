import '../generated/identifiers.dart';
import '../generated/message.dart';
import '../generated/message_timeline.dart' show MessageAttachmentMetadata;

/// Handwritten counterpart of the TS private-user-state saved message projection.
/// Parse an entry's `message` with its containing `messageId`. Paging and private
/// save-state metadata are intentionally outside this projection contract.
sealed class SavedMessageProjection {
  const SavedMessageProjection._();

  factory SavedMessageProjection.fromJson(
    Object? json, {
    required MessageId expectedMessageId,
  }) {
    final object = _object(json, 'SavedMessageProjection');
    if (object['availability'] == 'unavailable') {
      _keys(object, {'availability', 'reason'});
      return UnavailableSavedMessageProjection._(
        SavedMessageUnavailableReason.fromJson(object['reason']),
      );
    }
    if (object['availability'] != 'available') {
      throw const FormatException('Invalid saved message availability.');
    }
    _keys(object, {'availability', 'current'});
    return AvailableSavedMessageProjection._(
      SavedMessageCurrentProjection.fromJson(
        object['current'],
        expectedMessageId: expectedMessageId,
      ),
    );
  }

  Map<String, Object?> toJson();
}

final class AvailableSavedMessageProjection extends SavedMessageProjection {
  const AvailableSavedMessageProjection._(this.current) : super._();

  final SavedMessageCurrentProjection current;

  @override
  Map<String, Object?> toJson() => {
        'availability': 'available',
        'current': current.toJson(),
      };
}

enum SavedMessageUnavailableReason {
  deleted,
  inaccessible;

  static SavedMessageUnavailableReason fromJson(Object? json) => switch (json) {
        'deleted' => deleted,
        'inaccessible' => inaccessible,
        _ => throw const FormatException('Invalid saved message reason.'),
      };
}

/// Exact shell: no current message, reply reference, or stale source content.
final class UnavailableSavedMessageProjection extends SavedMessageProjection {
  const UnavailableSavedMessageProjection._(this.reason) : super._();

  final SavedMessageUnavailableReason reason;

  @override
  Map<String, Object?> toJson() => {
        'availability': 'unavailable',
        'reason': reason.name,
      };
}

final class SavedMessageCurrentProjection {
  SavedMessageCurrentProjection._({
    required this.id,
    required this.conversationId,
    required this.author,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    required this.content,
    required List<MessageAttachmentMetadata> attachmentMetadata,
    this.replyTo,
  }) : attachmentMetadata = List.unmodifiable(attachmentMetadata);

  factory SavedMessageCurrentProjection.fromJson(
    Object? json, {
    required MessageId expectedMessageId,
  }) {
    final object = _object(json, 'SavedMessageCurrentProjection');
    _keys(object, {
      'id',
      'conversationId',
      'author',
      'sequence',
      'createdAt',
      'updatedAt',
      'revision',
      'content',
      'attachmentMetadata',
    }, optional: {
      'replyTo'
    });
    final id = MessageId.fromJson(object['id']);
    if (id != expectedMessageId) {
      throw const FormatException(
          'Current id must match saved entry messageId.');
    }
    // Saved projections retain the existing content shape, without copying
    // source attribution, forward snapshots, or reply metadata into content.
    final contentJson = _object(object['content'], 'content');
    _keys(contentJson, {'format', 'text'},
        optional: {'mentions', 'attachments', 'blocks'});
    final content = MessageContent.fromJson(contentJson);
    final metadataJson = object['attachmentMetadata'];
    if (metadataJson is! List) {
      throw const FormatException('attachmentMetadata must be an array.');
    }
    final metadata =
        metadataJson.map(MessageAttachmentMetadata.fromJson).toList();
    final references = content.attachments ?? <MessageAttachmentReference>[];
    if (metadata.length != references.length) {
      throw const FormatException('Attachment metadata must match references.');
    }
    final seen = <AttachmentId>{};
    for (var i = 0; i < references.length; i++) {
      if (!seen.add(references[i].attachmentId) ||
          metadata[i].attachmentId != references[i].attachmentId) {
        throw const FormatException(
            'Attachment metadata must follow unique references.');
      }
    }
    final sequence = MessageSequence.fromJson(object['sequence']);
    if (sequence.value < 0 || sequence.value > 9007199254740991) {
      throw const FormatException(
          'Sequence must be a nonnegative safe integer.');
    }
    return SavedMessageCurrentProjection._(
      id: id,
      conversationId: ConversationId.fromJson(object['conversationId']),
      author: MessageAuthorIdentity.fromJson(object['author']),
      sequence: sequence,
      createdAt: IsoTimestamp.fromJson(object['createdAt']),
      updatedAt: IsoTimestamp.fromJson(object['updatedAt']),
      revision: MessageRevisionMetadata.fromJson(object['revision']),
      content: content,
      attachmentMetadata: metadata,
      // containsKey rejects an explicitly supplied null via the canonical parser.
      replyTo: object.containsKey('replyTo')
          ? MessageReplyReference.fromJson(object['replyTo'])
          : null,
    );
  }

  final MessageId id;
  final ConversationId conversationId;
  final MessageAuthorIdentity author;
  final MessageSequence sequence;
  final IsoTimestamp createdAt;
  final IsoTimestamp updatedAt;
  final MessageRevisionMetadata revision;
  final MessageContent content;
  final List<MessageAttachmentMetadata> attachmentMetadata;

  /// Identity only. The reply source is in [conversationId].
  final MessageReplyReference? replyTo;

  Map<String, Object?> toJson() => {
        'id': id.toJson(),
        'conversationId': conversationId.toJson(),
        'author': author.toJson(),
        'sequence': sequence.toJson(),
        'createdAt': createdAt.toJson(),
        'updatedAt': updatedAt.toJson(),
        'revision': revision.toJson(),
        'content': content.toJson(),
        'attachmentMetadata':
            attachmentMetadata.map((item) => item.toJson()).toList(),
        if (replyTo case final reference?) 'replyTo': reference.toJson(),
      };
}

Map<String, Object?> _object(Object? json, String name) {
  if (json is! Map<String, Object?>) {
    throw FormatException('$name must be an object.');
  }
  return json;
}

void _keys(Map<String, Object?> object, Set<String> required,
    {Set<String> optional = const {}}) {
  if (!required.every(object.containsKey) ||
      object.keys
          .any((key) => !required.contains(key) && !optional.contains(key))) {
    throw const FormatException(
        'Missing required or unknown saved projection field.');
  }
}
