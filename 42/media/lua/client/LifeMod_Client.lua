-- ============================================================
-- LifeMod_Client.lua
-- Client-side receiver for server notifications.
-- ONLY displays messages to the local player.
-- Cannot modify lives, elimination status, or any game state.
-- ============================================================

require "LifeMod_Shared"
require "ISUI/ISCharacterScreen"

LifeMod.Client = LifeMod.Client or {}

-- ── Store local player life data ───────────────────────────────
LifeMod.Client.lives = nil
LifeMod.Client.maxLives = nil

local function printToChat(text, r, g, b)
    -- Display a halo note over the player's head instead of writing to the chat box.
    -- We must avoid ISChat.addLineInChat because it causes critical conflicts with 
    -- other chat mods (like Aurora Chat) which expect strict Java ChatMessage objects.
    if getPlayer() then
        getPlayer():setHaloNote(text, (r or 1)*255, (g or 1)*255, (b or 1)*255, 350)
    end
end

local function showMessage(text)
    printToChat("[LifeMod] " .. text, 0.2, 0.8, 0.2)
end

local function showEliminationMessage(text)
    printToChat("[LifeMod — ELIMINATED] " .. text, 1.0, 0.15, 0.15)
end

-- ============================================================
-- OnServerCommand — receive messages sent by the server
-- Only handles LifeMod module commands.
-- ============================================================
local function onServerCommand(module, command, args)
    if module ~= LifeMod.MODULE then return end

    -- ── Life update notification ──────────────────────────────
    if command == LifeMod.CMD_LIFE_UPDATE then
        print("[LifeMod] Client received CMD_LIFE_UPDATE!")
        if args and args.lives then
            LifeMod.Client.lives = args.lives
            LifeMod.Client.maxLives = args.maxLives
            print("[LifeMod] Client lives set to: " .. tostring(LifeMod.Client.lives))
        end
        local msg = args and args.message
        if msg then
            showMessage(msg)
        end

    -- ── Elimination notification ──────────────────────────────
    elseif command == LifeMod.CMD_ELIMINATED then
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
        sendClientCommand(player, LifeMod.MODULE, LifeMod.CMD_PLAYER_CONNECT, {})
    end
end
Events.OnCreatePlayer.Add(onCreatePlayer)

-- ============================================================
-- True Resurrection: Intercept Death
-- ============================================================
LifeMod.Client.safetyNetEndTime = 0
LifeMod.Client.lastHealthCheckTime = 0
LifeMod.Client.lastSafetyNetWarning = 0

local function checkPlayerHealth(player)
    if not player or not player:isLocalPlayer() then return end
    
    local currentTime = os.time()

    -- ── 1. Safety Net Timer ──
    if LifeMod.Client.safetyNetEndTime > 0 then
        if currentTime > LifeMod.Client.safetyNetEndTime then
            LifeMod.Client.safetyNetEndTime = 0
            player:setGodMod(false)
            showMessage("Your safety net has expired. Be careful!")
        else
            local remaining = LifeMod.Client.safetyNetEndTime - currentTime
            if remaining <= 5 and currentTime > LifeMod.Client.lastSafetyNetWarning then
                LifeMod.Client.lastSafetyNetWarning = currentTime
                showMessage("Safety net expires in " .. remaining .. " seconds!")
            end
        end
    end

    -- Throttle check to avoid excessive processing (check 10x a second)
    local curTimeMs = getTimestampMs()
    if curTimeMs - LifeMod.Client.lastHealthCheckTime < 100 then return end
    -- Only monitor local player
    if player ~= getPlayer() then return end
    
    -- If we haven't received our life count yet, request it and abort this tick
    if LifeMod.Client.lives == nil then 
        if curTimeMs - (LifeMod.Client.lastRequestTime or 0) > 1000 then
            LifeMod.Client.lastRequestTime = curTimeMs
            print("[LifeMod] checkPlayerHealth: lives is nil. Requesting lives from server...")
            sendClientCommand(player, LifeMod.MODULE, LifeMod.CMD_REQUEST_LIVES, {})
        end
        return 
    end
    
    -- Don't intercept if they are out of lives
    if LifeMod.Client.lives <= 0 then return end

    if player:isDead() then return end

    -- ── 2. Intercept lethal damage ──
    local bodyHealth = player:getBodyDamage():getOverallBodyHealth()

    -- If health drops critically low (below 40 out of 100)
    -- Increased to 40 because massive horde drag-downs or crits can instantly drop health.
    if bodyHealth < 40.0 then
        -- Intercept death!
        local bd = player:getBodyDamage()
        
        -- Completely heal all individual body parts and remove all infections/bleeding
        for i=0, bd:getBodyParts():size()-1 do
            local bp = bd:getBodyParts():get(i)
            bp:RestoreToFullHealth()
            bp:SetBitten(false)
            bp:SetInfected(false)
            bp:SetFakeInfected(false)
            bp:setBleedingTime(0)
            bp:setDeepWounded(false)
            bp:setDeepWoundTime(0)
            bp:setScratched(false, true)
            bp:setScratchTime(0)
            bp:setCut(false)
            bp:setCutTime(0)
            bp:setBurnTime(0)
            bp:setNeedBurnWash(false)
        end
        
        -- Cure zombie infection completely so they don't instantly drop dead from the virus
        bd:setInfected(false)
        bd:setInfectionTime(-1.0)
        bd:setInfectionMortalityDuration(-1.0)
        bd:setInfectionLevel(0)
        bd:setFakeInfectionLevel(0)
        bd:setIsFakeInfected(false)
        
        -- Restore overall health
        bd:RestoreToFullHealth()
        
        -- Make player invulnerable for the safety net duration (30 seconds)
        player:setGodMod(true)
        LifeMod.Client.safetyNetEndTime = currentTime + 30
        LifeMod.Client.lastSafetyNetWarning = 0
        player:getBodyDamage():setInfectionMortalityDuration(-1)
        player:getBodyDamage():setInfectionTime(-1)
        player:getBodyDamage():setInfectionLevel(0)

        showMessage("You suffered a lethal injury but a life was consumed! You are invulnerable for 30 seconds.")
        
        -- Instantly deduct a life locally to prevent double-triggering before server responds
        LifeMod.Client.lives = LifeMod.Client.lives - 1
        
        -- Tell server to deduct a life
        sendClientCommand(player, LifeMod.MODULE, LifeMod.CMD_CONSUME_LIFE, {})
    end
end

local function onPlayerJoined(playerIndex)
    local player = getSpecificPlayer(playerIndex) or getPlayer()
    -- Request lives when the player character is fully instantiated and networked
    if player and player:isLocalPlayer() then
        sendClientCommand(player, LifeMod.MODULE, LifeMod.CMD_REQUEST_LIVES, {})
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
            local lives = LifeMod.Client.lives
            local maxLives = LifeMod.Client.maxLives

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
                
                -- Draw the LifeMod counter precisely underneath the last drawn vanilla stat
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
Events.OnPlayerUpdate.Add(checkPlayerHealth)
