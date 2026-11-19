-- Drops the map. The items stay in their Foundry conversations; with the map gone the sync would send them again,
-- so drop foundry_conversation_map (000003) in the same down-migration and let the sync rebuild.
DROP TABLE IF EXISTS camel_history.foundry_item_map;
