-- Agent Web UI, part 1: the schema.
-- The tables of this flow (web_ui/chat) live in the schema `web_ui`, not in `public`. Every name in the later migrations is
-- qualified with it, because migrate runs with the default search_path. The web UI connects with search_path=web_ui.
-- The version table of this folder (web_ui_chat_schema_migrations) stays in public: migrate creates it before the first
-- migration runs, when this schema does not exist yet.
CREATE SCHEMA IF NOT EXISTS web_ui;

COMMENT ON SCHEMA web_ui IS
    'Agent Web UI (inside-agent-web-ui): its users, sessions and chat conversations with the messages of each.';
