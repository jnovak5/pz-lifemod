-- ============================================================
-- LifeMod_Admin.lua
-- Server-side administration enforcement.
-- Handles: OnPlayerConnect gate, new player enrolment,
--          whitelist removal on elimination, and admin operations.
-- ============================================================

require "LifeMod_Shared"
require "LifeMod_DataStore"
require "LifeMod_Logger"

LifeMod.Admin = LifeMod.Admin or {}

local Admin = LifeMod.Admin
local DS    = LifeMod.DataStore
local LOG   = LifeMod.Logger

-- ============================================================
-- Whitelist removal helper
-- Attempts removal via the PZ server API; logs result either way.
-- username = last-known username string (display name, not SteamID)
-- ============================================================
local function attemptWhitelistRemoval(username, steamID)
    local enabled = LifeMod.getSandboxCfg(
        "RemoveFromWhitelistOnElimination",
        LifeMod.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION
    )
    if not enabled then return end

    LOG.logSystem("Whitelist: attempting removal of " .. username .. " (SteamID=" .. steamID .. ")")

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
        local basePath = getModFileRecordFileFullPath("LifeMod_data.json")
        if not basePath then error("cannot resolve base path") end

        -- Walk up to the Zomboid save root and look for *.whitelist
        -- DataStore path is something like: .../Zomboid/Lua/LifeMod_data.json
        -- Whitelist is:                      .../Zomboid/Server/<name>.whitelist
        local saveRoot = basePath:match("(.+)[/\\]Lua[/\\]")
        if not saveRoot then error("cannot find save root") end

        local whitelistDir = saveRoot .. "/Server/"

        -- Find whitelist file (first match)
        local lf = io.open(whitelistDir .. "_list.tmp", "w")
        if lf then lf:close() end
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

-- ============================================================
-- Internal: apply elimination side-effects for a player record
-- Used when an admin action causes lives to drop to 0.
-- player may be nil if the target is currently offline.
-- ============================================================
local function applyEliminationEffects(record, player)
    -- Whitelist removal (online or offline — uses username from record)
    attemptWhitelistRemoval(record.username, record.steamID)

    -- If the player is currently online, notify + kick
    if player then
        local msgEnabled = LifeMod.getSandboxCfg(
            "EnablePrivateDeathMessage",
            LifeMod.DEFAULT_PRIVATE_DEATH_MESSAGE
        )
        if msgEnabled then
            local msg = "You have been eliminated by a server administrator. Contact an admin for assistance."
            sendServerCommand(player, LifeMod.MODULE, LifeMod.CMD_ELIMINATED, { message = msg })
        end

        local kickEnabled = LifeMod.getSandboxCfg("KickOnElimination", LifeMod.DEFAULT_KICK_ON_ELIMINATION)
        if kickEnabled then
            local ticksRemaining = math.ceil(3000 / (1000/20))
            local tickCount = 0
            local function doKick()
                tickCount = tickCount + 1
                if tickCount >= ticksRemaining then
                    Events.OnTick.Remove(doKick)
                    pcall(function() kickPlayer(player) end)
                end
            end
            Events.OnTick.Add(doKick)
        end
    end
end

-- ============================================================
-- Internal: find an online IsoPlayer by SteamID
-- Returns IsoPlayer or nil
-- ============================================================
local function findOnlinePlayer(steamID)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and tostring(p:getSteamID()) == steamID then
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
    if not LifeMod.isMultiplayerSession() then return end

    if not LifeMod.getSandboxCfg("EnableSystem", LifeMod.DEFAULT_ENABLE_SYSTEM) then
        return
    end

    if not DS.isLoaded() then
        LOG.logWarn("Admin: player connected before DataStore ready — gate skipped. User=" ..
                    tostring(player:getUsername()))
        return
    end

    local steamID  = tostring(player:getSteamID())
    local username = tostring(player:getUsername())
    local now      = os.time()

    if not steamID or steamID == "" or steamID == "0" then
        LOG.logWarn("Admin: player connected with invalid SteamID. User=" .. username)
        return
    end

    local record = DS.getRecord(steamID)

    -- New player: enrol them
    if not record then
        record = DS.newRecord(steamID, username)
        DS.setRecord(steamID, record)
        DS.saveDeferred()
        LOG.logSystem("Admin: new player enrolled — SteamID=" .. steamID .. " | User=" .. username)
        return
    end

    -- Update display username and last-seen
    record.username = username
    record.lastSeen = now

    -- Elimination gate
    if record.eliminated then
        LOG.logWarn("Admin: eliminated player connection attempt — SteamID=" .. steamID .. " | User=" .. username)

        local msgEnabled = LifeMod.getSandboxCfg("EnablePrivateDeathMessage", LifeMod.DEFAULT_PRIVATE_DEATH_MESSAGE)
        if msgEnabled then
            local msg = "You have been eliminated on this server and may not play. Please contact a server administrator."
            sendServerCommand(player, LifeMod.MODULE, LifeMod.CMD_ELIMINATED, { message = msg })
        end

        local kickEnabled = LifeMod.getSandboxCfg("KickOnElimination", LifeMod.DEFAULT_KICK_ON_ELIMINATION)
        if kickEnabled then
            local ticksRemaining = math.ceil(3000 / (1000/20))
            local tickCount = 0
            local function doKick()
                tickCount = tickCount + 1
                if tickCount >= ticksRemaining then
                    Events.OnTick.Remove(doKick)
                    pcall(function() kickPlayer(player) end)
                end
            end
            Events.OnTick.Add(doKick)
        end
    end

    DS.setRecord(steamID, record)
    DS.saveDeferred()
