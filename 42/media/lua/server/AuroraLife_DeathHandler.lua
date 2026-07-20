-- ============================================================
-- AuroraLife_DeathHandler.lua
-- Server-side death processing pipeline.
-- Deducts one life per confirmed, unique death event.
-- ============================================================

require "AuroraLife_Shared"
require "AuroraLife_DataStore"
require "AuroraLife_Logger"

AuroraLife.DeathHandler = AuroraLife.DeathHandler or {}

local DH  = AuroraLife.DeathHandler
local DS  = AuroraLife.DataStore
local LOG = AuroraLife.Logger

-- ── Duplicate-death cooldown table ───────────────────────────
-- [steamID] = epoch-second of last confirmed death
local _cooldown = {}

-- ── Internal: purge expired cooldown entries ──────────────────
local function _purgeCooldowns()
    local now = os.time()
    for sid, ts in pairs(_cooldown) do
        if (now - ts) >= AuroraLife.DEATH_COOLDOWN_SECS then
            _cooldown[sid] = nil
        end
    end
end

-- ── Internal: resolve best-effort death cause ─────────────────
-- Returns a short string describing the probable cause.
-- The PZ API does not always surface a reliable kill source;
-- we do a best-effort check and fall back to "unknown".
local function _resolveCause(character)
    local ok, cause = pcall(function()
        -- Attempt to get the last hit attacker type if the API exposes it
        -- (varies by PZ build; wrapped in pcall for safety)
        local body = character:getBodyDamage()
        if body then
            local woundList = body:getBodyParts()
            -- No reliable kill-source API in base game; return generic
        end
        return "unknown"
    end)
    return (ok and cause) or "unknown"
end

-- ── Internal: apply elimination effects ──────────────────────
local function _applyElimination(player, record)
    -- Log elimination but do not kick.
    
    -- Whitelist removal (death-triggered elimination)
    local wlEnabled = AuroraLife.getSandboxCfg(
        "RemoveFromWhitelistOnElimination",
        AuroraLife.DEFAULT_REMOVE_WHITELIST_ON_ELIMINATION
    )
    if wlEnabled then
        local ok1 = pcall(function()
            if removeUserFromWhiteList then
                removeUserFromWhiteList(record.username)
            elseif removePlayerFromWhiteList then
                removePlayerFromWhiteList(record.username)
            else
                error("no API")
            end
        end)
        if ok1 then
            LOG.logSystem("DeathHandler: whitelist removal successful for " .. record.username)
        else
            LOG.logWarn("DeathHandler: whitelist removal failed for " .. record.username ..
                        ". Admin must remove manually.")
        end
    end
    -- Send private elimination notification
    local msgEnabled = AuroraLife.getSandboxCfg("EnablePrivateDeathMessage", AuroraLife.DEFAULT_PRIVATE_DEATH_MESSAGE)
    if msgEnabled then
        local msg = "You have used all of your lives and have been eliminated. Contact a server administrator for assistance."
        sendServerCommand(player, AuroraLife.MODULE, AuroraLife.CMD_ELIMINATED, { message = msg })
    end


    LOG.logWarn("DeathHandler: player eliminated — SteamID=" .. tostring(record.steamID) ..
                " | User=" .. tostring(record.username))
end

