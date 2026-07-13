-- ============================================================
-- LifeMod_SandboxVars.lua
-- Sandbox option definitions for LifeMod.
-- These appear in the Sandbox Settings panel in-game and in
-- the server's SandboxVars.lua configuration file.
--
-- Access at runtime:
--   SandboxVars.LifeMod.StartingLives
--   SandboxVars.LifeMod.EnableSystem
--   etc.
-- ============================================================

VERSION = 1,

option EnableSystem {
    type        = boolean,
    default     = true,
    page        = LifeMod,
    translation = LifeMod_EnableSystem,
}

option StartingLives {
    type        = integer,
    default     = 5,
    min         = 1,
    max         = 99,
    page        = LifeMod,
    translation = LifeMod_StartingLives,
}

option KickOnElimination {
    type        = boolean,
    default     = true,
    page        = LifeMod,
    translation = LifeMod_KickOnElimination,
}

option EnablePrivateDeathMessage {
    type        = boolean,
    default     = true,
    page        = LifeMod,
    translation = LifeMod_EnablePrivateDeathMessage,
}

option RemoveFromWhitelistOnElimination {
    type        = boolean,
    default     = false,
    page        = LifeMod,
    translation = LifeMod_RemoveFromWhitelistOnElimination,
}

option RestoreLives {
    type        = integer,
    default     = 1,
    min         = 1,
    max         = 99,
    page        = LifeMod,
    translation = LifeMod_RestoreLives,
}
