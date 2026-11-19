-- Drops the schema. It has no CASCADE on purpose: if anything else was put in it, this fails instead of deleting it.
-- It runs after the down of every later migration, which drop their tables and the view.
DROP SCHEMA IF EXISTS history;
