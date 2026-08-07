-- ============================================================
-- SVRPLife_Client.lua
-- Client-side receiver for server notifications.
-- ONLY displays messages to the local player.
-- Cannot modify lives, elimination status, or any game state.
-- ============================================================

require "SVRPLife_Shared"
require "ISUI/ISCharacterScreen"

SVRPLife.Client = SVRPLife.Client or {}

-- ── Store local player life data ───────────────────────────────
SVRPLife.Client.lives = nil
SVRPLife.Client.maxLives = nil

local function printToChat(text, r, g, b)
    -- Display a halo note over the player's head instead of writing to the chat box.
    -- We must avoid ISChat.addLineInChat because it causes critical conflicts with 
    -- other chat mods (like SVRP Chat) which expect strict Java ChatMessage objects.
    if getPlayer() then
        -- Increased duration from 350 to 500 for better visibility
        getPlayer():setHaloNote(text, (r or 1)*255, (g or 1)*255, (b or 1)*255, 500)
    end
end

local function showMessage(text)
    -- Bright yellow for normal messages to make them easier to see
    printToChat(text, 1.0, 0.85, 0.0)
end

local function showEliminationMessage(text)
    -- Bright red for elimination messages
    printToChat(text, 1.0, 0.15, 0.15)
end

-- Helper to safely call Java methods without spamming console errors if they don't exist
local function safeCall(obj, method, ...)
    if obj and obj[method] then 
        local ok, err = pcall(obj[method], obj, ...)
        if not ok then
            print("[SVRPLife] safeCall error on '" .. tostring(method) .. "': " .. tostring(err))
        end
        return ok, err
    end
    return false, "method not found"
end

-- ============================================================
-- OnServerCommand — receive messages sent by the server
-- Only handles SVRPLife module commands.
-- ============================================================
if SVRPLife.Client.onServerCommand then
    Events.OnServerCommand.Remove(SVRPLife.Client.onServerCommand)
end

SVRPLife.Client.onServerCommand = function(module, command, args)
    if module ~= SVRPLife.MODULE then return end

    -- ── Life update notification ──────────────────────────────
    if command == SVRPLife.CMD_LIFE_UPDATE then
        print("[SVRPLife] Client received CMD_LIFE_UPDATE!")
        if args and args.lives then
            SVRPLife.Client.lives = args.lives
            SVRPLife.Client.maxLives = args.maxLives
            print("[SVRPLife] Client lives set to: " .. tostring(SVRPLife.Client.lives))
        end
        local msg = args and args.message
        if msg then
            showMessage(msg)
        end

    -- ── Elimination notification ──────────────────────────────
    elseif command == SVRPLife.CMD_ELIMINATED then
        local msg = (args and args.message) or
                    "You have been eliminated. Contact a server administrator."
        showEliminationMessage(msg)

    elseif command == "admin_reply" then
        local msg = args and args.message
        if msg then
            -- Split multi-line messages and print each line separately
            for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
                if line ~= "" then
                    printToChat(line, 0.9, 0.6, 0.1)
                end
            end
        end
    end
end

Events.OnServerCommand.Add(SVRPLife.Client.onServerCommand)

-- ============================================================
-- OnCreatePlayer — Notify server that we've connected
-- ============================================================
if SVRPLife.Client.onCreatePlayer then
    Events.OnCreatePlayer.Remove(SVRPLife.Client.onCreatePlayer)
end

SVRPLife.Client.onCreatePlayer = function(playerIndex)
    local player = getSpecificPlayer(playerIndex) or getPlayer()
    if player and player:isLocalPlayer() then
        -- Send initialization command to the server so it knows we connected
        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_PLAYER_CONNECT, {})
    end
end
Events.OnCreatePlayer.Add(SVRPLife.Client.onCreatePlayer)

-- ============================================================
-- True Resurrection: Intercept Death
-- ============================================================
SVRPLife.Client.safetyNetEndTime = 0
SVRPLife.Client.lastHealthCheckTime = 0
SVRPLife.Client.lastSafetyNetWarning = 0
SVRPLife.Client.lastSafetyNetWarning = 0

if SVRPLife.Client.checkPlayerHealth then
    Events.OnPlayerUpdate.Remove(SVRPLife.Client.checkPlayerHealth)
end

