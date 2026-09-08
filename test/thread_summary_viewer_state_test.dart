import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const _threadId = ConversationId('thread-1');
const _viewerId = UserId('viewer-1');
const _lastReplyAt = IsoTimestamp('2026-09-01T12:00:00.000Z');
const _completeCoverage = ThreadSummarySequenceCoverage(
  threadId: _threadId,
  complete: true,
  latestSequence: MessageSequence(10),
);

ThreadSummaryFacts _facts({IsoTimestamp? lastReplyAt = _lastReplyAt}) =>
    ThreadSummaryFacts(
      threadId: _threadId,
      // Shared reply counts are deliberately different from sequence coverage.
      replyCount: 27,
      participantIds: const [UserId('user-z'), _viewerId, UserId('user-a')],
      lastReplyAt: lastReplyAt,
    );

ConversationReadState _cursor({
  int lastReadSequence = 4,
  int? manualUnreadFromSequence,
  UserId userId = _viewerId,
  ConversationId threadId = _threadId,
}) =>
    ConversationReadState(
      conversationId: threadId,
      userId: userId,
      lastReadSequence: MessageSequence(lastReadSequence),
      manualUnreadFromSequence: manualUnreadFromSequence == null
          ? null
          : MessageSequence(manualUnreadFromSequence),
      updatedAt: const IsoTimestamp('2026-09-01T12:01:00.000Z'),
    );

ThreadSummaryViewerBasis _basis({
  required ConversationReadState? cursor,
  bool? membershipActive = true,
  bool? following = false,
  ThreadSummarySequenceCoverage? coverage = _completeCoverage,
  ConversationId expectedThreadId = _threadId,
}) =>
    ThreadSummaryViewerBasis(
      expectedUserId: _viewerId,
      expectedThreadId: expectedThreadId,
      membershipActive: membershipActive,
      following: following,
      cursor: cursor,
      sequenceCoverage: coverage,
    );

