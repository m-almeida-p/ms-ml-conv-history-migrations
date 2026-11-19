-- Camel conversation history, part 4: the map from our message to the item that holds it in Foundry.
-- Every statement is repeatable, so running it over an existing table is safe.
--
-- Foundry gives every item an id (msg_ + an opaque string) and its paging cursors are those ids, while ours is the
-- sequence of the event. This table is the inbox of the sync: the key (conversation_id, sequence) means a message is
-- sent once, and the API reads it both ways (sequence to item to build a cursor, item to sequence to answer).
-- Foundry has no idempotency key, so a row here is the only proof that an item was sent.
CREATE TABLE IF NOT EXISTS camel_history.foundry_item_map (
    conversation_id VARCHAR(128) NOT NULL
        REFERENCES camel_history.foundry_conversation_map (conversation_id) ON DELETE CASCADE,
    sequence        INT          NOT NULL CHECK (sequence >= 1),
    foundry_item_id TEXT         NOT NULL UNIQUE,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, sequence)
);

COMMENT ON TABLE camel_history.foundry_item_map IS
    'Our message (conversation_id, sequence) and the Foundry item that holds it. Written by conv-history-sync, read by conv-history-api.';
COMMENT ON COLUMN camel_history.foundry_item_map.conversation_id IS
    'Our conversation id. Deleting its row in foundry_conversation_map deletes these rows too, which is how a rebuild starts clean.';
COMMENT ON COLUMN camel_history.foundry_item_map.sequence IS
    'The sequence of the event that became this message. Also the message _id the API serves.';
COMMENT ON COLUMN camel_history.foundry_item_map.foundry_item_id IS
    'The id Foundry generated for the item (msg_ + an opaque string). Unique; also the cursor Foundry pages with.';
COMMENT ON COLUMN camel_history.foundry_item_map.synced_at IS
    'When the item was recorded here.';
