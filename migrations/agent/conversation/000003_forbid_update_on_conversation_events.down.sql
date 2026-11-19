-- Removes the append-only guard; the table and its rows stay.
DROP TRIGGER IF EXISTS conversation_events_append_only ON event_store.conversation_events;
DROP FUNCTION IF EXISTS event_store.conversation_events_forbid_update();
