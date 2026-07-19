-- ============================================================
-- LifeMod_Server.lua
-- Central event wiring for the server context.
-- Registers all server-side event handlers and routes
-- inbound client commands to the correct handler.
-- ============================================================

require "LifeMod_Shared"
require "LifeMod_DataStore"
require "LifeMod_Logger"
require "LifeMod_DeathHandler"
require "LifeMod_Admin"
require "LifeMod_Commands"

local DS   = LifeMod.DataStore
local DH   = LifeMod.DeathHandler
local Adm  = LifeMod.Admin
local Cmds = LifeMod.Commands
local LOG  = LifeMod.Logger

-- ============================================================
-- OnServerStarted — load data, write startup backup
-- ============================================================
local function onServerStarted()
    if not LifeMod.isMultiplayerSession() then
        print(LifeMod.LOG_TAG .. " [SYSTEM] Singleplayer detected — LifeMod is multiplayer-only. System inactive.")
        return
    end
    LOG.logSystem("LifeMod v" .. LifeMod.VERSION .. " starting up.")
    DS.load()
    LOG.logSystem("LifeMod startup complete.")
end

-- ============================================================
-- OnPlayerDeath — primary death hook (Build 42+)
-- ============================================================
local function onPlayerDeath(player)
    -- OnPlayerDeath passes the IsoPlayer object directly
    DH.handleDeath(player)
end

-- ============================================================
-- OnCharacterDeath — secondary/fallback death hook
-- The cooldown guard in DeathHandler prevents double-processing
-- if both events fire for the same player within 5 seconds.
-- ============================================================
local function onCharacterDeath(character)
    DH.handleDeath(character)
end

-- ============================================================
-- Removed OnPlayerConnect/Disconnect (Invalid events)
-- ============================================================

-- ============================================================
-- EveryTenMinutes — periodic save + backup rotation
-- ============================================================
local function onEveryTenMinutes()
    DS.periodicTick()
end