SVRPLife.Client.checkPlayerHealth = function(player)
    if not player or not player:isLocalPlayer() then return end
    
    local currentTime = os.time()

    -- ── 1. Safety Net Timer ──
    if SVRPLife.Client.safetyNetEndTime > 0 then
        if currentTime > SVRPLife.Client.safetyNetEndTime then
            SVRPLife.Client.safetyNetEndTime = 0
            player:setGodMod(false)
            player:setGhostMode(false)
            sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_SET_GODMODE, { enable = false })
            
            -- Adrenaline Knockback on expiration to give them space when God Mode drops
            local ok, err = pcall(function()
                local cell = player:getCell()
                if cell then
                    local zList = cell:getZombieList()
                    if zList then
                        local pushed = 0
                        for i=0, zList:size()-1 do
                            local zombie = zList:get(i)
                            if zombie and zombie:DistTo(player) < 2.5 then
                                -- Clear targets so they stop eating
                                zombie:setEatBodyTarget(nil, false)
                                zombie:setTarget(nil)
                                
                                -- Standard knockback
                                zombie:setStaggerBack(true)
                                zombie:setKnockedDown(true)
                                
                                -- Crawlers often ignore setKnockedDown because they are already down.
                                -- Force a state change to interrupt their attack animation.
                                if zombie.isCrawling and zombie:isCrawling() then
                                    zombie:setHitReaction("Stagger")
                                    zombie:setVariable("HitReaction", "Stagger")
                                end
                                
                                pushed = pushed + 1
                            end
                        end
                        if pushed > 0 then
                            sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LOG_EVENT, { message = "Knocked back " .. pushed .. " zombies upon safety net expiration." })
                        end
                    end
                end
            end)
            if not ok then
                print("[SVRPLife] Knockback error: " .. tostring(err))
            end
            
            showMessage("Your safety net has expired. Be careful!")
        else
            local remaining = SVRPLife.Client.safetyNetEndTime - currentTime
            if remaining <= 10 and currentTime > SVRPLife.Client.lastSafetyNetWarning then
                SVRPLife.Client.lastSafetyNetWarning = currentTime
                showMessage("Safety net expires in " .. string.format("%.2f", remaining) .. " seconds!")
            end
            
            -- Aggressively force state continuously to prevent engine death sequences
            local bd = player:getBodyDamage()
            if not bd then return end
            
            -- Continuously clear every single injury type from every body part
            for i=0, bd:getBodyParts():size()-1 do
                local bp = bd:getBodyParts():get(i)
                safeCall(bp, "RestoreToFullHealth")
                safeCall(bp, "SetBitten", false)
                safeCall(bp, "SetInfected", false)
                safeCall(bp, "SetFakeInfected", false)
                safeCall(bp, "setBleedingTime", 0)
                safeCall(bp, "setDeepWounded", false)
                safeCall(bp, "setDeepWoundTime", 0)
                safeCall(bp, "setScratched", false, true)
                safeCall(bp, "setScratchTime", 0)
                safeCall(bp, "setCut", false)
                safeCall(bp, "setCutTime", 0)
                safeCall(bp, "setBurnTime", 0)
                safeCall(bp, "setNeedBurnWash", false)
                safeCall(bp, "setHaveGlass", false)
                safeCall(bp, "setBiteTime", 0)
                safeCall(bp, "setBleeding", false)
            end
            
            safeCall(bd, "RestoreToFullHealth")
            safeCall(bd, "setOverallBodyHealth", 100)
            safeCall(player, "setHealth", 1.0)
            safeCall(player, "setGodMod", true)
            safeCall(player, "setGhostMode", true)
            
            local curTimeMs = getTimestampMs()
            if not SVRPLife.Client.lastGodModeSync or curTimeMs - SVRPLife.Client.lastGodModeSync > 1000 then
                SVRPLife.Client.lastGodModeSync = curTimeMs
                sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_SET_GODMODE, { enable = true })
                sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_HEAL_PLAYER, {})
            end
            
            if player:getModData() then player:getModData().isDead = false end
            safeCall(player, "setAttackedByZombies", false)
            safeCall(player, "setDeathDragDown", false)
            safeCall(player, "setPlayingDeathSound", false)
            safeCall(player, "clearMaxHitReaction")
            safeCall(player, "setHitReaction", "")
            
            -- Aggressively clear fatal state machine variables
            safeCall(player, "setVariable", "isDying", "false")
            safeCall(player, "setVariable", "HitReaction", "")
            safeCall(player, "setVariable", "ZombieHitReaction", "")
            safeCall(player, "setVariable", "BumpFall", "false")
            safeCall(player, "clearVariable", "HitReaction")
            safeCall(player, "clearVariable", "BumpFall")
            
            safeCall(player, "setActionContextState", "idle")
            return
        end
    end

    -- Throttle check to avoid excessive processing (check 10x a second)
    local curTimeMs = getTimestampMs()
    if curTimeMs - SVRPLife.Client.lastHealthCheckTime < 100 then return end
    SVRPLife.Client.lastHealthCheckTime = curTimeMs
    
    -- Only monitor local player
    if player ~= getPlayer() then return end
    
    -- Initialize on first tick after 3 seconds
    if not SVRPLife.Client.hasInitialized then
        SVRPLife.Client.joinTime = SVRPLife.Client.joinTime or curTimeMs
        if curTimeMs - SVRPLife.Client.joinTime > 3000 then
            SVRPLife.Client.hasInitialized = true
            sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_REQUEST_LIVES, {})
        end
        return
    end
    
    -- If we haven't received our life count yet, abort this tick
    if SVRPLife.Client.lives == nil then return end
    
    -- Don't intercept if they are out of lives
    if SVRPLife.Client.lives <= 0 then return end

    if player:isDead() then return end

    -- ── 2. Intercept lethal damage ──
    local bodyHealth = player:getBodyDamage():getOverallBodyHealth()

    -- In a multiplayer environment, a network latency buffer is REQUIRED.
    -- If the threshold is too low (e.g. 15%), a zombie hit simulated by a remote client
    -- can instantly drop health below 0 and tell the server you died before your God Mode
    -- network packet has time to arrive. 35% provides a safe 50-100ms latency buffer.
    if bodyHealth < 35.0 then
        -- Check if it's an inescapable drag-down
        local isDragDown = false
        if player.isDeathDragDown then
            local ok, res = pcall(player.isDeathDragDown, player)
            if ok and res then isDragDown = true end
        end
        
        -- Fallback heuristic for drag-down detection if the API method is missing
        if not isDragDown and SandboxVars.Zombies and SandboxVars.Zombies.DragDown then
            if bodyHealth <= 0.0 and player:getAttackedByZombies() then
                isDragDown = true
            end
        end
        
        if isDragDown then
            -- Bypass the safety net and let the engine kill them naturally so the server can eliminate them
            return
        end
        
        -- Intercept death!
        local bd = player:getBodyDamage()
        if not bd then return end

        -- Completely heal all individual body parts and remove all infections/bleeding
        for i=0, bd:getBodyParts():size()-1 do
            local bp = bd:getBodyParts():get(i)
            safeCall(bp, "RestoreToFullHealth")
            safeCall(bp, "SetBitten", false)
            safeCall(bp, "SetInfected", false)
            safeCall(bp, "SetFakeInfected", false)
            safeCall(bp, "setBleedingTime", 0)
            safeCall(bp, "setDeepWounded", false)
            safeCall(bp, "setDeepWoundTime", 0)
            safeCall(bp, "setScratched", false, true)
            safeCall(bp, "setScratchTime", 0)
            safeCall(bp, "setCut", false)
            safeCall(bp, "setCutTime", 0)
            safeCall(bp, "setBurnTime", 0)
            safeCall(bp, "setNeedBurnWash", false)
            safeCall(bp, "setHaveGlass", false)
            safeCall(bp, "setBiteTime", 0)
            safeCall(bp, "setBleeding", false)
        end
        
        -- Cure zombie infection completely so they don't instantly drop dead from the virus
        safeCall(bd, "setInfected", false)
        safeCall(bd, "setInfectionTime", -1.0)
        safeCall(bd, "setInfectionMortalityDuration", -1.0)
        safeCall(bd, "setIsFakeInfected", false)
        
        -- Restore overall health
        safeCall(bd, "RestoreToFullHealth")
        safeCall(bd, "setOverallBodyHealth", 100)
        safeCall(player, "setHealth", 1.0)
        
        -- Aggressively clear isDead flags so they don't die during the safety net
        if player:getModData() then player:getModData().isDead = false end
        
        -- Break drag-down animation if they are being eaten and clear stunlocks
        safeCall(player, "setAttackedByZombies", false)
        safeCall(player, "setDeathDragDown", false)
        safeCall(player, "setPlayingDeathSound", false)
        safeCall(player, "clearMaxHitReaction")
        safeCall(player, "setHitReaction", "")
        
        -- Aggressively clear fatal state machine variables
        safeCall(player, "setVariable", "isDying", "false")
        safeCall(player, "setVariable", "HitReaction", "")
        safeCall(player, "setVariable", "ZombieHitReaction", "")
        safeCall(player, "setVariable", "BumpFall", "false")
        safeCall(player, "clearVariable", "HitReaction")
        safeCall(player, "clearVariable", "BumpFall")
        
        safeCall(player, "setActionContextState", "idle")
        safeCall(player, "setStaggerTime", 0)
        safeCall(player, "setEatBodyTarget", nil, false)
        
        -- Adrenaline Knockback: Stagger and knock down nearby zombies to guarantee escape
        local ok, err = pcall(function()
            local cell = player:getCell()
            if cell then
                local zList = cell:getZombieList()
                if zList then
                    local pushed = 0
                    for i=0, zList:size()-1 do
                        local zombie = zList:get(i)
                        if zombie and zombie:DistTo(player) < 2.5 then
                            -- Clear targets so they stop eating
                            zombie:setEatBodyTarget(nil, false)
                            zombie:setTarget(nil)
                            
                            -- Standard knockback
                            zombie:setStaggerBack(true)
                            zombie:setKnockedDown(true)
                            
                            -- Crawlers often ignore setKnockedDown because they are already down.
                            -- Force a state change to interrupt their attack animation.
                            if zombie.isCrawling and zombie:isCrawling() then
                                zombie:setHitReaction("Stagger")
                                zombie:setVariable("HitReaction", "Stagger")
                            end
                            
                            pushed = pushed + 1
                        end
                    end
                    if pushed > 0 then
                        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LOG_EVENT, { message = "Safety Net Triggered (Health: " .. bodyHealth .. "). Knocked back " .. pushed .. " zombies." })
                    else
                        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_LOG_EVENT, { message = "Safety Net Triggered (Health: " .. bodyHealth .. "). No zombies in immediate range." })
                    end
                end
            end
        end)
        if not ok then
            print("[SVRPLife] Safety Net Knockback error: " .. tostring(err))
        end
        
        -- Make player invulnerable and untargetable for the safety net duration (30 seconds)
        safeCall(player, "setGodMod", true)
        safeCall(player, "setGhostMode", true)
        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_SET_GODMODE, { enable = true })
        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_HEAL_PLAYER, {})
        SVRPLife.Client.lastGodModeSync = getTimestampMs()
        SVRPLife.Client.safetyNetEndTime = currentTime + 30
        SVRPLife.Client.lastSafetyNetWarning = 0

        showMessage("You suffered a lethal injury but a life was consumed! You are invulnerable for 30 seconds.")
        
        -- Instantly deduct a life locally to prevent double-triggering before server responds
        SVRPLife.Client.lives = SVRPLife.Client.lives - 1
        
        -- Tell server to deduct a life
        sendClientCommand(player, SVRPLife.MODULE, SVRPLife.CMD_CONSUME_LIFE, {})
    end
