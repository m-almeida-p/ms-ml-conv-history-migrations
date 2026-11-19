-- Camel conversation history, part 3: the map from our conversation to the one in Microsoft Foundry.
-- Every statement is repeatable, so running it over an existing table is safe.
--
-- Foundry creates a conversation's id itself (conv_ + an opaque string); a caller cannot choose it. The Camel
-- Karavan sync project (conv-history-sync) creates one Foundry conversation per conversation of ours and keeps the
-- pair here, so the API (conv-history-api) can find the Foundry conversation that holds the messages of ours.
-- A row exists only after Foundry confirmed the conversation: the conversation list shows only these.
CREATE TABLE IF NOT EXISTS camel_history.foundry_conversation_map (
    conversation_id         VARCHAR(128) PRIMARY KEY,
    foundry_conversation_id TEXT         NOT NULL UNIQUE,
    last_synced_sequence    INT          NOT NULL CHECK (last_synced_sequence >= 1),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE camel_history.foundry_conversation_map IS
    'Our conversation id and the id Foundry gave to the conversation that holds its messages. Written by conv-history-sync.';
COMMENT ON COLUMN camel_history.foundry_conversation_map.conversation_id IS
    'The conversation id of conversation_events (conv_v1_<uuid>). Primary key.';
COMMENT ON COLUMN camel_history.foundry_conversation_map.foundry_conversation_id IS
    'The id Foundry generated (conv_ + an opaque string). Unique: two of our conversations never share one.';
COMMENT ON COLUMN camel_history.foundry_conversation_map.last_synced_sequence IS
    'The highest sequence of this conversation already sent to Foundry. A lower sequence that is not in foundry_item_map arrived late.';
COMMENT ON COLUMN camel_history.foundry_conversation_map.created_at IS
    'When the Foundry conversation was recorded here.';
