-- ============================================================
-- LifeMod_Commands.lua
-- Server-side chat command parser.
-- Handles /lifes <sub-command> [args...]
-- All output is private to the requesting admin.
-- ============================================================

require "LifeMod_Shared"
require "LifeMod_DataStore"
require "LifeMod_Admin"
require "LifeMod_Logger"

LifeMod.Commands = LifeMod.Commands or {}

local Cmds  = LifeMod.Commands
local DS    = LifeMod.DataStore
local Admin = LifeMod.Admin
local LOG   = LifeMod.Logger

-- ── Send a private reply to the requesting admin ──────────────
local function reply(player, msg)
    -- sendServerCommand with the module + CMD sends to that specific player.
    -- For chat messages we use the game's built-in private messaging helper.
    -- In PZ, sendServerCommand(player, module, cmd, args) sends ONLY to that player.
    sendServerCommand(player, LifeMod.MODULE, "admin_reply", { message = msg })
end

-- ── Usage string ──────────────────────────────────────────────
local USAGE = table.concat({
    "[LifeMod] Commands:",
    "  /lifes check <PlayerName>",
    "  /lifes add <PlayerName> <amount>",
    "  /lifes remove <PlayerName> <amount>",
    "  /lifes set <PlayerName> <amount>",
    "  /lifes restore <PlayerName>",
    "  /lifes debug",
}, "\n")

-- ── Sub-command handlers ──────────────────────────────────────

local function cmdCheck(player, args)
    local targetName = args[1]
    if not targetName then
        reply(player, "[LifeMod] Usage: /lifes check <PlayerName>")
        return
    end

    local steamID = Admin.resolveTargetSteamID(targetName)
    if not steamID then
        reply(player, "[LifeMod] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, LifeMod.ACTION_VIEW, steamID)
    reply(player, msg)
end

local function cmdAdd(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[LifeMod] Usage: /lifes add <PlayerName> <amount>")
        return
    end
    if amount <= 0 then
        reply(player, "[LifeMod] Amount must be positive.")
        return
    end

    local steamID = Admin.resolveTargetSteamID(targetName)
    if not steamID then
        reply(player, "[LifeMod] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, LifeMod.ACTION_ADD, steamID, amount)
    reply(player, msg)
end

local function cmdRemove(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[LifeMod] Usage: /lifes remove <PlayerName> <amount>")
        return
    end
    if amount <= 0 then
        reply(player, "[LifeMod] Amount must be positive.")
        return
    end

    local steamID = Admin.resolveTargetSteamID(targetName)
    if not steamID then
        reply(player, "[LifeMod] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, LifeMod.ACTION_REMOVE, steamID, amount)
    reply(player, msg)
end

local function cmdSet(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[LifeMod] Usage: /lifes set <PlayerName> <amount>")
        return
    end

    local steamID = Admin.resolveTargetSteamID(targetName)
    if not steamID then
        reply(player, "[LifeMod] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, LifeMod.ACTION_SET, steamID, amount)
    reply(player, msg)
end

local function cmdRestore(player, args)
    local targetName = args[1]
    if not targetName then
        reply(player, "[LifeMod] Usage: /lifes restore <PlayerName>")
        return
    end

    local steamID = Admin.resolveTargetSteamID(targetName)
    if not steamID then
        reply(player, "[LifeMod] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, LifeMod.ACTION_RESTORE, steamID)
    reply(player, msg)
end

local function cmdDebug(player, _args)
    local records = DS.getAllRecords()
    local count   = 0
    local parts   = { "[LifeMod] DEBUG REPORT" }

    for sid, rec in pairs(records) do
        count = count + 1
        parts[#parts+1] = string.format(
            "  [%d] %s (SteamID=%s) | Lives=%d/%d | Elim=%s | Deaths=%d | Last=%s",
            count,
            tostring(rec.username),
            tostring(sid),
            rec.lives, rec.maxLives,
            tostring(rec.eliminated),
            rec.deathCount,
            rec.lastSeen and tostring(rec.lastSeen) or "N/A"
        )
    end

    parts[#parts+1] = string.format("  Total records: %d", count)
    parts[#parts+1] = string.format("  DataStore loaded: %s", tostring(DS.isLoaded()))
    parts[#parts+1] = string.format("  LifeMod version: %s", LifeMod.VERSION)
    parts[#parts+1] = string.format("  EnableSystem: %s",
        tostring(LifeMod.getSandboxCfg("EnableSystem", LifeMod.DEFAULT_ENABLE_SYSTEM)))
    parts[#parts+1] = string.format("  StartingLives: %d",
        LifeMod.getSandboxCfg("StartingLives", LifeMod.DEFAULT_STARTING_LIVES))

    -- Active death cooldowns
    local cooldowns = LifeMod.DeathHandler and LifeMod.DeathHandler.getCooldownTable() or {}
    local cdCount   = 0
    for sid, ts in pairs(cooldowns) do
        cdCount = cdCount + 1
        parts[#parts+1] = string.format("  [COOLDOWN] SteamID=%s since=%d", sid, ts)
    end
    if cdCount == 0 then
        parts[#parts+1] = "  [COOLDOWN] none active"
    end

    local fullMsg = table.concat(parts, "\n")
    reply(player, fullMsg)
    LOG.logSystem("Admin debug report requested by " .. tostring(player:getUsername()))
end

-- ── Sub-command dispatch table ────────────────────────────────
local subCommands = {
    check   = cmdCheck,
    add     = cmdAdd,
    remove  = cmdRemove,
    set     = cmdSet,
    restore = cmdRestore,
    debug   = cmdDebug,
}

-- ============================================================
-- Public: entry point — parse and dispatch /lifes <sub> [args]
-- Called from OnServerCommand in LifeMod_Server.lua
-- ============================================================
function Cmds.handleChatCommand(player, fullCommand)
    -- fullCommand = "lifes check Bob" (without leading slash)
    -- Split into tokens
    local tokens = {}
    for token in fullCommand:gmatch("%S+") do
        tokens[#tokens+1] = token:lower()
    end

    -- Ensure first token is "lifes"
    if tokens[1] ~= "lifes" then return false end

    -- Auth check
    if not LifeMod.isAuthorised(player) then
        reply(player, "[LifeMod] Access denied.")
        return true
    end

    local sub  = tokens[2]
    if not sub then
        reply(player, USAGE)
        return true
    end

    local handler = subCommands[sub]
    if not handler then
        reply(player, "[LifeMod] Unknown sub-command: " .. sub .. "\n" .. USAGE)
        return true
    end

    -- Build args (everything after sub-command, preserving original case for names)
    local rawTokens = {}
    for token in fullCommand:gmatch("%S+") do
        rawTokens[#rawTokens+1] = token
    end
    local args = {}
    for i = 3, #rawTokens do
        args[#args+1] = rawTokens[i]
    end

    handler(player, args)
    return true
end
