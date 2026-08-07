-- ============================================================
-- SVRPLife_Server.lua
-- Central event wiring for the server context.
-- Registers all server-side event handlers and routes
-- inbound client commands to the correct handler.
-- ============================================================

require "SVRPLife_Shared"
require "SVRPLife_DataStore"
require "SVRPLife_Logger"
require "SVRPLife_DeathHandler"
require "SVRPLife_Admin"
require "SVRPLife_Commands"

local DS   = SVRPLife.DataStore
local DH   = SVRPLife.DeathHandler
local Adm  = SVRPLife.Admin
local Cmds = SVRPLife.Commands
local LOG  = SVRPLife.Logger

SVRPLife.Server = SVRPLife.Server or {}

-- ============================================================
-- OnServerStarted — load data, write startup backup
-- ============================================================
if SVRPLife.Server.onServerStarted then Events.OnServerStarted.Remove(SVRPLife.Server.onServerStarted) end
if SVRPLife.Server.onServerStarted then
    if Events.OnGameStart then Events.OnGameStart.Remove(SVRPLife.Server.onServerStarted) end
end

SVRPLife.Server.onServerStarted = function()
    if not SVRPLife.isMultiplayerSession() then
        print(SVRPLife.LOG_TAG .. " [SYSTEM] Singleplayer detected — SVRPLife is multiplayer-only. System inactive.")
        return
    end
    LOG.logSystem("SVRPLife v" .. SVRPLife.VERSION .. " starting up.")
    DS.load()
    LOG.logSystem("SVRPLife startup complete.")
end

-- ============================================================
-- OnPlayerDeath — primary death hook (Build 42+)
-- ============================================================
if SVRPLife.Server.onPlayerDeath then Events.OnPlayerDeath.Remove(SVRPLife.Server.onPlayerDeath) end

SVRPLife.Server.onPlayerDeath = function(player)
    -- OnPlayerDeath passes the IsoPlayer object directly
    DH.handleDeath(player)
end

-- ============================================================
-- OnCharacterDeath — secondary/fallback death hook
-- The cooldown guard in DeathHandler prevents double-processing
-- if both events fire for the same player within 5 seconds.
-- ============================================================
if SVRPLife.Server.onCharacterDeath then Events.OnCharacterDeath.Remove(SVRPLife.Server.onCharacterDeath) end

SVRPLife.Server.onCharacterDeath = function(character)
    DH.handleDeath(character)
end

-- ============================================================
-- Removed OnPlayerConnect/Disconnect (Invalid events)
-- ============================================================

-- ============================================================
-- EveryTenMinutes — periodic save + backup rotation
-- ============================================================
if SVRPLife.Server.onEveryTenMinutes then Events.EveryTenMinutes.Remove(SVRPLife.Server.onEveryTenMinutes) end

SVRPLife.Server.onEveryTenMinutes = function()
    DS.periodicTick()
    DH.purgeCooldowns()
end

-- ============================================================
-- OnClientCommand — inbound requests from client UI / context menu
-- Signature: module (string), command (string), player, args (table)
-- ============================================================
if SVRPLife.Server.onClientCommand then Events.OnClientCommand.Remove(SVRPLife.Server.onClientCommand) end

