-- Camel conversation history, part 2: one row per conversation of an account, for the conversation list.
-- Every statement is repeatable, so running it over an existing table is safe.
--
-- Same table as history/conversation (000003), in the camel_history schema (created by 000001).
--
-- The list of an account's conversations needs, for each one, how many messages it has and when its
-- first and last message were. Grouping conversation_messages answers that, but it reads every
-- message the account ever sent on every page, so a page costs what the account's history costs.
-- This table keeps the answer, so a page reads only the rows it returns.
--
-- The consumer keeps it, in the same transaction that writes a message: a message that is new adds
-- one to the count and widens the first and last times, and nothing else touches it. Those updates
-- commute, so events that arrive in any order, or two writers at once, end with the same row.
-- A message with no account belongs to no account's list and is not counted.
--
-- There is no backfill: the schema starts empty and the consumer fills it as it reads the topic.
CREATE TABLE IF NOT EXISTS camel_history.conversation_summaries (
    id_yape_account   TEXT         NOT NULL,
    conversation_id   VARCHAR(128) NOT NULL,
    message_count     INT          NOT NULL CHECK (message_count > 0),
    first_occurred_at TIMESTAMPTZ  NOT NULL,
    last_occurred_at  TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (id_yape_account, conversation_id),
    CHECK (first_occurred_at <= last_occurred_at)
);

-- The order of the list: most recent first, the conversation id (larger first) breaking a tie. Both
-- columns run the same way on purpose: the cursor is the pair (last_occurred_at, conversation_id), and
-- Postgres turns a comparison of two such pairs into the boundary of an index scan only when the
-- columns run in the same direction. A page then starts at its cursor and stops after the rows it returns.
CREATE INDEX IF NOT EXISTS conversation_summaries_list_idx
    ON camel_history.conversation_summaries (id_yape_account, last_occurred_at DESC, conversation_id DESC);

COMMENT ON TABLE  camel_history.conversation_summaries IS
    'One row per conversation of an account: its message count and the times of its first and last message. The conversation list reads it. Kept by the consumer with conversation_messages.';
COMMENT ON COLUMN camel_history.conversation_summaries.id_yape_account IS
    'The customer account the conversation belongs to. With conversation_id, the primary key.';
COMMENT ON COLUMN camel_history.conversation_summaries.conversation_id IS
    'The conversation (the A2A contextId).';
COMMENT ON COLUMN camel_history.conversation_summaries.message_count IS
    'How many chat messages of this account the conversation has in conversation_messages.';
COMMENT ON COLUMN camel_history.conversation_summaries.first_occurred_at IS
    'occurred_at of the earliest of those messages.';
COMMENT ON COLUMN camel_history.conversation_summaries.last_occurred_at IS
    'occurred_at of the latest of those messages. Orders the conversation list and is the time part of its cursor.';