end

-- ============================================================
-- OnPlayerDisconnect — update last-seen, flush if dirty
-- ============================================================
function Admin.onPlayerDisconnect(player)
    if not DS.isLoaded() then return end

    local steamID = tostring(player:getSteamID())
    local record  = DS.getRecord(steamID)
    if record then
        record.lastSeen = os.time()
        DS.setRecord(steamID, record)
        DS.flushIfDirty()
    end
end

-- ============================================================
-- Execute an admin operation (called from Commands and UI router)
-- adminPlayer   = IsoPlayer performing the action
-- action        = LifeMod.ACTION_* constant
-- targetSteamID = string steam ID of the target
-- amount        = number (optional, for add/remove/set)
-- reason        = string (optional, for logging)
-- Returns: success (bool), message (string)
-- ============================================================
function Admin.executeOperation(adminPlayer, action, targetSteamID, amount, reason)
    -- Double-check server-side admin authorisation
    if not LifeMod.isAuthorised(adminPlayer) then
        return false, "Access denied: insufficient permissions."
    end

    if not DS.isLoaded() then
        return false, "DataStore not yet loaded. Try again in a moment."
    end

    local adminName = tostring(adminPlayer:getUsername())
    local record    = DS.getRecord(targetSteamID)

    if not record and action ~= LifeMod.ACTION_VIEW then
        return false, "No record found for player: " .. tostring(targetSteamID)
    end

    -- ── VIEW ─────────────────────────────────────────────────
    if action == LifeMod.ACTION_VIEW then
        if not record then
            return true, string.format("[LifeMod] No record found for SteamID=%s", targetSteamID)
        end
        return true, string.format(
            "[LifeMod] %s (SteamID=%s) | Lives: %d/%d | Eliminated: %s | Deaths: %d",
            record.username, record.steamID,
            record.lives, record.maxLives,
            tostring(record.eliminated), record.deathCount
        )
    end

    -- ── RESTORE ──────────────────────────────────────────────
    if action == LifeMod.ACTION_RESTORE then
        local prev        = record.lives
        local restoreAmt  = LifeMod.getRestoreLives()
        record.lives      = restoreAmt
        record.eliminated = false
        DS.setRecord(targetSteamID, record)
        DS.saveImmediate()
        LOG.logAdmin(adminName, "RESTORE", targetSteamID, prev, record.lives, reason)
        return true, string.format(
            "[LifeMod] %s restored. Lives set to %d. Elimination cleared.",
            record.username, record.lives
        )
    end

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
    if action == LifeMod.ACTION_ADD then
        record.lives = LifeMod.clamp(record.lives + num, LifeMod.MIN_LIVES, cap)
        -- Restore from elimination if lives go positive
        if record.lives > 0 then record.eliminated = false end

    -- ── REMOVE ───────────────────────────────────────────────
    elseif action == LifeMod.ACTION_REMOVE then
        record.lives = LifeMod.clamp(record.lives - num, LifeMod.MIN_LIVES, LifeMod.MAX_LIVES_HARD_CAP)
        if record.lives <= 0 then
            record.lives      = 0
            record.eliminated = true
        end

    -- ── SET ──────────────────────────────────────────────────
    elseif action == LifeMod.ACTION_SET then
        record.lives = LifeMod.clamp(num, LifeMod.MIN_LIVES, LifeMod.MAX_LIVES_HARD_CAP)
        if record.lives <= 0 then
            record.lives      = 0
            record.eliminated = true
        else
            record.eliminated = false
        end

    else
        return false, "Unknown action: " .. tostring(action)
    end

    DS.setRecord(targetSteamID, record)
    DS.saveImmediate()
    LOG.logAdmin(adminName, string.upper(action), targetSteamID, prev, record.lives, reason)

    -- Apply elimination side-effects if this action newly eliminated the player
    if record.eliminated and not wasElim then
        local onlinePlayer = findOnlinePlayer(targetSteamID)
        applyEliminationEffects(record, onlinePlayer)
    end

    return true, string.format(
        "[LifeMod] %s | %s | Lives: %d → %d | Eliminated: %s",
        record.username, string.upper(action), prev, record.lives, tostring(record.eliminated)
    )
end

-- ============================================================
-- Resolve a target SteamID from a player name string.
-- Searches online players first, then DataStore records.
-- Returns steamID (string) or nil.
-- ============================================================
function Admin.resolveTargetSteamID(targetName)
    -- Search online players
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername():lower() == targetName:lower() then
                return tostring(p:getSteamID())
            end
        end
    end

    -- Search DataStore records by last-known username
    for sid, rec in pairs(DS.getAllRecords()) do
        if rec.username and rec.username:lower() == targetName:lower() then
            return sid
        end
    end

    return nil
end