-- ============================================================
-- OnClientCommand — inbound requests from client UI / context menu
-- Signature: module (string), command (string), player, args (table)
-- ============================================================
local function onClientCommand(module, command, player, args)
    if module ~= LifeMod.MODULE then return end

    if command == LifeMod.CMD_PLAYER_CONNECT then
        Adm.onPlayerConnect(player)
        return
    end

    if command == LifeMod.CMD_REQUEST_LIVES then
        LOG.logSystem("Server: Received CMD_REQUEST_LIVES from " .. tostring(player:getUsername()))
        local steamID = player:getSteamID()
        local record = DS.getRecord(steamID)
        if not record then
            LOG.logSystem("Server: Creating new record for " .. tostring(player:getUsername()))
            local defaultLives = LifeMod.getSandboxCfg("StartingLives", LifeMod.DEFAULT_STARTING_LIVES)
            record = {
                steamID = steamID,
                username = player:getUsername(),
                lives = defaultLives,
                maxLives = defaultLives,
                eliminated = false,
                lastDeath = 0,
                deathCount = 0
            }
            DS.setRecord(steamID, record)
            DS.saveDeferred()
        end
        
        local defaultLives = LifeMod.getSandboxCfg("StartingLives", LifeMod.DEFAULT_STARTING_LIVES)
        local livesToSend = record.lives
        if livesToSend == nil then
            livesToSend = defaultLives
            record.lives = defaultLives
            DS.saveDeferred()
            LOG.logWarn("Server: Fixed corrupted nil lives for " .. tostring(player:getUsername()))
        end
        local maxL = record.maxLives or defaultLives
        
        LOG.logSystem("Server: Sending CMD_LIFE_UPDATE to " .. tostring(player:getUsername()) .. " with lives=" .. tostring(livesToSend))
        sendServerCommand(player, LifeMod.MODULE, LifeMod.CMD_LIFE_UPDATE, {
            lives = livesToSend,
            maxLives = maxL,
        })
        return
    end

    if command == LifeMod.CMD_CONSUME_LIFE then
        local steamID = player:getSteamID()
        local record = DS.getRecord(steamID)
        if record and record.lives > 0 then
            record.lives = record.lives - 1
            record.deathCount = (record.deathCount or 0) + 1
            DS.saveDeferred()
            
            sendServerCommand(player, LifeMod.MODULE, LifeMod.CMD_LIFE_UPDATE, {
                lives = record.lives,
                maxLives = record.maxLives,
            })
            
            LOG.logSystem("Server: Player " .. tostring(player:getUsername()) .. " consumed a life via resurrection. Remaining: " .. tostring(record.lives))
            
            if record.lives <= 0 then
                DH.eliminatePlayer(player, record)
            end
        end
        return
    end

    -- All other inbound commands require admin authority — re-validated server-side
    if not LifeMod.isAuthorised(player) then
        LOG.logWarn("Server: unauthorised OnClientCommand from " ..
                    tostring(player:getUsername()) .. " cmd=" .. tostring(command))
        return
    end

    if not DS.isLoaded() then
        LOG.logWarn("Server: OnClientCommand received before DataStore loaded. Dropped.")
        return
    end

    -- ── Admin view ───────────────────────────────────────────
    if command == LifeMod.CMD_ADMIN_VIEW then
        local targetSteamID = tostring(args and args.targetSteamID or "")
        local ok, msg = Adm.executeOperation(player, LifeMod.ACTION_VIEW, targetSteamID)
        sendServerCommand(player, LifeMod.MODULE, "admin_reply", { message = msg })

    -- ── Admin set (add / remove / set) ───────────────────────
    elseif command == LifeMod.CMD_ADMIN_SET then
        local targetSteamID = tostring(args and args.targetSteamID or "")
        local action        = tostring(args and args.action or "")
        local amount        = args and args.amount

        -- Validate action is one of the allowed mutations
        local allowedActions = {
            [LifeMod.ACTION_ADD]    = true,
            [LifeMod.ACTION_REMOVE] = true,
            [LifeMod.ACTION_SET]    = true,
        }
        if not allowedActions[action] then
            LOG.logWarn("Server: invalid action in admin_set: " .. tostring(action))
            return
        end

        local ok, msg = Adm.executeOperation(player, action, targetSteamID, amount)
        sendServerCommand(player, LifeMod.MODULE, "admin_reply", { message = msg })

    -- ── Admin restore ─────────────────────────────────────────
    elseif command == LifeMod.CMD_ADMIN_RESTORE then
        local targetSteamID = tostring(args and args.targetSteamID or "")
        local ok, msg = Adm.executeOperation(player, LifeMod.ACTION_RESTORE, targetSteamID)
        sendServerCommand(player, LifeMod.MODULE, "admin_reply", { message = msg })

    else
        LOG.logWarn("Server: unknown client command: " .. tostring(command))
    end
end

-- ============================================================
-- OnServerCommand — server-side chat command intercept
-- PZ routes /command text through this event on the server.
-- Signature: module (string), command (string), player, args
-- NOTE: In PZ, chat-typed "/" commands may also arrive via
--       a different hook depending on the build. We handle
--       both the standard OnServerCommand path AND the
--       OnPlayerSay path as a fallback below.
-- ============================================================
local function onServerCommand(module, command, player, args)
    -- Route /lifes commands (module will be "default" or similar for chat)
    -- Some PZ versions pass the full text as the command.
    if command and command:lower():match("^lifes") then
        Cmds.handleChatCommand(player, command)
    end
end

-- ============================================================
-- OnPlayerSay — catch /lifes typed in chat
-- In some PZ builds, typed /commands arrive here rather than
-- OnServerCommand if they are not registered game commands.
-- ============================================================
local function onPlayerSay(player, message)
    if not message then return end
    local trimmed = message:match("^%s*/(%S.*)$")  -- strip leading "/"
    if trimmed and trimmed:lower():match("^lifes") then
        Cmds.handleChatCommand(player, trimmed)
    end
end

-- ============================================================
-- Register all events
-- ============================================================
Events.OnServerStarted.Add(onServerStarted)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnCharacterDeath.Add(onCharacterDeath)
Events.EveryTenMinutes.Add(onEveryTenMinutes)
Events.OnClientCommand.Add(onClientCommand)
Events.OnServerCommand.Add(onServerCommand)


LOG.logSystem("LifeMod_Server.lua loaded — events registered.")
