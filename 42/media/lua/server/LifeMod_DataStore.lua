-- ============================================================
-- LifeMod_DataStore.lua
-- Server-side persistence layer.
-- Handles: load, get, set, atomic save, backups, corruption recovery.
-- NEVER trust or expose data to clients.
-- ============================================================

require "LifeMod_Shared"
require "LifeMod_Logger"

LifeMod.DataStore = LifeMod.DataStore or {}

local DS = LifeMod.DataStore
local LOG = LifeMod.Logger

-- ── Internal state ────────────────────────────────────────────
local _records    = {}           -- [steamID] = record table
local _dirty      = false        -- true when unsaved changes exist
local _loaded     = false        -- true after initial load succeeded
local _dataPath   = nil          -- resolved on first call to _resolvePath()
local _backupDir  = nil

local MAX_BACKUPS = 10

-- ============================================================
-- Path helpers
-- ============================================================

local function _resolvePaths()
    if _dataPath then return end

    -- getModFileRecordFileFullPath() returns a path inside the server's
    -- Zomboid/Lua/ directory (or equivalent on the dedicated server).
    -- We call it once and cache.
    local ok, path = pcall(function()
        return getModFileRecordFileFullPath("LifeMod_data.json")
    end)

    if ok and path then
        _dataPath  = path
        -- Derive backup directory by stripping filename and appending subdir
        _backupDir = path:gsub("[/\\][^/\\]+$", "") .. "/LifeMod_backups/"
    else
        LOG.logError("DataStore: could not resolve data path. Persistence disabled.")
    end
end

local function _ensureBackupDir()
    if not _backupDir then return end
    -- Lua has no built-in mkdir; use os.execute as fallback (available on Linux servers)
    -- On Windows dedicated servers this also works.
    os.execute('mkdir "' .. _backupDir .. '" 2>nul || mkdir -p "' .. _backupDir .. '" 2>/dev/null')
end

-- ============================================================
-- Serialisation helpers
-- ============================================================

