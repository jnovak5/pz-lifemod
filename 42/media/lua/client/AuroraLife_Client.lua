-- ============================================================
-- AuroraLife_Client.lua
-- Client-side receiver for server notifications.
-- ONLY displays messages to the local player.
-- Cannot modify lives, elimination status, or any game state.
-- ============================================================

require "AuroraLife_Shared"
require "ISUI/ISCharacterScreen"

AuroraLife.Client = AuroraLife.Client or {}

-- ── Store local player life data ───────────────────────────────
AuroraLife.Client.lives = nil
AuroraLife.Client.maxLives = nil

local function printToChat(text, r, g, b)
    -- Display a halo note over the player's head instead of writing to the chat box.
    -- We must avoid ISChat.addLineInChat because it causes critical conflicts with 
    -- other chat mods (like Aurora Chat) which expect strict Java ChatMessage objects.
    if getPlayer() then
        getPlayer():setHaloNote(text, (r or 1)*255, (g or 1)*255, (b or 1)*255, 350)
    end
end

local function showMessage(text)
    printToChat("[AuroraLife] " .. text, 0.2, 0.8, 0.2)
end

local function showEliminationMessage(text)
    printToChat("[AuroraLife — ELIMINATED] " .. text, 1.0, 0.15, 0.15)
end

-- ============================================================
-- OnServerCommand — receive messages sent by the server
-- Only handles AuroraLife module commands.
-- ============================================================
local function onServerCommand(module, command, args)
    if module ~= AuroraLife.MODULE then return end

    -- ── Life update notification ──────────────────────────────
    if command == AuroraLife.CMD_LIFE_UPDATE then
        print("[AuroraLife] Client received CMD_LIFE_UPDATE!")
        if args and args.lives then
            AuroraLife.Client.lives = args.lives
            AuroraLife.Client.maxLives = args.maxLives
            print("[AuroraLife] Client lives set to: " .. tostring(AuroraLife.Client.lives))
        end
        local msg = args and args.message
        if msg then
            showMessage(msg)
        end

    -- ── Elimination notification ──────────────────────────────
    elseif command == AuroraLife.CMD_ELIMINATED then
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

Events.OnServerCommand.Add(onServerCommand)

-- ============================================================
-- OnCreatePlayer — Notify server that we've connected
-- ============================================================
local function onCreatePlayer(playerIndex)
    local player = getSpecificPlayer(playerIndex) or getPlayer()
    if player and player:isLocalPlayer() then
        -- Send initialization command to the server so it knows we connected
        sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_PLAYER_CONNECT, {})
    end
end
Events.OnCreatePlayer.Add(onCreatePlayer)

-- ============================================================
-- True Resurrection: Intercept Death
-- ============================================================
AuroraLife.Client.safetyNetEndTime = 0
AuroraLife.Client.lastHealthCheckTime = 0
AuroraLife.Client.lastSafetyNetWarning = 0

