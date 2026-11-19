-- Dead letters, part 1: the schema.
-- The dead letters of every consumer live in the schema `dead_letter`: no single service owns them, so they are not in the schema of any
-- service. Every name in the later migrations is qualified with it, because migrate runs with the default search_path.
-- The version table of this folder (shared_dead_letter_schema_migrations) stays in public: migrate creates it before the first
-- migration runs, when this schema does not exist yet.
CREATE SCHEMA IF NOT EXISTS dead_letter;

COMMENT ON SCHEMA dead_letter IS
    'Records a consumer could not handle and will not retry: the record as received, why it was refused and what was done about it. Shared by every consumer.';
