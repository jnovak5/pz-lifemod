-- ============================================================
-- AuroraLife_Admin.lua
-- Server-side administration enforcement.
-- Handles: OnPlayerConnect gate, new player enrolment,
--          whitelist removal on elimination, and admin operations.
-- ============================================================

require "AuroraLife_Shared"
require "AuroraLife_DataStore"
require "AuroraLife_Logger"

AuroraLife.Admin = AuroraLife.Admin or {}

local Admin = AuroraLife.Admin
local DS  = AuroraLife.DataStore
local LOG = AuroraLife.Logger


-- ============================================================
-- Whitelist removal helper
-- Attempts removal via the PZ server API; logs result either way.
-- username = last-known username string (display name, not SteamID)
-- ============================================================
local function attemptWhitelistRemoval(username)
    local enabled = AuroraLife.getSandboxCfg(
        "RemoveFromWhitelistOnElimination",
        AuroraLife.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION
    )
    if not enabled then return end

    LOG.logSystem("Whitelist: attempting removal of " .. username)

    -- Approach 1: PZ native Lua bridge (most reliable if exposed)
    local ok1 = pcall(function()
        -- Build 42 dedicated server may expose this global
        if removeUserFromWhiteList then
            removeUserFromWhiteList(username)
        elseif removePlayerFromWhiteList then
            removePlayerFromWhiteList(username)
        else
            error("function not found")
        end
    end)

    if ok1 then
        LOG.logSystem("Whitelist: removed " .. username .. " via server API.")
        return
    end

    -- Approach 2: Find and edit the whitelist file directly
    -- PZ whitelist file: <SaveDir>/server/<ServerName>.whitelist
    -- One username per line.
    local ok2 = pcall(function()
        -- Resolve the whitelist path using the same base directory as data files
        local basePath = getModFileRecordFileFullPath("AuroraLife_data.json")
        if not basePath then error("cannot resolve base path") end

        -- Walk up to the Zomboid save root and look for *.whitelist
        -- DataStore path is something like: .../Zomboid/Lua/AuroraLife_data.json
        -- Whitelist is:                      .../Zomboid/Server/<name>.whitelist
        local saveRoot = basePath:match("(.+)[/\\]Lua[/\\]")
        if not saveRoot then error("cannot find save root") end

        local whitelistDir = saveRoot .. "/Server/"

        -- Find whitelist file (first match)
        os.execute('ls "' .. whitelistDir .. '"*.whitelist 2>/dev/null > "' .. whitelistDir .. '_wlist.tmp" || ' ..
                   'dir /b "' .. whitelistDir .. '"*.whitelist 2>nul > "' .. whitelistDir .. '_wlist.tmp"')

        local listF = io.open(whitelistDir .. "_wlist.tmp", "r")
        local wFile = listF and listF:read("*a") or ""
        if listF then listF:close() end
        os.remove(whitelistDir .. "_wlist.tmp")

        local wPath = wFile:match("^%s*([^\n]+)%s*$")
        if not wPath then error("no whitelist file found") end

        -- If listing returned filename only (not full path), prepend dir
        if not wPath:find("[/\\]") then
            wPath = whitelistDir .. wPath
        end

        -- Read, filter out the username, write back
        local f = io.open(wPath, "r")
        if not f then error("cannot open " .. wPath) end
        local lines = {}
        for line in f:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed:lower() ~= username:lower() then
                lines[#lines+1] = trimmed
            end
        end
        f:close()

        local out = io.open(wPath, "w")
        if not out then error("cannot write " .. wPath) end
        out:write(table.concat(lines, "\n"))
        if #lines > 0 then out:write("\n") end
        out:close()
    end)

    if ok2 then
        LOG.logSystem("Whitelist: removed " .. username .. " via direct file edit.")
    else
        LOG.logWarn("Whitelist: automatic removal FAILED for " .. username ..
                    ". Admin must manually remove from server whitelist.")
    end
end

-- Internal: apply elimination side-effects for a player record
-- Used when an admin action causes lives to drop to 0.
-- player may be nil if the target is currently offline.
-- ============================================================
local function applyEliminationEffects(record, player)
    -- Whitelist removal (online or offline — uses username from record)
    attemptWhitelistRemoval(record.username)

    local msgEnabled = AuroraLife.getSandboxCfg(
        "EnablePrivateDeathMessage",
        AuroraLife.DEFAULT_PRIVATE_DEATH_MESSAGE
    )

    -- If the player is currently online, notify them. Do not kick them.
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername():lower() == record.username:lower() then
                if msgEnabled then
                    local msg = "An Admin has eliminated you. Your current run is over."
                    sendServerCommand(p, AuroraLife.MODULE, AuroraLife.CMD_ELIMINATED, { message = msg })
                end
                break
            end
        end
    end
end

-- ============================================================
-- Internal: find an online IsoPlayer by SteamID
-- Returns IsoPlayer or nil
-- ============================================================
local function findOnlinePlayer(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername():lower() == username:lower() then
            return p
        end
    end
    return nil
end

-- ============================================================
-- OnPlayerConnect — elimination gate and enrolment
-- ============================================================
function Admin.onPlayerConnect(player)
    -- MP-only guard
    if not AuroraLife.isMultiplayerSession() then return end

    if not AuroraLife.getSandboxCfg("EnableSystem", AuroraLife.DEFAULT_ENABLE_SYSTEM) then
        return
    end

    if not DS.isLoaded() then
        LOG.logWarn("Admin: player connected before DataStore ready — gate skipped. User=" ..
                    tostring(player:getUsername()))
        return
    end

    local username = tostring(player:getUsername())
    local now      = os.time()

    if not username or username == "" then
        LOG.logWarn("Admin: player connected with invalid username.")
        return
    end

    local record = DS.getRecord(username)

    -- New player: enrol them
    if not record then
        record = DS.newRecord(username)
        DS.setRecord(username, record)
        DS.saveDeferred()
        LOG.logSystem("Admin: new player enrolled — User=" .. username)
        
        sendServerCommand(player, AuroraLife.MODULE, AuroraLife.CMD_LIFE_UPDATE, {
            lives    = record.lives,
            maxLives = record.maxLives,
        })
        return
    end

    -- Update display username and last-seen
    record.username = username
    record.lastSeen = now

    -- Elimination gate
    if record.eliminated then
        LOG.logWarn("Admin: eliminated player reconnected — User=" .. username)

        local msgEnabled = AuroraLife.getSandboxCfg("EnablePrivateDeathMessage", AuroraLife.DEFAULT_PRIVATE_DEATH_MESSAGE)
        if msgEnabled then
            local msg = "You have been eliminated on this server. You must create a new character to continue playing."
            sendServerCommand(player, AuroraLife.MODULE, AuroraLife.CMD_ELIMINATED, { message = msg })
        end
        -- Removed: Connection rejection / Kicking. They can now simply make a new character.
    end

    DS.setRecord(username, record)
    DS.saveDeferred()
    
    sendServerCommand(player, AuroraLife.MODULE, AuroraLife.CMD_LIFE_UPDATE, {
        lives    = record.lives,
        maxLives = record.maxLives or AuroraLife.getSandboxCfg("StartingLives", AuroraLife.DEFAULT_STARTING_LIVES) or 5,
    })
end

-- ============================================================
-- OnPlayerDisconnect — update last-seen, flush if dirty
-- ============================================================
function Admin.onPlayerDisconnect(player)
    if not DS.isLoaded() then return end

    local username = tostring(player:getUsername())
    local record  = DS.getRecord(username)
    if record then
        record.lastSeen = os.time()
        DS.setRecord(username, record)
        DS.flushIfDirty()
    end
end

-- ============================================================
-- Execute an admin operation (called from Commands and UI router)
-- adminPlayer   = IsoPlayer performing the action
-- action        = AuroraLife.ACTION_* constant
-- targetUsername = string username of the target
-- amount        = number (optional, for add/remove/set)
-- reason        = string (optional, for logging)
-- Returns: success (bool), message (string)
-- ============================================================
function Admin.executeOperation(adminPlayer, action, targetUsername, amount, reason)
    -- Double-check server-side admin authorisation
    if not AuroraLife.isAuthorised(adminPlayer) then
        return false, "Access denied: insufficient permissions."
    end

    if not DS.isLoaded() then
        return false, "DataStore not yet loaded. Try again in a moment."
    end

    local adminName = tostring(adminPlayer:getUsername())
    local record    = DS.getRecord(targetUsername)

    if not record and action ~= AuroraLife.ACTION_VIEW then
        return false, "No record found for player: " .. tostring(targetUsername)
    end

    -- ── VIEW ─────────────────────────────────────────────────
    if action == AuroraLife.ACTION_VIEW then
        if not record then
            return true, string.format("No record found for Username=%s", targetUsername)
        end
        return true, string.format(
            "%s | Lives: %d/%d | Deaths: %d",
            record.username,
            record.lives, record.maxLives,
            record.deathCount
        )
    end

    -- ── RESTORE ──────────────────────────────────────────────
    -- Feature completely removed per user request.
    -- Numeric operations require amount
    local num = tonumber(amount)
    if not num then
        return false, "Invalid amount: " .. tostring(amount)
    end
    num = math.floor(num)

    local prev        = record.lives
    local wasElim     = record.eliminated
    local cap         = record.maxLives  -- admin add is capped at season starting amount

    -- ── ADD ──────────────────────────────────────────────────
    if action == AuroraLife.ACTION_ADD then
        record.lives = AuroraLife.clamp(record.lives + num, AuroraLife.MIN_LIVES, cap)
        -- Restore from elimination if lives go positive
        if record.lives > 0 then record.eliminated = false end

    -- ── REMOVE ───────────────────────────────────────────────
    elseif action == AuroraLife.ACTION_REMOVE then
        record.lives = AuroraLife.clamp(record.lives - num, AuroraLife.MIN_LIVES, AuroraLife.MAX_LIVES_HARD_CAP)
        if record.lives <= 0 then
            record.lives      = 0
            record.eliminated = true
        end

    -- ── SET ──────────────────────────────────────────────────
    elseif action == AuroraLife.ACTION_SET then
        record.lives = AuroraLife.clamp(num, AuroraLife.MIN_LIVES, AuroraLife.MAX_LIVES_HARD_CAP)
        if record.lives <= 0 then
            record.lives      = 0
            record.eliminated = true
        else
            record.eliminated = false
        end

    else
        return false, "Unknown action: " .. tostring(action)
    end

    DS.setRecord(targetUsername, record)
    DS.saveImmediate()
    LOG.logAdmin(adminName, string.upper(action), targetUsername, prev, record.lives, reason)

    -- Send update to client if they are online
    local onlinePlayer = findOnlinePlayer(targetUsername)
    if onlinePlayer then
        sendServerCommand(onlinePlayer, AuroraLife.MODULE, AuroraLife.CMD_LIFE_UPDATE, {
            lives      = record.lives,
            maxLives   = record.maxLives,
            eliminated = record.eliminated,
            deathCount = record.deathCount
        })
    end

    -- Apply elimination side-effects if this action newly eliminated the player
    if record.eliminated and not wasElim then
        applyEliminationEffects(record, onlinePlayer)
    end

    return true, string.format(
        "%s | %s | Lives: %d to %d",
        record.username, string.upper(action), prev, record.lives
    )
end


-- ============================================================
-- Resolve a target Username from a player name string.
-- Searches online players first, then DataStore records.
-- Returns exact stored username (string) or nil.
-- ============================================================
function Admin.resolveTargetUsername(targetName)
    -- Search online players
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername():lower() == targetName:lower() then
                return tostring(p:getUsername())
            end
        end
    end

    -- Search DataStore records
    for uname, rec in pairs(DS.getAllRecords()) do
        if uname:lower() == targetName:lower() then
            return uname
        end
    end

    return nil
end
