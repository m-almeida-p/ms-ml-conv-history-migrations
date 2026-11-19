-- Agent Web UI, part 2: users, sessions, conversations and messages.
-- Every name is qualified with the schema web_ui (created by 000001). Every statement is IF NOT EXISTS, so running it over
-- existing tables is safe.

CREATE TABLE IF NOT EXISTS web_ui.users (
    id            uuid PRIMARY KEY,
    -- Stored lowercase so the UNIQUE constraint is case-insensitive. The
    -- application normalizes before writing; the CHECK makes a miss fail loudly.
    email         text NOT NULL
                  CONSTRAINT users_email_key UNIQUE
                  CONSTRAINT users_email_normalized CHECK (email <> '' AND email = lower(email)),
    password_hash text NOT NULL CONSTRAINT users_password_hash_present CHECK (password_hash <> ''),
    created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  web_ui.users IS 'The people who can sign in to the web UI.';
COMMENT ON COLUMN web_ui.users.id IS 'The user.';
COMMENT ON COLUMN web_ui.users.email IS 'The sign-in name, lowercase, unique.';
COMMENT ON COLUMN web_ui.users.password_hash IS 'The password as a hash; the password itself is never stored.';
COMMENT ON COLUMN web_ui.users.created_at IS 'When the user was created.';

-- id holds the SHA-256 hex digest of the cookie token, never the token itself,
-- so a leaked table cannot be replayed as live sessions.
CREATE TABLE IF NOT EXISTS web_ui.sessions (
    id         text PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES web_ui.users (id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON web_ui.sessions (user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON web_ui.sessions (expires_at);

COMMENT ON TABLE  web_ui.sessions IS 'The signed-in sessions of the users, until they expire.';
COMMENT ON COLUMN web_ui.sessions.id IS 'The SHA-256 hex digest of the cookie token, never the token.';
COMMENT ON COLUMN web_ui.sessions.user_id IS 'The user the session belongs to; the session goes with the user.';
COMMENT ON COLUMN web_ui.sessions.expires_at IS 'When the session stops being valid.';
COMMENT ON COLUMN web_ui.sessions.created_at IS 'When the session started.';

CREATE TABLE IF NOT EXISTS web_ui.conversations (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES web_ui.users (id) ON DELETE CASCADE,
    title      text NOT NULL CONSTRAINT conversations_title_length CHECK (char_length(title) BETWEEN 1 AND 120),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
-- The sidebar lists a user's conversations, newest activity first.
CREATE INDEX IF NOT EXISTS conversations_user_updated_idx ON web_ui.conversations (user_id, updated_at DESC);

COMMENT ON TABLE  web_ui.conversations IS 'The chats of a user, listed in the sidebar.';
COMMENT ON COLUMN web_ui.conversations.id IS 'The conversation.';
COMMENT ON COLUMN web_ui.conversations.user_id IS 'The user who owns it; the conversation goes with the user.';
COMMENT ON COLUMN web_ui.conversations.title IS 'The name shown in the sidebar, 1 to 120 characters.';
COMMENT ON COLUMN web_ui.conversations.created_at IS 'When the conversation was started.';
COMMENT ON COLUMN web_ui.conversations.updated_at IS 'When it last changed; the sidebar orders by it, newest first.';

CREATE TABLE IF NOT EXISTS web_ui.messages (
    id              uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES web_ui.conversations (id) ON DELETE CASCADE,
    seq             integer NOT NULL CONSTRAINT messages_seq_positive CHECK (seq > 0),
    role            text NOT NULL CONSTRAINT messages_role_known CHECK (role IN ('user', 'assistant')),
    -- Markdown, exactly as the agent produced it (or the user typed it).
    content         text NOT NULL DEFAULT '',
    status          text NOT NULL
                    CONSTRAINT messages_status_known CHECK (status IN ('pending', 'streaming', 'complete', 'stopped', 'failed')),
    error           text NOT NULL DEFAULT '',
    -- ttft_ms, duration_ms, usage {prompt, completion}, tool_calls []
    meta            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT messages_conversation_seq_key UNIQUE (conversation_id, seq)
);

COMMENT ON TABLE  web_ui.messages IS 'The messages of a conversation: what the user typed and what the agent answered.';
COMMENT ON COLUMN web_ui.messages.id IS 'The message.';
COMMENT ON COLUMN web_ui.messages.conversation_id IS 'The conversation it belongs to; the message goes with it.';
COMMENT ON COLUMN web_ui.messages.seq IS 'Position in the conversation, from 1; unique within it.';
COMMENT ON COLUMN web_ui.messages.role IS 'Who wrote it: user or assistant.';
COMMENT ON COLUMN web_ui.messages.content IS 'Markdown, exactly as the agent produced it or the user typed it.';
COMMENT ON COLUMN web_ui.messages.status IS 'pending, streaming, complete, stopped or failed.';
COMMENT ON COLUMN web_ui.messages.error IS 'Why a failed message failed; empty otherwise.';
COMMENT ON COLUMN web_ui.messages.meta IS 'Time to first token, duration, token usage and the tool calls of the answer (ttft_ms, duration_ms, usage, tool_calls).';
COMMENT ON COLUMN web_ui.messages.created_at IS 'When the message was created.';
COMMENT ON COLUMN web_ui.messages.updated_at IS 'When it last changed (a streamed answer is updated as it grows).';