-- ============================================================
-- Public: process a confirmed player death
-- Called from both OnPlayerDeath and OnCharacterDeath hooks.
-- ============================================================
function DH.handleDeath(character)
    -- Guard: system enabled?
    if not AuroraLife.getSandboxCfg("EnableSystem", AuroraLife.DEFAULT_ENABLE_SYSTEM) then
        return
    end

    -- Guard: multiplayer only
    if not AuroraLife.isMultiplayerSession() then return end

    -- Guard: must be a player, not zombie/NPC
    if not character or not instanceof(character, "IsoPlayer") then return end

    -- Guard: DataStore must be loaded
    if not DS.isLoaded() then
        LOG.logWarn("DeathHandler: death event received before DataStore ready. Ignored.")
        return
    end

    local steamID  = tostring(character:getSteamID())
    local username = tostring(character:getUsername())

    if not steamID or steamID == "" or steamID == "0" then
        LOG.logWarn("DeathHandler: death event with invalid SteamID. Ignored. User=" .. username)
        return
    end

    -- Guard: duplicate-event cooldown
    _purgeCooldowns()
    local now = os.time()
    if _cooldown[steamID] then
        LOG.logWarn("DeathHandler: duplicate death suppressed for SteamID=" .. steamID ..
                    " (within " .. AuroraLife.DEATH_COOLDOWN_SECS .. "s cooldown).")
        return
    end
    _cooldown[steamID] = now

    -- Load or create record
    local record = DS.getRecord(steamID)
    if not record then
        record = DS.newRecord(steamID, username)
        LOG.logSystem("DeathHandler: new player enrolled — SteamID=" .. steamID .. " | User=" .. username)
    end

    -- Sync display username (may have changed; SteamID is the authority)
    record.username = username
    record.lastSeen = now

    -- Guard: already eliminated (do not double-deduct)
    if record.eliminated then
        LOG.logWarn("DeathHandler: death on eliminated player — no deduction. SteamID=" .. steamID)
        DS.setRecord(steamID, record)
        DS.saveImmediate()
        return
    end

    -- Capture state before mutation
    local previousLives = record.lives
    local cause         = _resolveCause(character)
    
    local isDragDown = false
    pcall(function()
        if character:isDeathDragDown() then isDragDown = true end
    end)
    
    if not isDragDown and SandboxVars.Zombies and SandboxVars.Zombies.DragDown then
        if character:getAttackedByZombies() then
            isDragDown = true
        end
    end

    if isDragDown then
        record.lives = 0
        cause = "drag-down"
        LOG.logSystem("DeathHandler: drag-down detected! Instantly eliminating player " .. tostring(username))
    else
        -- Deduct one life
        record.lives      = record.lives - 1
    end
    record.deathCount = record.deathCount + 1

    -- Capture last death position
    local x, y, z = 0, 0, 0
    local posOk = pcall(function()
        x = math.floor(character:getX())
        y = math.floor(character:getY())
        z = math.floor(character:getZ())
    end)
    record.lastDeath = {
        timestamp = now,
        x = x, y = y, z = z,
        cause = cause,
    }

    -- Clamp to minimum
    if record.lives < AuroraLife.MIN_LIVES then
        record.lives = AuroraLife.MIN_LIVES
    end

    -- Check elimination
    if record.lives <= 0 then
        record.eliminated = true
    end

    -- Persist immediately (death is a destructive event)
    DS.setRecord(steamID, record)
    DS.saveImmediate()

    -- Log
    LOG.logDeath(record, previousLives, cause)

    -- Notify player
    local player = character  -- IsoPlayer IS the character for players
    if record.eliminated then
        _applyElimination(player, record)
    else
        local msgEnabled = AuroraLife.getSandboxCfg("EnablePrivateDeathMessage", AuroraLife.DEFAULT_PRIVATE_DEATH_MESSAGE)
        if msgEnabled then
            local msg = string.format(
                "You have died. Remaining lives: %d/%d",
                record.lives, record.maxLives
            )
            sendServerCommand(player, AuroraLife.MODULE, AuroraLife.CMD_LIFE_UPDATE, {
                lives    = record.lives,
                maxLives = record.maxLives,
                message  = msg,
            })
        end
    end
end

-- ============================================================
-- Public: expose cooldown table for debug purposes only
-- ============================================================
function DH.getCooldownTable()
    return _cooldown
end

-- ============================================================
-- Public: manually set the cooldown (used by CMD_CONSUME_LIFE)
-- ============================================================
function DH.setCooldown(steamID)
    if steamID then
        _cooldown[tostring(steamID)] = os.time()
    end
end
