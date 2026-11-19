-- Event store, part 3: the table is append-only, and the database says so.
-- Every name is qualified with the schema event_store. Every statement is repeatable, so running it over an existing table is safe.
--
-- A fact that happened is never edited. The CDC publishes a row once, when it is
-- inserted, and the history service refuses a second version of the same position
-- for good: an UPDATE would change the store and leave the history with the old row,
-- and nothing would bring them back together. INSERT stays open, as does DELETE
-- (retention, erasure, tests); TRUNCATE is not a row update and is left alone
-- (the CDC ignores it, and the explorer empties the table with it).
--
-- The grant is the first line of defence: the role the service writes with should
-- not hold UPDATE on this table. The trigger is the second, and the only one that
-- also holds for the table's owner and for an operator at a prompt.
--
-- It is a statement trigger, so it runs once per UPDATE and never touches a row.
-- It does not fire on INSERT: it costs the write path nothing.
CREATE OR REPLACE FUNCTION event_store.conversation_events_forbid_update() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'conversation_events is append-only: UPDATE refused'
        USING ERRCODE = 'integrity_constraint_violation',
              HINT = 'Record a new event instead of changing a stored one.';
END;
$$;

DROP TRIGGER IF EXISTS conversation_events_append_only ON event_store.conversation_events;
CREATE TRIGGER conversation_events_append_only
    BEFORE UPDATE ON event_store.conversation_events
    FOR EACH STATEMENT EXECUTE FUNCTION event_store.conversation_events_forbid_update();

COMMENT ON FUNCTION event_store.conversation_events_forbid_update() IS
    'Refuses every UPDATE of conversation_events: the store is append-only.';
COMMENT ON TRIGGER conversation_events_append_only ON event_store.conversation_events IS
    'Keeps the store and the history it feeds from diverging: a stored fact is never edited.';
