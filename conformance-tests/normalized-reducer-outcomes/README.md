# Normalized reducer outcome projection

This suite reduces the same ordered durable-event sequence in TypeScript and
Dart, then compares a shared JSON projection. The projection is intentionally
smaller than either runtime's complete cache state.

Every projected collection is an array sorted by its explicit identifier (and
member/reaction arrays are sorted lexicographically). It includes canonical
entity identity, revisions, ordered timeline identifiers, current-actor state,
attachment metadata, huddle state, and the last accepted replay cursor.

It omits runtime-specific classes and enum representations, optimistic and
pending state, callbacks and subscriptions, pagination, recent-event replay
windows, persistence encoding, and other transient or storage-only details.
Adding a field here is a cross-runtime compatibility commitment.