end
Events.OnPlayerUpdate.Add(SVRPLife.Client.checkPlayerHealth)

-- ============================================================
-- UI Hook: Draw Lives on Character Info Screen
-- ============================================================
if SVRPLife.Client.initializeUIHooks then
    Events.OnGameStart.Remove(SVRPLife.Client.initializeUIHooks)
end

SVRPLife.Client.initializeUIHooks = function()
    if not ISCharacterScreen then return end
    if ISCharacterScreen.SVRPLifeHooked then return end
    ISCharacterScreen.SVRPLifeHooked = true

    local original_ISCharacterScreen_render = ISCharacterScreen.render
    function ISCharacterScreen:render()
        -- Always call original first to ensure vanilla UI draws correctly
        if original_ISCharacterScreen_render then
            original_ISCharacterScreen_render(self)
        end

        -- Only draw if we are rendering the local player's info tab
        if self.char and self.char == getPlayer() then
            local lives = SVRPLife.Client.lives
            local maxLives = SVRPLife.Client.maxLives

            if lives ~= nil and maxLives ~= nil then
                -- Calculate X coordinate dynamically to match vanilla layout
                local textWid1 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Favourite_Weapon") or "Favourite Weapon")
                local textWid2 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Zombies_Killed") or "Zombies Killed")
                local textWid3 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Survived_For") or "Survived For")
                local x = 20 + math.max(textWid1, math.max(textWid2, textWid3))

                -- Calculate the exact Z coordinate where vanilla finished drawing.
                -- Vanilla's render() ends by setting the parent height to the bottom of the last drawn element + 10.
                -- Using self:getHeight() - 10 ensures we draw safely below all vanilla stats and other mods.
                local z = self:getHeight() - 10
                local BUTTON_HGT = math.max(25, getTextManager():getFontHeight(UIFont.Small) + 3 * 2)
                
                -- Draw the SVRPLife counter precisely underneath the last drawn vanilla stat
                self:drawTextRight("Lives Remaining", x, z, 1, 1, 1, 1, UIFont.Small)
                
                -- Color code the lives text: Green if plenty, Orange if low, Red if 0
                local r, g, b = 0.2, 0.8, 0.2
                if lives == 0 then
                    r, g, b = 1.0, 0.2, 0.2
                elseif lives <= 2 then
                    r, g, b = 0.8, 0.5, 0.1
                end
                
                self:drawText(tostring(lives) .. " / " .. tostring(maxLives), x + 10, z, r, g, b, 1.0, UIFont.Small)
                
                -- Push the window height down so it doesn't clip our new text
                self:setHeightAndParentHeight(self:getHeight() + BUTTON_HGT)
            end
        end
    end
end

Events.OnGameStart.Add(SVRPLife.Client.initializeUIHooks)
