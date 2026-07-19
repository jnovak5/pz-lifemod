-- ============================================================
-- LifeMod_Shared.lua
-- Shared constants, utilities, and version info.
-- Loaded in BOTH server and client contexts.
-- ============================================================

LifeMod = LifeMod or {}

-- ── Version ──────────────────────────────────────────────────
LifeMod.VERSION       = "1.0.0"
LifeMod.VERSION_INT   = 1000          -- integer for comparison checks

-- ── Network module name (must be unique across all mods) ─────
LifeMod.MODULE        = "LifeMod"

-- ── Network commands  (server → client) ──────────────────────
LifeMod.CMD_LIFE_UPDATE  = "notify_life_update"
LifeMod.CMD_ELIMINATED   = "notify_eliminated"

-- ── Network commands (client → server) ───────────────────────
LifeMod.CMD_PLAYER_CONNECT = "player_connect"
LifeMod.CMD_REQUEST_LIVES  = "request_lives"
LifeMod.CMD_CONSUME_LIFE   = "consume_life"
LifeMod.CMD_ADMIN_VIEW    = "admin_view"
LifeMod.CMD_ADMIN_SET     = "admin_set"
LifeMod.CMD_ADMIN_RESTORE = "admin_restore"

-- ── Admin set actions ────────────────────────────────────────
LifeMod.ACTION_VIEW   = "view"
LifeMod.ACTION_ADD    = "add"
LifeMod.ACTION_REMOVE = "remove"
LifeMod.ACTION_SET    = "set"
LifeMod.ACTION_RESTORE= "restore"

-- ── Access levels allowed to use admin commands ───────────────
-- Build 42 access level strings.  Moderator included by default.
LifeMod.ADMIN_ACCESS_LEVELS = {
    ["Admin"]     = true,
    ["Moderator"] = true,
}

-- ── Hard limits ───────────────────────────────────────────────
LifeMod.MAX_LIVES_HARD_CAP = 99          -- absolute ceiling for any lives value
LifeMod.MIN_LIVES          = 0

-- ── Death cooldown window (seconds) ──────────────────────────
-- Duplicate OnPlayerDeath events within this window are suppressed.
LifeMod.DEATH_COOLDOWN_SECS = 5

-- ── Logging prefix ───────────────────────────────────────────
LifeMod.LOG_TAG = "[LIFEMOD]"

-- ── Default sandbox fallbacks (used when SandboxVars not ready)
LifeMod.DEFAULT_STARTING_LIVES                   = 5
LifeMod.DEFAULT_ENABLE_SYSTEM                    = true
LifeMod.DEFAULT_KICK_ON_ELIMINATION              = true
LifeMod.DEFAULT_PRIVATE_DEATH_MESSAGE            = true
LifeMod.DEFAULT_RESTORE_LIVES                    = 1    -- lives given by /lifes restore
LifeMod.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION  = false

-- ============================================================
-- Utility: safe sandbox config reader
-- Returns the sandbox value or the supplied default.
-- ============================================================
function LifeMod.getSandboxCfg(key, default)
    local ok, sv = pcall(function() return SandboxVars.LifeMod end)
    if ok and sv and sv[key] ~= nil then
        return sv[key]
    end
    return default
end

-- ============================================================
-- Utility: check whether a player object has admin access
-- Works both client-side (own player) and server-side.
-- ============================================================
function LifeMod.isAuthorised(player)
    if not player then return false end
    local level = player:getAccessLevel()
    return LifeMod.ADMIN_ACCESS_LEVELS[level] == true
end

-- ============================================================
-- Utility: clamp integer to [lo, hi]
-- ============================================================
function LifeMod.clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

-- ============================================================
-- Utility: returns true only in a real multiplayer session.
-- Server-side: isMultiplayer() exists in PZ Build 42.
-- Used to auto-disable the system in singleplayer.
-- ============================================================
function LifeMod.isMultiplayerSession()
    local ok, result = pcall(function()
        return isMultiplayer and isMultiplayer()
    end)
    return ok and result == true
end

-- ============================================================
-- Utility: ISO-8601 timestamp string (server-side only)
-- Falls back to epoch seconds on client.
-- ============================================================
function LifeMod.timestamp()
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
function LifeMod.getRestoreLives()
    return LifeMod.clamp(
        LifeMod.getSandboxCfg("RestoreLives", LifeMod.DEFAULT_RESTORE_LIVES),
        1,
        LifeMod.MAX_LIVES_HARD_CAP
    )
end
