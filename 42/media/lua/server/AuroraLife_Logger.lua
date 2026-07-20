-- ============================================================
-- AuroraLife_Logger.lua
-- Server-side structured logging.
-- All output goes to server console AND a flat log file.
-- Never sent to clients.
-- ============================================================

require "AuroraLife_Shared"

AuroraLife.Logger = AuroraLife.Logger or {}

local LOG = AuroraLife.LOG_TAG

-- ── Internal: write one line to console + log file ───────────
local function writeLine(line)
    -- PZ server: print() writes to console.txt and server console
    print(line)

    -- Append to our own log file for admin inspection
    local ok, err = pcall(function()
        -- getModFileRecordFileFullPath returns a path inside the save dir
        -- We use a simple approach: write via fileWrite helper if available,
        -- otherwise fall back to io.open (works on dedicated servers)
        local path = getModFileRecordFileFullPath and
            getModFileRecordFileFullPath("AuroraLife_log.txt") or
            nil

        if path then
            local f = io.open(path, "a")
            if f then
                f:write(line .. "\n")
                f:close()
            end
        end
    end)

    if not ok and err then
        print(LOG .. " [WARN] Logger file write failed: " .. tostring(err))
    end
end

-- ── Public: generic log ───────────────────────────────────────
function AuroraLife.Logger.log(category, message)
    local ts  = AuroraLife.timestamp()
    local line = string.format("%s [%s] %s | %s", LOG, category, ts, message)
    writeLine(line)
end

-- ── Public: death event ───────────────────────────────────────
-- record        = the player's DataStore record AFTER update
-- previousLives = lives count before deduction
-- cause         = string or "unknown"
function AuroraLife.Logger.logDeath(record, previousLives, cause)
    local pos = "N/A"
    if record.lastDeath then
        pos = string.format("(%d,%d,%d)",
            record.lastDeath.x or 0,
            record.lastDeath.y or 0,
            record.lastDeath.z or 0)
    end

    local msg = string.format(
        "SteamID=%s | User=%s | Lives=%d→%d | Pos=%s | Cause=%s",
        tostring(record.steamID),
        tostring(record.username),
        previousLives,
        record.lives,
        pos,
        tostring(cause or "unknown")
    )
    AuroraLife.Logger.log("DEATH", msg)
end

-- ── Public: admin action ──────────────────────────────────────
function AuroraLife.Logger.logAdmin(adminName, action, targetSteamID, prevValue, newValue, reason)
    local msg = string.format(
        "Admin=%s | Action=%s | Target=%s | Value=%s→%s | Reason=%s",
        tostring(adminName),
        tostring(action),
        tostring(targetSteamID),
        tostring(prevValue),
        tostring(newValue),
        tostring(reason or "none")
    )
    AuroraLife.Logger.log("ADMIN", msg)
end

-- ── Public: system event ─────────────────────────────────────
function AuroraLife.Logger.logSystem(message)
    AuroraLife.Logger.log("SYSTEM", message)
end

-- ── Public: warning ───────────────────────────────────────────
function AuroraLife.Logger.logWarn(message)
    AuroraLife.Logger.log("WARN", message)
end

-- ── Public: error ─────────────────────────────────────────────
function AuroraLife.Logger.logError(message)
    AuroraLife.Logger.log("ERROR", message)
end