void main() {
  group('projectThreadSummaryForViewer', () {
    for (final row in [
      (read: 10, unread: 0),
      (read: 4, unread: 6),
    ]) {
      test('N=10 and R=${row.read} yields ${row.unread} unread', () {
        final summary = projectThreadSummaryForViewer(
          _facts(),
          _basis(cursor: _cursor(lastReadSequence: row.read)),
        );

        expect(summary.unreadCount, row.unread);
      });
    }

    test('manual marker M=8 yields 3 unread; clearing it yields 0', () {
      final facts = _facts();
      final marked = _cursor(
        lastReadSequence: 10,
        manualUnreadFromSequence: 8,
      );
      final cleared = _cursor(lastReadSequence: 10);
      final markedBefore = marked.toJson();
      final clearedBefore = cleared.toJson();

      expect(
        projectThreadSummaryForViewer(facts, _basis(cursor: marked))
            .unreadCount,
        3,
      );
      expect(
        projectThreadSummaryForViewer(facts, _basis(cursor: cleared))
            .unreadCount,
        0,
      );
      expect(marked.toJson(), markedBefore);
      expect(cleared.toJson(), clearedBefore);
    });

    const eligibilityCases = <({bool? active, bool? following, int? unread})>[
      (active: true, following: true, unread: 6),
      (active: true, following: false, unread: 6),
      (active: true, following: null, unread: 6),
      (active: false, following: true, unread: 6),
      (active: false, following: false, unread: 0),
      (active: false, following: null, unread: null),
      (active: null, following: true, unread: 6),
      (active: null, following: false, unread: null),
      (active: null, following: null, unread: null),
    ];
    for (final row in eligibilityCases) {
      test('membership=${row.active}, following=${row.following}', () {
        final summary = projectThreadSummaryForViewer(
          _facts(),
          _basis(
            cursor: _cursor(),
            membershipActive: row.active,
            following: row.following,
          ),
        );

        expect(summary.unreadCount, row.unread);
      });
    }

    test('both known false yields zero without cursor or coverage', () {
      final summary = projectThreadSummaryForViewer(
        _facts(),
        _basis(
          cursor: null,
          coverage: null,
          membershipActive: false,
          following: false,
        ),
      );

      expect(summary.unreadCount, 0);
    });

    for (final row in <({String name, ConversationReadState? cursor})>[
      (name: 'absent', cursor: null),
      (name: 'wrong user', cursor: _cursor(userId: const UserId('other-user'))),
      (
        name: 'wrong thread',
        cursor: _cursor(threadId: const ConversationId('other-thread')),
      ),
    ]) {
      test('${row.name} cursor leaves eligible viewer unread unknown', () {
        final summary = projectThreadSummaryForViewer(
          _facts(),
          _basis(cursor: row.cursor),
        );

        expect(summary.unreadCount, isNull);
      });
    }

    test('missing in-memory cursor is distinct from authoritative R=0', () {
      final facts = _facts();

      expect(
        projectThreadSummaryForViewer(facts, _basis(cursor: null)).unreadCount,
        isNull,
      );
      expect(
        projectThreadSummaryForViewer(
          facts,
          _basis(cursor: _cursor(lastReadSequence: 0)),
        ).unreadCount,
        10,
      );
    });

    const invalidCoverageCases = <({
      String name,
      ThreadSummarySequenceCoverage? coverage,
    })>[
      (name: 'absent', coverage: null),
      (
        name: 'incomplete',
        coverage: ThreadSummarySequenceCoverage(
          threadId: _threadId,
          complete: false,
          latestSequence: MessageSequence(10),
        ),
      ),
      (
        name: 'wrong thread',
        coverage: ThreadSummarySequenceCoverage(
          threadId: ConversationId('other-thread'),
          complete: true,
          latestSequence: MessageSequence(10),
        ),
      ),
    ];
    for (final row in invalidCoverageCases) {
      test('${row.name} coverage cannot be replaced by shared facts', () {
        final facts = _facts();
        final summary = projectThreadSummaryForViewer(
          facts,
          _basis(cursor: _cursor(), coverage: row.coverage),
        );

        expect(facts.replyCount, 27);
        expect(facts.lastReplyAt, _lastReplyAt);
        expect(summary.unreadCount, isNull);
      });
    }

    for (final active in [true, false]) {
      test('expected thread mismatch stays unknown with membership=$active',
          () {
        const otherThread = ConversationId('other-thread');
        final summary = projectThreadSummaryForViewer(
          _facts(),
          _basis(
            expectedThreadId: otherThread,
            membershipActive: active,
            cursor: _cursor(threadId: otherThread),
            coverage: const ThreadSummarySequenceCoverage(
              threadId: otherThread,
              complete: true,
              latestSequence: MessageSequence(10),
            ),
          ),
        );

        expect(summary.unreadCount, isNull);
      });
    }

    test('ahead-of-latest read cursor clamps unread to zero', () {
      final summary = projectThreadSummaryForViewer(
        _facts(),
        _basis(cursor: _cursor(lastReadSequence: 15)),
      );

      expect(summary.unreadCount, 0);
    });

    for (final timestamp in [_lastReplyAt, null]) {
      test('preserves shared facts and inputs with lastReplyAt=$timestamp', () {
        final facts = _facts(lastReplyAt: timestamp);
        final factsBefore = facts.toJson();
        final read = _cursor(lastReadSequence: 10);
        final unread = _cursor(lastReadSequence: 4);
        final marked = _cursor(
          lastReadSequence: 10,
          manualUnreadFromSequence: 8,
        );
        final cursors = [read, unread, marked];
        final cursorsBefore = [for (final cursor in cursors) cursor.toJson()];
        final bases = [
          _basis(cursor: read),
          _basis(cursor: unread),
          _basis(cursor: marked),
          _basis(cursor: null),
          _basis(cursor: null, membershipActive: false, following: false),
        ];

        for (final basis in bases) {
          final summary = projectThreadSummaryForViewer(facts, basis);

          expect(summary.threadId, facts.threadId);
          expect(summary.replyCount, facts.replyCount);
          expect(summary.participantIds, orderedEquals(facts.participantIds));
          expect(summary.lastReplyAt, timestamp);
          expect(facts.toJson(), factsBefore);
          expect(
            [for (final cursor in cursors) cursor.toJson()],
            cursorsBefore,
          );
        }
      });
    }
  });
}
