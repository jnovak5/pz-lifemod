-- ============================================================
-- LifeMod_UI.lua
-- Client-side admin context menu.
-- Visible ONLY to players with admin/moderator access.
-- All sensitive operations are validated server-side.
-- ============================================================

require "LifeMod_Shared"

LifeMod.UI = LifeMod.UI or {}

-- ── Internal: send an admin command to the server ─────────────
local function sendAdminCmd(command, targetSteamID, extraArgs)
    local args = extraArgs or {}
    args.targetSteamID = targetSteamID
    sendClientCommand(LifeMod.MODULE, command, args)
end

-- ── Internal: open a numeric input dialog ────────────────────
-- onConfirm(amount) is called with the parsed integer.
local function openNumericDialog(title, onConfirm)
    local screen = getCore()
    local w, h   = 300, 130
    local x      = screen:getScreenWidth()  / 2 - w / 2
    local y      = screen:getScreenHeight() / 2 - h / 2

    local dialog = ISTextBox:new(x, y, w, h, title, "", nil, function(button, self)
        if button.internal == "OK" then
            local amount = tonumber(self:getEntry():getText())
            if amount and amount > 0 then
                onConfirm(math.floor(amount))
            else
                -- Re-open with an error note if invalid
                openNumericDialog(title .. "\n(Enter a positive integer)", onConfirm)
            end
        end
    end, nil)
    dialog:initialise()
    dialog:addToUIManager()
    dialog.entry:setText("")
end

-- ============================================================
-- Build the LifeMod sub-menu for a given online target player
-- ============================================================
local function buildSubMenu(context, targetPlayer)
    local targetSteamID = tostring(targetPlayer:getSteamID())
    local targetName    = tostring(targetPlayer:getUsername())

    local subMenu = context:getNew(context)
    context:addSubMenu(context:addOption("[LifeMod] " .. targetName, nil, nil), subMenu)

    -- ── View Lives ───────────────────────────────────────────
    subMenu:addOption("View Lives", nil, function()
        sendAdminCmd(LifeMod.CMD_ADMIN_VIEW, targetSteamID)
    end)

    subMenu:addOptionSeparator()

    -- ── Add Life ─────────────────────────────────────────────
    subMenu:addOption("Add Life (+1)", nil, function()
        sendAdminCmd(LifeMod.CMD_ADMIN_SET, targetSteamID, {
            action = LifeMod.ACTION_ADD,
            amount = 1,
        })
    end)

    -- ── Remove Life ──────────────────────────────────────────
    subMenu:addOption("Remove Life (-1)", nil, function()
        sendAdminCmd(LifeMod.CMD_ADMIN_SET, targetSteamID, {
            action = LifeMod.ACTION_REMOVE,
            amount = 1,
        })
    end)

    -- ── Set Lives (opens input dialog) ───────────────────────
    subMenu:addOption("Set Lives...", nil, function()
        openNumericDialog("Set lives for " .. targetName .. ":", function(amount)
            sendAdminCmd(LifeMod.CMD_ADMIN_SET, targetSteamID, {
                action = LifeMod.ACTION_SET,
                amount = amount,
            })
        end)
    end)

    subMenu:addOptionSeparator()

    -- ── Restore Eliminated Player ─────────────────────────────
    subMenu:addOption("Restore Player (Clear Elimination)", nil, function()
        sendAdminCmd(LifeMod.CMD_ADMIN_RESTORE, targetSteamID)
    end)
end

-- ============================================================
-- OnFillWorldObjectContextMenu — inject menu on right-click
-- Signature: playerIndex, context, worldObjects, test
-- ============================================================
local function onFillWorldObjectContextMenu(playerIndex, context, worldObjects, test)
    -- Early exit: only show for admins (client-side display check)
    local localPlayer = getSpecificPlayer(playerIndex)
    if not localPlayer then return end
    if not LifeMod.isAuthorised(localPlayer) then return end

    -- Find if any world object is a player character
    for i = 1, #worldObjects do
        local obj = worldObjects[i]
        if obj and obj.isPlayer and obj:isPlayer() then
            -- Don't show the menu for the admin's own character
            if obj ~= localPlayer then
                buildSubMenu(context, obj)
            end
        end
    end
end

-- ============================================================
-- Register event
-- ============================================================
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
