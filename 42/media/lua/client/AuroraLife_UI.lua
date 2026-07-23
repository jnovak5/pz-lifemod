-- ============================================================
-- AuroraLife_UI.lua
-- Client-side admin context menu.
-- Visible ONLY to players with admin/moderator access.
-- All sensitive operations are validated server-side.
-- ============================================================

require "AuroraLife_Shared"

AuroraLife.UI = AuroraLife.UI or {}

-- ── Internal: send an admin command to the server ─────────────
local function sendAdminCmd(command, targetName, extraArgs)
    local args = extraArgs or {}
    args.targetName = targetName
    sendClientCommand(getPlayer(), AuroraLife.MODULE, command, args)
end

-- ── Internal: open a numeric input dialog ────────────────────
-- onConfirm(amount) is called with the parsed integer.
local function openNumericDialog(title, onConfirm)
    local screen = getCore()
    local w, h   = 300, 130
    local x      = screen:getScreenWidth()  / 2 - w / 2
    local y      = screen:getScreenHeight() / 2 - h / 2

    local dialog = nil
    dialog = ISTextBox:new(x, y, w, h, title, "", nil, function(target, button)
        if button.internal == "OK" then
            local amount = tonumber(dialog.entry:getText())
            if amount and amount > 0 then
                onConfirm(math.floor(amount))
            else
                -- Re-open with an error note if invalid
                openNumericDialog(title .. "\n(Enter a positive integer)", onConfirm)
            end
        end
    end, nil, nil)
    dialog:initialise()
    dialog:addToUIManager()
    dialog.entry:setText("")
end

-- ============================================================
-- Build the AuroraLife sub-menu for a given online target player
-- ============================================================
local function buildSubMenu(context, targetPlayer, localPlayer)
    local targetName = tostring(targetPlayer:getUsername())

    -- Create submenu — use the standard PZ context menu pattern
    local option  = context:addOption("[AuroraLife] " .. targetName)
    local subMenu = context:getNew(context)
    context:addSubMenu(option, subMenu)

    -- ── View Lives ───────────────────────────────────────────
    subMenu:addOption("View Lives", localPlayer, function()
        sendAdminCmd(AuroraLife.CMD_ADMIN_VIEW, targetName)
    end)

    -- ── Add Life ─────────────────────────────────────────────
    subMenu:addOption("Add Life (+1)", localPlayer, function()
        sendAdminCmd(AuroraLife.CMD_ADMIN_SET, targetName, {
            action = AuroraLife.ACTION_ADD,
            amount = 1,
        })
    end)

    -- ── Remove Life ──────────────────────────────────────────
    subMenu:addOption("Remove Life (-1)", localPlayer, function()
        sendAdminCmd(AuroraLife.CMD_ADMIN_SET, targetName, {
            action = AuroraLife.ACTION_REMOVE,
            amount = 1,
        })
    end)

    -- ── Set Lives (opens input dialog) ───────────────────────
    subMenu:addOption("Set Lives...", localPlayer, function()
        openNumericDialog("Set lives for " .. targetName .. ":", function(amount)
            sendAdminCmd(AuroraLife.CMD_ADMIN_SET, targetName, {
                action = AuroraLife.ACTION_SET,
                amount = amount,
            })
        end)
    end)
end

-- ============================================================
-- OnFillWorldObjectContextMenu — inject menu on right-click
-- Signature: playerIndex, context, worldObjects, test
-- ============================================================
if AuroraLife.UI.onFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Remove(AuroraLife.UI.onFillWorldObjectContextMenu)
end

AuroraLife.UI.onFillWorldObjectContextMenu = function(playerIndex, context, worldObjects, test)
    if test then return end
    if not worldObjects then return end
    local localPlayer = getSpecificPlayer(playerIndex)
    if not localPlayer then return end
    if not AuroraLife.isAuthorised(localPlayer) then return end

    -- Wrap everything in pcall so context menu errors don't break the game
    local ok, err = pcall(function()
        local square = nil
        for i = 1, #worldObjects do
            local obj = worldObjects[i]
            if obj and obj.getSquare and obj:getSquare() then
                square = obj:getSquare()
                break
            elseif obj and obj.getMovingObjects then
                square = obj
                break
            end
        end

        if square and square.getMovingObjects then
            local movingObjects = square:getMovingObjects()
            if movingObjects then
                for j = 0, movingObjects:size() - 1 do
                    local o = movingObjects:get(j)
                    if instanceof(o, "IsoPlayer") then
                        buildSubMenu(context, o, localPlayer)
                    end
                end
            end
        end
    end)

    if not ok then
        print("[AuroraLife] Context menu error: " .. tostring(err))
    end
end

-- ============================================================
-- Register event
-- ============================================================
Events.OnFillWorldObjectContextMenu.Add(AuroraLife.UI.onFillWorldObjectContextMenu)
