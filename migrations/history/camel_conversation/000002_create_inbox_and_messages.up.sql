-- Camel conversation history, part 2: the inbox and the chat read model, in the schema camel_history (created by 000001).
-- Every statement is IF NOT EXISTS, so running it over existing tables is safe.
--
-- Same tables as history/conversation (000002), in a schema of their own. They are filled by the Camel
-- Karavan consumer (ms-ml-camel-conv-history-bs), which reads the same topic as ms-ml-conv-history-bs. The
-- separate schema keeps the two consumers' rows apart, so their results can be compared and neither
-- writes into the other's tables. Every name is qualified, because migrate runs with the default search_path.
-- The inbox keeps every conversation_events row that reaches this service, before
-- and whether or not it becomes a chat message. It is the source a rebuild replays.
CREATE TABLE IF NOT EXISTS camel_history.conversation_inbox (
    conversation_id VARCHAR(128) NOT NULL,
    sequence        INT          NOT NULL,
    event_name      VARCHAR(128) NOT NULL,
    event_version   INT          NOT NULL,
    payload         JSONB        NOT NULL,
    metadata        JSONB        NOT NULL,
    correlation_id  TEXT,
    id_yape_account TEXT,
    actor           TEXT CHECK (actor IN ('user', 'agent', 'system')),
    flow            TEXT,
    occurred_at     TIMESTAMPTZ  NOT NULL,
    kafka_topic     TEXT         NOT NULL,
    kafka_partition INT          NOT NULL,
    kafka_offset    BIGINT       NOT NULL,
    received_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    projected_at    TIMESTAMPTZ,
    CONSTRAINT conversation_inbox_stream_key PRIMARY KEY (conversation_id, sequence)
);

COMMENT ON TABLE  camel_history.conversation_inbox IS
    'Every conversation_events row received from Kafka, stored once. Replaying it rebuilds conversation_messages.';
COMMENT ON COLUMN camel_history.conversation_inbox.conversation_id IS
    'The conversation the event belongs to (the A2A contextId). With sequence, the dedupe key: a redelivery hits ON CONFLICT DO NOTHING.';
COMMENT ON COLUMN camel_history.conversation_inbox.sequence IS
    'Position of the event in its conversation stream, the same value as conversation_events.sequence. Starts at 1.';
COMMENT ON COLUMN camel_history.conversation_inbox.event_name IS
    'Name of the event, such as UserMessageSent.';
COMMENT ON COLUMN camel_history.conversation_inbox.event_version IS
    'Shape version of the payload when it was written.';
COMMENT ON COLUMN camel_history.conversation_inbox.payload IS
    'The event payload, parsed from the JSON string Debezium sends.';
COMMENT ON COLUMN camel_history.conversation_inbox.metadata IS
    'The event metadata, parsed from the JSON string Debezium sends.';
COMMENT ON COLUMN camel_history.conversation_inbox.correlation_id IS
    'Copy of the conversation_events column of the same name.';
COMMENT ON COLUMN camel_history.conversation_inbox.id_yape_account IS
    'Copy of the conversation_events column of the same name: the customer account.';
COMMENT ON COLUMN camel_history.conversation_inbox.actor IS
    'Who caused the fact, as a business role: user, agent or system.';
COMMENT ON COLUMN camel_history.conversation_inbox.flow IS
    'Copy of the conversation_events column of the same name: the flow the fact took place in, such as p2p, or NULL outside any flow.';
COMMENT ON COLUMN camel_history.conversation_inbox.occurred_at IS
    'The conversation_events occurred_at: when the fact happened, in UTC.';
COMMENT ON COLUMN camel_history.conversation_inbox.kafka_topic IS
    'Topic the record was read from. Provenance only.';
COMMENT ON COLUMN camel_history.conversation_inbox.kafka_partition IS
    'Partition the record was read from. Provenance only.';
COMMENT ON COLUMN camel_history.conversation_inbox.kafka_offset IS
    'Offset of the record in its partition. Provenance only.';
COMMENT ON COLUMN camel_history.conversation_inbox.received_at IS
    'When this service stored the event.';
COMMENT ON COLUMN camel_history.conversation_inbox.projected_at IS
    'When the event was projected, set in the same transaction as the projection. A skipped event is stamped too.';

-- Only the chat between the user and the assistant, shaped after the Smooch message.
CREATE TABLE IF NOT EXISTS camel_history.conversation_messages (
    conversation_id VARCHAR(128) NOT NULL,
    sequence        INT          NOT NULL,
    role            TEXT         NOT NULL CHECK (role IN ('appUser', 'appMaker')),
    author_id       TEXT         NOT NULL,
    type            TEXT         NOT NULL DEFAULT 'text',
    text            TEXT         NOT NULL,
    truncated       BOOLEAN      NOT NULL DEFAULT FALSE,
    event_name      VARCHAR(128) NOT NULL,
    id_yape_account TEXT,
    flow            TEXT,
    occurred_at     TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (conversation_id, sequence)
);

-- The conversation list asks for one account's conversations, newest first.
CREATE INDEX IF NOT EXISTS conversation_messages_account_idx
    ON camel_history.conversation_messages (id_yape_account, occurred_at DESC);

COMMENT ON TABLE  camel_history.conversation_messages IS
    'The chat history: one row per message between a user and the assistant. Built from conversation_inbox.';
COMMENT ON COLUMN camel_history.conversation_messages.conversation_id IS
    'Smooch conversation._id.';
COMMENT ON COLUMN camel_history.conversation_messages.sequence IS
    'Position of the message''s event in the conversation stream. Orders the chat; gaps are normal because other events fill them. Smooch _id, as a string in the API, unique within the conversation, and the paging cursor.';
COMMENT ON COLUMN camel_history.conversation_messages.role IS
    'Smooch role: appUser for the customer, appMaker for the assistant and guardrail replies.';
COMMENT ON COLUMN camel_history.conversation_messages.author_id IS
    'Smooch authorId: the customer account for appUser, ms-ml-genai-agent-bs for appMaker.';
COMMENT ON COLUMN camel_history.conversation_messages.type IS
    'Smooch message type. Always text for now.';
COMMENT ON COLUMN camel_history.conversation_messages.text IS
    'The message text, as the event recorded it.';
COMMENT ON COLUMN camel_history.conversation_messages.truncated IS
    'Smooch metadata.truncated: the recorded text was cut at the agent''s limit.';
COMMENT ON COLUMN camel_history.conversation_messages.event_name IS
    'The name of the event that produced the message, as in conversation_inbox. Smooch metadata.eventName.';
COMMENT ON COLUMN camel_history.conversation_messages.id_yape_account IS
    'The customer account, used to list their conversations.';
COMMENT ON COLUMN camel_history.conversation_messages.flow IS
    'The flow the message took place in, such as p2p, or NULL outside any flow. A message the user writes carries the flow they were in when they wrote it, so the message that opens a flow has none and the one that leaves it carries the flow it was in.';
COMMENT ON COLUMN camel_history.conversation_messages.occurred_at IS
    'When the event happened, in UTC, as in the event store. Smooch received, sent as Unix seconds. Not when this service stored it: that is conversation_inbox.received_at.';
