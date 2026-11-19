-- Drops the map. The Foundry conversations stay in Foundry as orphans: list them with
-- ms-ml-camel-conv-history-bs scripts/foundry-cleanup-orphans.sh before dropping, or the sync will create new ones.
-- Down-migrate 000004 first: its table refers to this one.
DROP TABLE IF EXISTS camel_history.foundry_conversation_map;
