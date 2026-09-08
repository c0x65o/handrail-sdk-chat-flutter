const addReactionInputFixture = <String, Object?>{
  'operation': 'add_reaction',
  'messageId': 'message-1',
  'reactionKey': '👍',
  'idempotencyKey': 'reaction-attempt-1',
};

const removeReactionInputFixture = <String, Object?>{
  'operation': 'remove_reaction',
  'messageId': 'message-1',
  'reactionKey': '👍',
  'idempotencyKey': 'reaction-attempt-2',
};

Map<String, Object?> addReactionResultFixture(String status) =>
    <String, Object?>{
      'operation': 'add_reaction',
      'reconciliationStatus': status,
      'messageId': 'message-1',
      'reactionKey': '👍',
      'count': 3,
      'reactedByCurrentUser': true,
    };

Map<String, Object?> removeReactionResultFixture(String status) =>
    <String, Object?>{
      'operation': 'remove_reaction',
      'reconciliationStatus': status,
      'messageId': 'message-1',
      'reactionKey': '👍',
      'count': 2,
      'reactedByCurrentUser': false,
    };
