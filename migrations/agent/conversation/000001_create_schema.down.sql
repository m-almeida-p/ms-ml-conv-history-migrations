-- Drops the schema. It has no CASCADE on purpose: if anything else was put in it, this fails instead of deleting it.
-- It runs after the down of every later migration, which drop the table, the trigger and the publication.
DROP SCHEMA IF EXISTS event_store;
