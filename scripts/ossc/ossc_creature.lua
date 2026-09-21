---@omw-context local
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
--
-- Creature implementation intentionally shares the exact same runtime as the
-- NPC implementation. Keeping one implementation prevents the creature actor
-- script from drifting and fixes creature-only casting/animation bugs.
-- ============================================================================

return require('scripts.ossc.ossc_npc')
