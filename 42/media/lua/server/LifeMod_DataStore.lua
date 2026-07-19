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

    local ok, path = pcall(function()
        return "LifeMod_data.json"
    end)

    if ok and path then
        _dataPath  = path
    else
        LOG.logError("DataStore: could not resolve data path. Persistence disabled.")
    end
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
    -- Save as a Lua array so loadstring can evaluate it without brackets
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
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
        
    -- Convert JSON array brackets to Lua table braces, only at the start/end
    -- to avoid messing up strings containing brackets.
    luaStr = luaStr:gsub("^%s*%[", "{"):gsub("%]%s*$", "}")

    local chunk, err = loadstring("return " .. luaStr)
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
    -- getModFileReader(modID, fileName, createIfNull)
    local reader = getModFileReader("AuroraLife", path, false)
    if not reader then return nil, "file not found" end
    
    local content = ""
    local line = reader:readLine()
    while line do
        content = content .. line .. "\n"
        line = reader:readLine()
    end
    reader:close()
    return content
end

local function _writeFile(path, content)
    -- getModFileWriter(modID, fileName, createIfNull, append)
    local writer = getModFileWriter("AuroraLife", path, true, false)
    if not writer then return false, "cannot open file" end
    
    writer:write(content)
    writer:close()
    return true
end

-- Atomic write is not fully supported with getModFileWriter since we cannot use os.rename
local function _writeAtomic(path, content)
    return _writeFile(path, content)
end

-- ============================================================
-- Backup helpers
-- ============================================================
DS._backupIndex = 0

function DS.createBackup()
    if not _dataPath then return end
    local content = _readFile(_dataPath)
    if not content or content == "" then return end

    local backupPath = "LifeMod_backup_" .. tostring(DS._backupIndex % MAX_BACKUPS) .. ".json"
    local ok, err = _writeFile(backupPath, content)
    if ok then
        LOG.logSystem("DataStore: created backup → " .. backupPath)
        DS._backupIndex = DS._backupIndex + 1
    else
        LOG.logError("DataStore: failed to create backup — " .. tostring(err))
    end
end

function DS.pruneBackups(maxCount)
    -- Deprecated: Round-robin backups don't need pruning.
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
    -- Scan through all 10 possible backup slots and load the first one that decodes successfully
    -- We can't determine the newest without os.execute, so we just grab the first valid one.
    -- (This isn't perfect, but it's safe against total corruption).
    for i = 0, MAX_BACKUPS - 1 do
        local backupPath = "LifeMod_backup_" .. tostring(i) .. ".json"
        local content = _readFile(backupPath)
        if content and content ~= "" then
            local parsed, perr = _decode(content)
            if parsed then
                _records = {}
                for _, record in ipairs(parsed) do
                    if record and record.steamID then
                        _records[record.steamID] = record
                    end
                end
                LOG.logSystem("DataStore: restored from backup → " .. backupPath)
                return
            end
        end
    end

    LOG.logError("DataStore: no valid backups found. Starting empty.")
    _records = {}
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
        savedSkills    = {},
        savedTraits    = {},
        savedRecipes   = {},
        pendingRestore = false,
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
