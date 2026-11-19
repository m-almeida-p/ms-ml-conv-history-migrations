-- Event store, part 2: the table. This directory is the definition of the schema.
-- Every name is qualified with the schema event_store (created by 000001). Every statement is IF NOT EXISTS, so running it over existing tables is safe.

CREATE TABLE IF NOT EXISTS event_store.conversation_events (
    conversation_id VARCHAR(128) NOT NULL,
    sequence        INT          NOT NULL,
    event_name      VARCHAR(128) NOT NULL,

    -- Which shape of that event this row holds. It is the one thing that cannot
    -- be added retroactively: without it, a payload written before a change is
    -- indistinguishable from one written after.
    event_version   INT          NOT NULL DEFAULT 1,

    -- The fact itself. It never carries the conversation id, the actor or any
    -- request identifier: those describe the call, not what happened.
    payload         JSONB        NOT NULL,

    -- The context around the fact that has no column of its own: causation id and
    -- run id. A field that would change if the same fact arrived through another
    -- channel belongs in the metadata or a column, never in the payload.
    metadata        JSONB        NOT NULL DEFAULT '{}'::jsonb,

    -- Four fields of the context, stored as columns and nowhere else: the metadata
    -- document does not repeat them, so a row pays for each value once (the CDC
    -- feeds two more tables with the row). They are plain columns, not generated
    -- ones, so logical replication (the CDC reading this table) publishes them on
    -- every Postgres version: generated columns are not published before Postgres 18.
    --
    -- The first two are the ones worth searching by. Tracing one operation end
    -- to end is the investigation query, and finding everything belonging to an
    -- account is what per-user isolation and erasure need. The actor is here so
    -- that who caused a fact reads as a column, not as a path into the JSON. The
    -- rest stays in the JSON document, because it is read once the row has
    -- already been found.
    --
    -- The flow says which flow the fact took place in (p2p, bill_payment, ...), so
    -- one table serves every flow and a reader can tell them apart. It is the flow
    -- that was active when the fact arrived, and NULL outside any flow.
    --
    -- All four may be NULL: an event recorded with thin metadata is still worth
    -- far more than one not recorded at all.
    correlation_id  TEXT,
    id_yape_account TEXT,
    actor           TEXT CHECK (actor IN ('user', 'agent', 'system')),
    flow            TEXT,

    occurred_at     TIMESTAMPTZ  NOT NULL,

    PRIMARY KEY (conversation_id, sequence)
);

CREATE INDEX IF NOT EXISTS conversation_events_correlation_id_idx
    ON event_store.conversation_events (correlation_id);

CREATE INDEX IF NOT EXISTS conversation_events_id_yape_account_idx
    ON event_store.conversation_events (id_yape_account, occurred_at DESC);

COMMENT ON TABLE  event_store.conversation_events IS
    'Append-only log of what happened in a conversation. Rows are never updated or deleted outside an erasure request.';
COMMENT ON COLUMN event_store.conversation_events.conversation_id IS
    'The exchange this event belongs to: the contextId of the A2A message, validated by the agent. Never derived here: only the caller knows whether a turn continues an earlier conversation.';
COMMENT ON COLUMN event_store.conversation_events.sequence IS
    'Position within the stream. Assigned on append and used for optimistic locking: a mismatch means another writer got there first.';
COMMENT ON COLUMN event_store.conversation_events.event_name IS
    'Which fact this is. Maps to a Go type through the catalogue in events.go; a name with no entry there is skipped on read rather than failing the load.';
COMMENT ON COLUMN event_store.conversation_events.event_version IS
    'Which shape of the event this payload holds. Readers upcast from here to the current version before decoding. Cannot be added retroactively, which is why it ships before any event needs it.';
COMMENT ON COLUMN event_store.conversation_events.payload IS
    'The fact itself, and nothing else. Carries no conversation id, no account, no request identifier: those describe the call rather than what happened.';
COMMENT ON COLUMN event_store.conversation_events.metadata IS
    'Context around the fact that has no column of its own: causation id and run id. The correlation id, account, actor and flow are columns and are not repeated here.';
COMMENT ON COLUMN event_store.conversation_events.correlation_id IS
    'Ties every step of one process together and is the key for tracing an operation end to end across services and logs.';
COMMENT ON COLUMN event_store.conversation_events.id_yape_account IS
    'The account the conversation belongs to, named as Yape names it. Survives payload erasure on purpose: it is what finds the rows to erase.';
COMMENT ON COLUMN event_store.conversation_events.actor IS
    'Who caused the fact, as a business role: user, agent or system. It changes event by event within one stream, unlike the account.';
COMMENT ON COLUMN event_store.conversation_events.flow IS
    'The flow the fact took place in, such as p2p or bill_payment, and NULL when it took place outside any flow. It is the flow active when the fact arrived: a message the user writes carries the flow they were in when they wrote it, so the message that opens a flow has none and the message that leaves one carries the flow it was in.';
COMMENT ON COLUMN event_store.conversation_events.occurred_at IS
    'When the fact happened, in UTC. Not when the row was written: a retry records the original time.';