local function checkPlayerHealth(player)
    if not player or not player:isLocalPlayer() then return end
    
    local currentTime = os.time()

    -- ── 1. Safety Net Timer ──
    if AuroraLife.Client.safetyNetEndTime > 0 then
        if currentTime > AuroraLife.Client.safetyNetEndTime then
            AuroraLife.Client.safetyNetEndTime = 0
            player:setGodMod(false)
            player:setGhostMode(false)
            sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_SET_GODMODE, { enable = false })
            
            -- Adrenaline Knockback on expiration to give them space when God Mode drops
            pcall(function()
                local cell = player:getCell()
                if cell then
                    local zList = cell:getZombieList()
                    if zList then
                        for i=0, zList:size()-1 do
                            local zombie = zList:get(i)
                            if zombie and zombie:DistTo(player) < 2.5 then
                                zombie:setStaggerBack(true)
                                zombie:setKnockedDown(true)
                            end
                        end
                    end
                end
            end)
            
            showMessage("Your safety net has expired. Be careful!")
        else
            local remaining = AuroraLife.Client.safetyNetEndTime - currentTime
            if remaining <= 5 and currentTime > AuroraLife.Client.lastSafetyNetWarning then
                AuroraLife.Client.lastSafetyNetWarning = currentTime
                showMessage("Safety net expires in " .. remaining .. " seconds!")
            end
            
            -- Aggressively force state continuously to prevent engine death sequences
            -- Helper to safely call Java methods without spamming console errors if they don't exist
            local function safeCall(obj, method, ...)
                if obj and obj[method] then pcall(function(...) obj[method](obj, ...) end, ...) end
            end
            
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
            if not AuroraLife.Client.lastGodModeSync or curTimeMs - AuroraLife.Client.lastGodModeSync > 1000 then
                AuroraLife.Client.lastGodModeSync = curTimeMs
                sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_SET_GODMODE, { enable = true })
                sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_HEAL_PLAYER, {})
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
    if curTimeMs - AuroraLife.Client.lastHealthCheckTime < 100 then return end
    -- Only monitor local player
    if player ~= getPlayer() then return end
    
    -- Initialize on first tick after 3 seconds
    if not AuroraLife.Client.hasInitialized then
        AuroraLife.Client.joinTime = AuroraLife.Client.joinTime or curTimeMs
        if curTimeMs - AuroraLife.Client.joinTime > 3000 then
            AuroraLife.Client.hasInitialized = true
            if not player:getModData().AuroraLife_NewCharClaimed then
                player:getModData().AuroraLife_NewCharClaimed = true
                sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_NEW_CHARACTER, {})
            end
            sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_REQUEST_LIVES, {})
        end
        return
    end
    
    -- If we haven't received our life count yet, abort this tick
    if AuroraLife.Client.lives == nil then return end
    
    -- Don't intercept if they are out of lives
    if AuroraLife.Client.lives <= 0 then return end

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
        pcall(function()
            if player:isDeathDragDown() then isDragDown = true end
        end)
        
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
        -- Helper to safely call Java methods without spamming console errors if they don't exist
        local function safeCall(obj, method, ...)
            if obj and obj[method] then pcall(function(...) obj[method](obj, ...) end, ...) end
        end

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
        safeCall(player, "setEatBodyTarget", nil, nil)
        
        -- Adrenaline Knockback: Stagger and knock down nearby zombies to guarantee escape
        pcall(function()
            local cell = player:getCell()
            if cell then
                local zList = cell:getZombieList()
                if zList then
                    for i=0, zList:size()-1 do
                        local zombie = zList:get(i)
                        if zombie and zombie:DistTo(player) < 2.5 then
                            zombie:setStaggerBack(true)
                            zombie:setKnockedDown(true)
                        end
                    end
                end
            end
        end)
        
        -- Make player invulnerable and untargetable for the safety net duration (30 seconds)
        safeCall(player, "setGodMod", true)
        safeCall(player, "setGhostMode", true)
        sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_SET_GODMODE, { enable = true })
        sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_HEAL_PLAYER, {})
        AuroraLife.Client.lastGodModeSync = getTimestampMs()
        AuroraLife.Client.safetyNetEndTime = currentTime + 30
        AuroraLife.Client.lastSafetyNetWarning = 0

        showMessage("You suffered a lethal injury but a life was consumed! You are invulnerable for 30 seconds.")
        
        -- Instantly deduct a life locally to prevent double-triggering before server responds
        AuroraLife.Client.lives = AuroraLife.Client.lives - 1
        
        -- Tell server to deduct a life
        sendClientCommand(player, AuroraLife.MODULE, AuroraLife.CMD_CONSUME_LIFE, {})
    end
end

local function onPlayerJoined(playerIndex)
    local player = getSpecificPlayer(playerIndex) or getPlayer()
    if player and player:isLocalPlayer() then
        -- Initialization is now handled in checkPlayerHealth after a 3-second delay
    end
end
Events.OnCreatePlayer.Add(onPlayerJoined)
Events.OnPlayerUpdate.Add(checkPlayerHealth)

-- ============================================================
-- UI Hook: Draw Lives on Character Info Screen
-- ============================================================
local function initializeUIHooks()
    if not ISCharacterScreen then return end

    local original_ISCharacterScreen_render = ISCharacterScreen.render
    function ISCharacterScreen:render()
        -- Always call original first to ensure vanilla UI draws correctly
        if original_ISCharacterScreen_render then
            original_ISCharacterScreen_render(self)
        end

        -- Only draw if we are rendering the local player's info tab
        if self.char and self.char == getPlayer() then
            local lives = AuroraLife.Client.lives
            local maxLives = AuroraLife.Client.maxLives

            if lives ~= nil and maxLives ~= nil then
                -- Calculate X coordinate dynamically to match vanilla layout
                local textWid1 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Favourite_Weapon") or "Favourite Weapon")
                local textWid2 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Zombies_Killed") or "Zombies Killed")
                local textWid3 = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_char_Survived_For") or "Survived For")
                local x = 20 + math.max(textWid1, math.max(textWid2, textWid3))

                -- Calculate the exact Z coordinate where vanilla finished drawing
                local z = self.literatureButton:getBottom()
                local BUTTON_HGT = math.max(25, getTextManager():getFontHeight(UIFont.Small) + 3 * 2)
                z = math.max(z + 10, self.avatarY + self.avatarHeight + 10 + 2)
                
                -- Account for Favourite Weapon
                if self.favouriteWeapon then
                    z = z + BUTTON_HGT
                end
                
                -- Account for Zombies Killed
                z = z + BUTTON_HGT
                
                -- Account for Survived For (if they have a watch)
                local clock = UIManager.getClock()
                if clock and clock:isDateVisible() then
                    z = z + BUTTON_HGT
                end
                
                -- Draw the AuroraLife counter precisely underneath the last drawn vanilla stat
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
                self:setHeightAndParentHeight(z + BUTTON_HGT + 10)
            end
        end
    end
end

Events.OnGameStart.Add(initializeUIHooks)
