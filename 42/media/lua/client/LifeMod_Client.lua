-- ============================================================
-- LifeMod_Client.lua
-- Client-side receiver for server notifications.
-- ONLY displays messages to the local player.
-- Cannot modify lives, elimination status, or any game state.
-- ============================================================

require "LifeMod_Shared"

LifeMod.Client = LifeMod.Client or {}

-- ── Internal: display a message to the local player ──────────
-- Uses the game's modal message system so it cannot be missed.
local function showMessage(text)
    -- HaloTextHelper or MsgBox may not exist on all PZ versions.
    -- We try multiple approaches, most reliable first.

    -- 1. addLineInChat: appears in the chat panel (always available)
    local ok1 = pcall(function()
        addLineInChat("[LifeMod] " .. text, 1, 1, 0.2, 0.8, 0.2, 1)
        --             text, playerIndex, r, g, b, a  (green tint)
    end)

    if not ok1 then
        -- 2. Fallback: generic modal info box
        pcall(function()
            local modal = ISModalDialog:new(
                getCore():getScreenWidth()  / 2 - 150,
                getCore():getScreenHeight() / 2 - 75,
                300, 150,
                "[LifeMod]\n" .. text,
                false, nil, nil
            )
            modal:initialise()
            modal:addToUIManager()
        end)
    end
end

-- ── Internal: display an elimination message ──────────────────
-- Presented more prominently than a regular notification.
local function showEliminationMessage(text)
    -- Attempt a red-tinted chat message first
    local ok = pcall(function()
        addLineInChat("[LifeMod] " .. text, 1, 1, 0.15, 0.15, 1)
    end)

    if not ok then
        pcall(function()
            local modal = ISModalDialog:new(
                getCore():getScreenWidth()  / 2 - 175,
                getCore():getScreenHeight() / 2 - 100,
                350, 200,
                "[LifeMod — ELIMINATED]\n" .. text,
                false, nil, nil
            )
            modal:initialise()
            modal:addToUIManager()
        end)
    end
end

-- ============================================================
-- OnServerCommand — receive messages sent by the server
-- Only handles LifeMod module commands.
-- ============================================================
local function onServerCommand(module, command, args)
    if module ~= LifeMod.MODULE then return end

    -- ── Life update notification ──────────────────────────────
    if command == LifeMod.CMD_LIFE_UPDATE then
        local msg = args and args.message
        if msg then
            showMessage(msg)
        end

    -- ── Elimination notification ──────────────────────────────
    elseif command == LifeMod.CMD_ELIMINATED then
        local msg = (args and args.message) or
                    "You have been eliminated. Contact a server administrator."
        showEliminationMessage(msg)

    -- ── Admin reply (private command feedback) ────────────────
    elseif command == "admin_reply" then
        local msg = args and args.message
        if msg then
            -- Split multi-line messages and print each line separately
            for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
                if line ~= "" then
                    addLineInChat(line, 1, 1, 0.9, 0.6, 0.1, 1)
                    --                         orange tint for admin messages
                end
            end
        end
    end
end

-- ============================================================
-- Register event
-- ============================================================
Events.OnServerCommand.Add(onServerCommand)