SVRPLife.Server.onClientCommand = function(module, command, player, args)
    if module ~= SVRPLife.MODULE then return end

    -- Ensure DataStore is loaded (fallback for when OnServerStarted doesn't fire)
    DS.ensureLoaded()

    if command == SVRPLife.CMD_PLAYER_CONNECT then
        Adm.onPlayerConnect(player)
        return
    end

    if command == SVRPLife.CMD_REQUEST_LIVES then
        LOG.logSystem("Server: Received CMD_REQUEST_LIVES from " .. tostring(player:getUsername()))
        local username = tostring(player:getUsername())
        local record = DS.getRecord(username)
        if not record then
            LOG.logSystem("Server: Creating new record for " .. tostring(player:getUsername()))
            local defaultLives = SVRPLife.getSandboxCfg("StartingLives", SVRPLife.DEFAULT_STARTING_LIVES)
            record = {
                username = player:getUsername(),
                lives = defaultLives,
                maxLives = defaultLives,
                eliminated = false,
                lastDeath = 0,
                deathCount = 0
            }
            DS.setRecord(username, record)
            DS.saveDeferred()
        end
        
        local defaultLives = SVRPLife.getSandboxCfg("StartingLives", SVRPLife.DEFAULT_STARTING_LIVES)
        local livesToSend = record.lives
        if livesToSend == nil then
            livesToSend = defaultLives
            record.lives = defaultLives
            DS.saveDeferred()
            LOG.logWarn("Server: Fixed corrupted nil lives for " .. tostring(player:getUsername()))
        end
        local maxL = record.maxLives or defaultLives
        
        LOG.logSystem("Server: Sending CMD_LIFE_UPDATE to " .. tostring(player:getUsername()) .. " with lives=" .. tostring(livesToSend))
        sendServerCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LIFE_UPDATE, {
            lives = livesToSend,
            maxLives = maxL,
        })
        return
    end

    if command == SVRPLife.CMD_CONSUME_LIFE then
        local username = tostring(player:getUsername())
        local record = DS.getRecord(username)
        if record and record.lives > 0 then
            record.lives = record.lives - 1
            record.deathCount = (record.deathCount or 0) + 1
            DS.saveDeferred()
            
            -- Prevent double-deduction if the engine also fires OnPlayerDeath
            DH.setCooldown(username)
            
            sendServerCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LIFE_UPDATE, {
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

    if command == SVRPLife.CMD_NEW_CHARACTER then
        LOG.logSystem("Server: CMD_NEW_CHARACTER received for " .. tostring(player:getUsername()))
        local username = tostring(player:getUsername())
        local record = DS.getRecord(username)
        if record then
                local defaultLives = SVRPLife.getSandboxCfg("StartingLives", SVRPLife.DEFAULT_STARTING_LIVES)
                record.lives = defaultLives
                record.maxLives = defaultLives
                record.eliminated = false
                DS.saveDeferred()
                LOG.logSystem("Server: Player " .. tostring(player:getUsername()) .. " created a new character. Lives reset to " .. defaultLives)
                
                sendServerCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LIFE_UPDATE, {
                    lives = record.lives,
                    maxLives = record.maxLives,
                })
            end
        return
    end

    if command == SVRPLife.CMD_SET_GODMODE then
        local enable = args.enable
        if player.setGodMod then player:setGodMod(enable) end
        if player.setGhostMode then player:setGhostMode(enable) end
        return
    end

    if command == SVRPLife.CMD_HEAL_PLAYER then
        local bd = player:getBodyDamage()
        if bd then
            if bd.RestoreToFullHealth then bd:RestoreToFullHealth() end
            if bd.setOverallBodyHealth then bd:setOverallBodyHealth(100) end
        end
        if player.setHealth then player:setHealth(1.0) end
        return
    end

    if command == SVRPLife.CMD_LOG_EVENT then
        local msg = args.message
        if msg then LOG.logSystem("ClientEvent [" .. tostring(player:getUsername()) .. "]: " .. tostring(msg)) end
        return
    end

    -- All other inbound commands require admin authority — re-validated server-side
    if not SVRPLife.isAuthorised(player) then
        LOG.logWarn("Server: unauthorised OnClientCommand from " ..
                    tostring(player:getUsername()) .. " cmd=" .. tostring(command))
        return
    end

    if not DS.isLoaded() then
        LOG.logWarn("Server: OnClientCommand received before DataStore loaded. Dropped.")
        return
    end

    -- ── Admin view ───────────────────────────────────────────
    if command == SVRPLife.CMD_ADMIN_VIEW then
        local targetUsername = tostring(args and args.targetName or "")
        local ok, msg = Adm.executeOperation(player, SVRPLife.ACTION_VIEW, targetUsername)
        sendServerCommand(player, SVRPLife.MODULE, "admin_reply", { message = msg })

    -- ── Admin set (add / remove / set) ───────────────────────
    elseif command == SVRPLife.CMD_ADMIN_SET then
        local targetUsername = tostring(args and args.targetName or "")
        local action        = tostring(args and args.action or "")
        local amount        = args and args.amount

        -- Validate action is one of the allowed mutations
        local allowedActions = {
            [SVRPLife.ACTION_ADD]    = true,
            [SVRPLife.ACTION_REMOVE] = true,
            [SVRPLife.ACTION_SET]    = true,
        }
        if not allowedActions[action] then
            LOG.logWarn("Server: invalid action in admin_set: " .. tostring(action))
            return
        end

        local ok, msg = Adm.executeOperation(player, action, targetUsername, amount)
        sendServerCommand(player, SVRPLife.MODULE, "admin_reply", { message = msg })

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
if SVRPLife.Server.onServerCommand then Events.OnServerCommand.Remove(SVRPLife.Server.onServerCommand) end

SVRPLife.Server.onServerCommand = function(module, command, player, args)
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
if SVRPLife.Server.onPlayerSay then Events.OnPlayerSay.Remove(SVRPLife.Server.onPlayerSay) end

SVRPLife.Server.onPlayerSay = function(player, message)
    if not message then return end
    local trimmed = message:match("^%s*/(%S.*)$")  -- strip leading "/"
    if trimmed and trimmed:lower():match("^lifes") then
        Cmds.handleChatCommand(player, trimmed)
    end
end

-- ============================================================
-- Register all events
-- ============================================================
Events.OnServerStarted.Add(SVRPLife.Server.onServerStarted)
Events.OnPlayerDeath.Add(SVRPLife.Server.onPlayerDeath)
Events.OnCharacterDeath.Add(SVRPLife.Server.onCharacterDeath)
Events.EveryTenMinutes.Add(SVRPLife.Server.onEveryTenMinutes)
Events.OnClientCommand.Add(SVRPLife.Server.onClientCommand)
Events.OnServerCommand.Add(SVRPLife.Server.onServerCommand)

-- Fallback: OnGameStart fires in co-op when OnServerStarted may not
if Events.OnGameStart then
    Events.OnGameStart.Add(SVRPLife.Server.onServerStarted)
end

if Events.OnPlayerSay then
    Events.OnPlayerSay.Add(SVRPLife.Server.onPlayerSay)
end

LOG.logSystem("SVRPLife_Server.lua loaded — events registered.")
