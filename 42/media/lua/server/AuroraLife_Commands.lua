-- ============================================================
-- AuroraLife_Commands.lua
-- Server-side chat command parser.
-- Handles /lifes <sub-command> [args...]
-- All output is private to the requesting admin.
-- ============================================================

require "AuroraLife_Shared"
require "AuroraLife_DataStore"
require "AuroraLife_Admin"
require "AuroraLife_Logger"

AuroraLife.Commands = AuroraLife.Commands or {}

local Cmds  = AuroraLife.Commands
local DS    = AuroraLife.DataStore
local Admin = AuroraLife.Admin
local LOG   = AuroraLife.Logger

-- ── Send a private reply to the requesting admin ──────────────
local function reply(player, msg)
    -- sendServerCommand with the module + CMD sends to that specific player.
    -- For chat messages we use the game's built-in private messaging helper.
    -- In PZ, sendServerCommand(player, module, cmd, args) sends ONLY to that player.
    sendServerCommand(player, AuroraLife.MODULE, "admin_reply", { message = msg })
end

-- ── Usage string ──────────────────────────────────────────────
local USAGE = table.concat({
    "[AuroraLife] Commands:",
    "  /lifes check <PlayerName>",
    "  /lifes add <PlayerName> <amount>",
    "  /lifes remove <PlayerName> <amount>",
    "  /lifes set <PlayerName> <amount>",
    "  /lifes debug",
}, "\n")

-- ── Sub-command handlers ──────────────────────────────────────

local function cmdCheck(player, args)
    local targetName = args[1]
    if not targetName then
        reply(player, "[AuroraLife] Usage: /lifes check <PlayerName>")
        return
    end

    local username = Admin.resolveTargetUsername(targetName)
    if not username then
        reply(player, "[AuroraLife] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, AuroraLife.ACTION_VIEW, username)
    reply(player, msg)
end

local function cmdAdd(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[AuroraLife] Usage: /lifes add <PlayerName> <amount>")
        return
    end
    if amount <= 0 then
        reply(player, "[AuroraLife] Amount must be positive.")
        return
    end

    local username = Admin.resolveTargetUsername(targetName)
    if not username then
        reply(player, "[AuroraLife] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, AuroraLife.ACTION_ADD, username, amount)
    reply(player, msg)
end

local function cmdRemove(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[AuroraLife] Usage: /lifes remove <PlayerName> <amount>")
        return
    end
    if amount <= 0 then
        reply(player, "[AuroraLife] Amount must be positive.")
        return
    end

    local username = Admin.resolveTargetUsername(targetName)
    if not username then
        reply(player, "[AuroraLife] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, AuroraLife.ACTION_REMOVE, username, amount)
    reply(player, msg)
end

local function cmdSet(player, args)
    local targetName = args[1]
    local amount     = tonumber(args[2])
    if not targetName or not amount then
        reply(player, "[AuroraLife] Usage: /lifes set <PlayerName> <amount>")
        return
    end

    local username = Admin.resolveTargetUsername(targetName)
    if not username then
        reply(player, "[AuroraLife] Player not found: " .. targetName)
        return
    end

    local ok, msg = Admin.executeOperation(player, AuroraLife.ACTION_SET, username, amount)
    reply(player, msg)
end

local function cmdDebug(player, _args)
    local records = DS.getAllRecords()
    local count   = 0
    local parts   = { "[AuroraLife] DEBUG REPORT" }

    for uname, rec in pairs(records) do
        count = count + 1
        parts[#parts+1] = string.format(
            "  [%d] %s | Lives=%d/%d | Elim=%s | Deaths=%d | Last=%s",
            count,
            tostring(rec.username),
            rec.lives, rec.maxLives,
            tostring(rec.eliminated),
            rec.deathCount,
            rec.lastSeen and tostring(rec.lastSeen) or "N/A"
        )
    end

    parts[#parts+1] = string.format("  Total records: %d", count)
    parts[#parts+1] = string.format("  DataStore loaded: %s", tostring(DS.isLoaded()))
    parts[#parts+1] = string.format("  AuroraLife version: %s", AuroraLife.VERSION)
    parts[#parts+1] = string.format("  EnableSystem: %s",
        tostring(AuroraLife.getSandboxCfg("EnableSystem", AuroraLife.DEFAULT_ENABLE_SYSTEM)))
    parts[#parts+1] = string.format("  StartingLives: %d",
        AuroraLife.getSandboxCfg("StartingLives", AuroraLife.DEFAULT_STARTING_LIVES))

    -- Active death cooldowns
    local cooldowns = AuroraLife.DeathHandler and AuroraLife.DeathHandler.getCooldownTable() or {}
    local cdCount   = 0
    for uname, ts in pairs(cooldowns) do
        cdCount = cdCount + 1
        parts[#parts+1] = string.format("  [COOLDOWN] User=%s since=%d", uname, ts)
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
    debug   = cmdDebug,
}

-- ============================================================
-- Public: entry point — parse and dispatch /lifes <sub> [args]
-- Called from OnServerCommand in AuroraLife_Server.lua
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
    if not AuroraLife.isAuthorised(player) then
        reply(player, "[AuroraLife] Access denied.")
        return true
    end

    local sub  = tokens[2]
    if not sub then
        reply(player, USAGE)
        return true
    end

    local handler = subCommands[sub]
    if not handler then
        reply(player, "[AuroraLife] Unknown sub-command: " .. sub .. "\n" .. USAGE)
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
