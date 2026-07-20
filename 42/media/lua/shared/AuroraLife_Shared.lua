-- ============================================================
-- AuroraLife_Shared.lua
-- Shared constants, utilities, and version info.
-- Loaded in BOTH server and client contexts.
-- ============================================================

AuroraLife = AuroraLife or {}

-- ── Version ──────────────────────────────────────────────────
AuroraLife.VERSION       = "1.0.0"
AuroraLife.VERSION_INT   = 1000          -- integer for comparison checks

-- ── Network module name (must be unique across all mods) ─────
AuroraLife.MODULE        = "AuroraLife"

-- ── Network commands  (server → client) ──────────────────────
AuroraLife.CMD_LIFE_UPDATE  = "notify_life_update"
AuroraLife.CMD_ELIMINATED   = "notify_eliminated"

-- ── Network commands (client → server) ───────────────────────
AuroraLife.CMD_PLAYER_CONNECT = "player_connect"
AuroraLife.CMD_REQUEST_LIVES  = "request_lives"
AuroraLife.CMD_LIFE_UPDATE    = "life_update"
AuroraLife.CMD_CONSUME_LIFE   = "consume_life"
AuroraLife.CMD_ELIMINATED     = "eliminated"
AuroraLife.CMD_NEW_CHARACTER  = "new_character"
AuroraLife.CMD_SET_GODMODE    = "set_godmode"
AuroraLife.CMD_HEAL_PLAYER    = "heal_player"
AuroraLife.CMD_LOG_EVENT      = "log_event"
AuroraLife.CMD_ADMIN_VIEW    = "admin_view"
AuroraLife.CMD_ADMIN_SET     = "admin_set"
AuroraLife.CMD_ADMIN_RESTORE = "admin_restore"

-- ── Admin set actions ────────────────────────────────────────
AuroraLife.ACTION_VIEW   = "view"
AuroraLife.ACTION_ADD    = "add"
AuroraLife.ACTION_REMOVE = "remove"
AuroraLife.ACTION_SET    = "set"
AuroraLife.ACTION_RESTORE= "restore"

-- ── Access levels allowed to use admin commands ───────────────
-- Build 42 access level strings.  Moderator included by default.
AuroraLife.ADMIN_ACCESS_LEVELS = {
    ["Admin"]     = true,
    ["Moderator"] = true,
}

-- ── Hard limits ───────────────────────────────────────────────
AuroraLife.MAX_LIVES_HARD_CAP = 99          -- absolute ceiling for any lives value
AuroraLife.MIN_LIVES          = 0

-- ── Death cooldown window (seconds) ──────────────────────────
-- Duplicate OnPlayerDeath events within this window are suppressed.
AuroraLife.DEATH_COOLDOWN_SECS = 5

-- ── Logging prefix ───────────────────────────────────────────
AuroraLife.LOG_TAG = "[AuroraLife]"

-- ── Default sandbox fallbacks (used when SandboxVars not ready)
AuroraLife.DEFAULT_STARTING_LIVES                   = 5
AuroraLife.DEFAULT_ENABLE_SYSTEM                    = true
AuroraLife.DEFAULT_KICK_ON_ELIMINATION              = true
AuroraLife.DEFAULT_PRIVATE_DEATH_MESSAGE            = true
AuroraLife.DEFAULT_RESTORE_LIVES                    = 1    -- lives given by /lifes restore
AuroraLife.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION  = false

-- ============================================================
-- Utility: safe sandbox config reader
-- Returns the sandbox value or the supplied default.
-- ============================================================
function AuroraLife.getSandboxCfg(key, default)
    local ok, sv = pcall(function() return SandboxVars.AuroraLife end)
    if ok and sv and sv[key] ~= nil then
        return sv[key]
    end
    return default
end

-- ============================================================
-- Utility: check whether a player object has admin access
-- Works both client-side (own player) and server-side.
-- ============================================================
function AuroraLife.isAuthorised(player)
    if not player then return false end
    local level = player:getAccessLevel()
    return AuroraLife.ADMIN_ACCESS_LEVELS[level] == true
end

-- ============================================================
-- Utility: clamp integer to [lo, hi]
-- ============================================================
function AuroraLife.clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

-- ============================================================
-- Utility: returns true only in a real multiplayer session.
-- Server-side: isMultiplayer() exists in PZ Build 42.
-- Used to auto-disable the system in singleplayer.
-- ============================================================
function AuroraLife.isMultiplayerSession()
    local ok, result = pcall(function()
        return isMultiplayer and isMultiplayer()
    end)
    return ok and result == true
end

-- ============================================================
-- Utility: ISO-8601 timestamp string (server-side only)
-- Falls back to epoch seconds on client.
-- ============================================================
function AuroraLife.timestamp()
    -- getGameTime():getRealworldSecondsSinceEpoch() may not exist on all builds;
    -- use os.date as a reliable cross-platform fallback.
    local ok, result = pcall(function()
        return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end)
    if ok then return result end
    return tostring(os.time())
end

-- ============================================================
-- Utility: get the configurable restore lives amount
-- ============================================================
function AuroraLife.getRestoreLives()
    return AuroraLife.clamp(
        AuroraLife.getSandboxCfg("RestoreLives", AuroraLife.DEFAULT_RESTORE_LIVES),
        1,
        AuroraLife.MAX_LIVES_HARD_CAP
    )
end
