-- ============================================================
-- SVRPLife_Shared.lua
-- Shared constants, utilities, and version info.
-- Loaded in BOTH server and client contexts.
-- ============================================================

SVRPLife = SVRPLife or {}

-- ── Version ──────────────────────────────────────────────────
SVRPLife.VERSION       = "1.0.0"
SVRPLife.VERSION_INT   = 1000          -- integer for comparison checks

-- ── Network module name (must be unique across all mods) ─────
SVRPLife.MODULE        = "SVRPLife"

-- ── Network commands  (server → client) ──────────────────────
SVRPLife.CMD_LIFE_UPDATE  = "notify_life_update"
SVRPLife.CMD_ELIMINATED   = "notify_eliminated"

-- ── Network commands (client → server) ───────────────────────
SVRPLife.CMD_PLAYER_CONNECT = "player_connect"
SVRPLife.CMD_REQUEST_LIVES  = "request_lives"
SVRPLife.CMD_CONSUME_LIFE   = "consume_life"
SVRPLife.CMD_NEW_CHARACTER  = "new_character"
SVRPLife.CMD_SET_GODMODE    = "set_godmode"
SVRPLife.CMD_HEAL_PLAYER    = "heal_player"
SVRPLife.CMD_LOG_EVENT      = "log_event"
SVRPLife.CMD_ADMIN_VIEW    = "admin_view"
SVRPLife.CMD_ADMIN_SET     = "admin_set"

-- ── Admin set actions ────────────────────────────────────────
SVRPLife.ACTION_VIEW   = "view"
SVRPLife.ACTION_ADD    = "add"
SVRPLife.ACTION_REMOVE = "remove"
SVRPLife.ACTION_SET    = "set"

-- ── Access levels allowed to use admin commands ───────────────
-- Build 42 access level strings.  Moderator included by default.
SVRPLife.ADMIN_ACCESS_LEVELS = {
    ["admin"]     = true,
    ["moderator"] = true,
}

-- ── Hard limits ───────────────────────────────────────────────
SVRPLife.MAX_LIVES_HARD_CAP = 99          -- absolute ceiling for any lives value
SVRPLife.MIN_LIVES          = 0

-- ── Death cooldown window (seconds) ──────────────────────────
-- Duplicate OnPlayerDeath events within this window are suppressed.
SVRPLife.DEATH_COOLDOWN_SECS = 5

-- ── Logging prefix ───────────────────────────────────────────
SVRPLife.LOG_TAG = "[SVRPLife]"

-- ── Default sandbox fallbacks (used when SandboxVars not ready)
SVRPLife.DEFAULT_STARTING_LIVES                   = 2
SVRPLife.DEFAULT_ENABLE_SYSTEM                    = true
SVRPLife.DEFAULT_KICK_ON_ELIMINATION              = true
SVRPLife.DEFAULT_PRIVATE_DEATH_MESSAGE            = true
SVRPLife.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION  = false

-- ============================================================
-- Utility: safe sandbox config reader
-- Returns the sandbox value or the supplied default.
-- ============================================================
function SVRPLife.getSandboxCfg(key, default)
    local ok, sv = pcall(function() return SandboxVars.SVRPLife end)
    if ok and sv and sv[key] ~= nil then
        return sv[key]
    end
    return default
end

-- ============================================================
-- Utility: check whether a player object has admin access
-- Works both client-side (own player) and server-side.
-- ============================================================
function SVRPLife.isAuthorised(player)
    if not player then return false end
    -- Allow full access in singleplayer for testing
    if not isClient() and not isServer() then return true end
    
    local level = player:getAccessLevel()
    if not level then return false end
    return SVRPLife.ADMIN_ACCESS_LEVELS[tostring(level):lower()] == true
end

-- ============================================================
-- Utility: clamp integer to [lo, hi]
-- ============================================================
function SVRPLife.clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

-- ============================================================
-- Utility: returns true only in a real multiplayer session.
-- Server-side: isMultiplayer() exists in PZ Build 42.
-- Used to auto-disable the system in singleplayer.
-- ============================================================
function SVRPLife.isMultiplayerSession()
    local ok, result = pcall(function()
        return isMultiplayer and isMultiplayer()
    end)
    return ok and result == true
end

-- ============================================================
-- Utility: ISO-8601 timestamp string (server-side only)
-- Falls back to epoch seconds on client.
-- ============================================================
function SVRPLife.timestamp()
    -- getGameTime():getRealworldSecondsSinceEpoch() may not exist on all builds;
    -- use os.date as a reliable cross-platform fallback.
    local ok, result = pcall(function()
        return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end)
    if ok then return result end
    return tostring(os.time())
end