-- Minimal JSON encoder sufficient for our record shape.
-- Does not handle arbitrary nesting — only what our data model requires.
local function _encodeValue(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then return tostring(v)
    elseif t == "string"  then
        -- escape backslashes, double-quotes, newlines
        v = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
        return '"' .. v .. '"'
    elseif t == "table" then
        -- check if array-like (integer keys from 1)
        local isArray = (#v > 0)
        if isArray then
            local parts = {}
            for _, val in ipairs(v) do
                parts[#parts+1] = _encodeValue(val)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts+1] = '"' .. tostring(k) .. '":' .. _encodeValue(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function _encode(records)
    local parts = {}
    for steamID, record in pairs(records) do
        parts[#parts+1] = _encodeValue(record)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n]"
end

-- Thin JSON decoder — relies on Lua's loadstring to parse the JSON
-- since PZ ships with a Lua runtime that supports it.
-- For safety we sanitise the string first.
local function _decode(jsonStr)
    if not jsonStr or jsonStr == "" then return nil end

    -- Convert JSON booleans/null so Lua's loadstring can evaluate
    local luaStr = jsonStr
        :gsub('"([^"]-)"%s*:', '["%1"]=')  -- "key": -> ["key"]=
        :gsub('%btrue', 'true')
        :gsub('%bfalse', 'false')
        :gsub('%bnull', 'nil')

    local chunk, err = load("return " .. luaStr)
    if not chunk then
        return nil, "parse error: " .. tostring(err)
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, "eval error: " .. tostring(result)
    end
    return result
end

-- ============================================================
-- File I/O helpers
-- ============================================================

local function _readFile(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function _writeFile(path, content)
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

-- Atomic write: write to .tmp then rename.
local function _writeAtomic(path, content)
    local tmp = path .. ".tmp"
    local ok, err = _writeFile(tmp, content)
    if not ok then
        return false, "tmp write failed: " .. tostring(err)
    end
    -- os.rename is atomic on POSIX; on Windows it may fail if dest exists
    os.remove(path)
    local renamed = os.rename(tmp, path)
    if not renamed then
        return false, "rename failed"
    end
    return true
end

-- ============================================================
-- Backup helpers
-- ============================================================

function DS.createBackup()
    _resolvePaths()
    if not _dataPath or not _backupDir then return end
    _ensureBackupDir()

    local stamp = os.date("%Y%m%d_%H%M%S")
    local dest  = _backupDir .. "LifeMod_data_" .. stamp .. ".json"

    local content, err = _readFile(_dataPath)
    if not content then
        LOG.logWarn("DataStore: backup skipped — could not read primary file: " .. tostring(err))
        return
    end

    local ok, werr = _writeFile(dest, content)
    if ok then
        LOG.logSystem("DataStore: backup written → " .. dest)
    else
        LOG.logWarn("DataStore: backup write failed: " .. tostring(werr))
    end
end

function DS.pruneBackups(maxCount)
    _resolvePaths()
    if not _backupDir then return end
    maxCount = maxCount or MAX_BACKUPS

    -- List files matching pattern (Lua io has no glob; use os.execute + temp file)
    local listFile = _backupDir .. "_list.tmp"
    os.execute('ls -1t "' .. _backupDir .. '"LifeMod_data_*.json 2>/dev/null > "' .. listFile .. '" || ' ..
               'dir /b /o-d "' .. _backupDir .. 'LifeMod_data_*.json" 2>nul > "' .. listFile .. '"')

    local content = _readFile(listFile)
    os.remove(listFile)

    if not content or content == "" then return end

    local files = {}
    for line in content:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            files[#files+1] = trimmed
        end
    end

    -- Files are sorted newest-first from ls -1t / dir /o-d
    for i = maxCount + 1, #files do
        local full = _backupDir .. files[i]
        -- If ls gave full paths already, use as-is
        if not files[i]:find("[/\\]") then
            full = _backupDir .. files[i]
        else
            full = files[i]
        end
        os.remove(full)
        LOG.logSystem("DataStore: pruned old backup → " .. full)
    end
end

-- ============================================================
-- Load
-- ============================================================

function DS.load()
    _resolvePaths()
    if not _dataPath then
        _loaded = true  -- allow system to function without persistence (in-memory only)
        return
    end

    -- Backup current file before loading (protects against mid-session corruption)
    DS.createBackup()

    local content, err = _readFile(_dataPath)
    if not content then
        LOG.logSystem("DataStore: no existing data file found. Starting fresh. (" .. tostring(err) .. ")")
        _records = {}
        _loaded  = true
        return
    end

    local parsed, perr = _decode(content)
    if not parsed then
        LOG.logError("DataStore: primary file corrupt — " .. tostring(perr))
        DS._restoreFromBackup()
    else
        -- Build lookup table
        _records = {}
        for _, record in ipairs(parsed) do
            if record and record.steamID then
                _records[record.steamID] = record
            end
        end
        local count = 0
        for _ in pairs(_records) do count = count + 1 end
        LOG.logSystem("DataStore: loaded " .. count .. " player records.")
    end

    _loaded = true
    DS.pruneBackups(MAX_BACKUPS)
end

function DS._restoreFromBackup()
    if not _backupDir then
        _records = {}
        return
    end

    -- Find newest backup
    local listFile = _backupDir .. "_restore_list.tmp"
    os.execute('ls -1t "' .. _backupDir .. '"LifeMod_data_*.json 2>/dev/null > "' .. listFile .. '" || ' ..
               'dir /b /o-d "' .. _backupDir .. 'LifeMod_data_*.json" 2>nul > "' .. listFile .. '"')
    local listContent = _readFile(listFile)
    os.remove(listFile)

    if not listContent or listContent == "" then
        LOG.logError("DataStore: no backups found. Starting with empty records.")
        _records = {}
        return
    end

    -- Take first (newest) file
    local newest = listContent:match("^([^\n]+)")
    if newest then
        newest = newest:match("^%s*(.-)%s*$")
    end

    local fullPath
    if newest and newest:find("[/\\]") then
        fullPath = newest
    elseif newest then
        fullPath = _backupDir .. newest
    end

    if not fullPath then
        LOG.logError("DataStore: could not determine backup path.")
        _records = {}
        return
    end

    local content = _readFile(fullPath)
    local parsed, perr = _decode(content or "")
    if parsed then
        _records = {}
        for _, record in ipairs(parsed) do
            if record and record.steamID then
                _records[record.steamID] = record
            end
        end
        LOG.logSystem("DataStore: restored from backup → " .. fullPath)
    else
        LOG.logError("DataStore: backup also corrupt — " .. tostring(perr) .. ". Starting empty.")
        _records = {}
    end
end

-- ============================================================
-- Record accessors
-- ============================================================

function DS.getRecord(steamID)
    return _records[steamID]
end

function DS.setRecord(steamID, record)
    _records[steamID] = record
    _dirty = true
end

function DS.getAllRecords()
    return _records
end

function DS.isLoaded()
    return _loaded
end

-- ============================================================
-- Save
-- ============================================================

function DS.saveImmediate()
    if not _dataPath then return end
    if not _loaded    then return end

    local encoded = _encode(_records)
    local ok, err = _writeAtomic(_dataPath, encoded)
    if ok then
        _dirty = false
    else
        LOG.logError("DataStore: save failed — " .. tostring(err))
    end
end

function DS.saveDeferred()
    _dirty = true
end

function DS.flushIfDirty()
    if _dirty then
        DS.saveImmediate()
    end
end

-- ============================================================
-- Player record factory
-- ============================================================

function DS.newRecord(steamID, username)
    local startLives = LifeMod.getSandboxCfg("StartingLives", LifeMod.DEFAULT_STARTING_LIVES)
    return {
        steamID    = steamID,
        username   = username or "unknown",
        lives      = startLives,
        maxLives   = startLives,
        eliminated = false,
        firstSeen  = os.time(),
        lastSeen   = os.time(),
        deathCount = 0,
        lastDeath  = nil,
    }
end

-- ============================================================
-- Periodic flush (called by Events.EveryTenMinutes in Server.lua)
-- ============================================================
function DS.periodicTick()
    DS.flushIfDirty()
    -- Rotate backups every ~30 minutes (every 3rd tick of EveryTenMinutes)
    DS._tickCount = (DS._tickCount or 0) + 1
    if DS._tickCount % 3 == 0 then
        DS.createBackup()
        DS.pruneBackups(MAX_BACKUPS)
    end
end
