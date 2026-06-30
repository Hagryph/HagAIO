local S = dofile("Test/support.lua")

-- A real Logger (it self-instantiates at file load) with date + a capturing chat frame stubbed, so we
-- can assert exactly which lines reach chat.
local function setup()
    _G.date = function() return "00:00:00" end
    local chat = {}
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) chat[#chat + 1] = msg end }
    local ns = S.newNs()
    ns.EventBus = nil                       -- Record guards on this; keep it absent
    S.load(ns, "Core/Logger.lua")           -- sets ns.Logger = Logger:New()
    return ns.Logger, chat
end

describe("Logger debug flag", function()
    it("outputs nothing at all when off -- not even to the log (never log-only)", function()
        local log, chat = setup()
        log:Core():Debug("hi")
        assert.are.equal(0, #chat)
        assert.are.equal(0, #log:GetHistory())
    end)
    it("posts DEBUG to chat when on", function()
        local log, chat = setup()
        log:SetDebug(true)
        assert.is_true(log:GetDebug())
        log:Core():Debug("hi")
        assert.are.equal(1, #chat)
    end)
    it("posts DEBUG to chat when on even if 'Echo to Chat' is off", function()
        local log, chat = setup()
        log:SetEcho(false)
        log:SetDebug(true)
        log:Core():Debug("hi")
        assert.are.equal(1, #chat)        -- ALWAYS, independent of the echo setting
    end)
    it("the debug flag does not surface other record-only lines (INFO stays silent)", function()
        local log, chat = setup()
        log:SetDebug(true)
        log:Core():Info("info")
        assert.are.equal(0, #chat)
    end)
    it("turning the debug flag back off silences DEBUG again", function()
        local log, chat = setup()
        log:SetDebug(true);  log:Core():Debug("a")
        log:SetDebug(false); log:Core():Debug("b")
        assert.are.equal(1, #chat)          -- only the first, while it was on
    end)
end)

local function ns_LogLevel()
    -- The level enum the Logger publishes (ns.LogLevel) -- used to pick threshold orders by name.
    local ns = S.newNs()
    S.load(ns, "Core/Logger.lua")
    return ns.LogLevel
end

describe("Logger chat echo policy (Warn/Error/EchoInfo vs the *Always / Announce bypass)", function()
    it("Warn/Error reach chat at NORMAL echo only while 'Echo to Chat' is on", function()
        local log, chat = setup()         -- echo defaults to ON
        assert.is_true(log:GetEcho())
        log:Core():Warn("w")
        log:Core():Error("e")
        assert.are.equal(2, #chat)        -- both NORMAL lines surfaced
    end)
    it("Warn/Error stay log-only (silent in chat) when 'Echo to Chat' is off", function()
        local log, chat = setup()
        log:SetEcho(false)
        log:Core():Warn("w")
        log:Core():Error("e")
        assert.are.equal(0, #chat)        -- NORMAL is gated off...
        assert.are.equal(2, #log:GetHistory())   -- ...but still recorded
    end)
    it("WarnAlways/ErrorAlways BYPASS the pref -- they reach chat even with echo off", function()
        local log, chat = setup()
        log:SetEcho(false)
        log:Core():WarnAlways("w")
        log:Core():ErrorAlways("e")
        assert.are.equal(2, #chat)        -- ALWAYS ignores the "Echo to Chat" setting
    end)
    it("EchoInfo/EchoSuccess follow the pref; Announce bypasses it", function()
        local log, chat = setup()
        log:SetEcho(false)
        log:Core():EchoInfo("i")          -- NORMAL: gated off
        log:Core():EchoSuccess("s")       -- NORMAL: gated off
        assert.are.equal(0, #chat)
        log:Core():Announce("a")          -- ALWAYS: through even with echo off
        assert.are.equal(1, #chat)
    end)
    it("plain Info/Success never echo, even with echo on (record-only)", function()
        local log, chat = setup()         -- echo on by default
        log:Core():Info("i")
        log:Core():Success("s")
        assert.are.equal(0, #chat)        -- NEVER policy: log only
        assert.are.equal(2, #log:GetHistory())
    end)
    it("NORMAL echo is also gated by the min-level threshold", function()
        local log, chat = setup()         -- echo on, default min level = INFO (20)
        log:SetMinLevel(ns_LogLevel().WARN.order)   -- raise threshold above INFO
        log:Core():EchoInfo("i")          -- INFO (20) < WARN (30): below threshold
        assert.are.equal(0, #chat)
        log:Core():Warn("w")              -- WARN meets the threshold
        assert.are.equal(1, #chat)
    end)
end)

-- A DB-backed Logger so SetEcho / SetMinLevel can be asserted to PERSIST. Mirrors
-- versioning_spec's rig: load the DB engine, wire an inline `logger` table through a
-- DatabaseManager stub (the singleton row id = 1 that the Logger upserts into).
local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

local function setupDB()
    _G.date = function() return "00:00:00" end
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
    local ns = S.newNs()
    ns.EventBus = nil
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local schema = ns.DB.Schema.new("L", { tables = {
        logger = { scope = "global", columns = {
            { name = "id",        type = "integer", primaryKey = true },
            { name = "min_level", type = "integer" },
            { name = "echo",      type = "boolean" },
        } },
    } })
    local db = ns.DB.Database:New("L", schema, {})
    ns.DatabaseManager = { Shared = function() return db end, Contribute = function() end }
    S.load(ns, "Core/Logger.lua")           -- sets ns.Logger = Logger:New()
    return ns.Logger, db
end

-- The single logger prefs row (id = 1), or nil before any SetEcho/SetMinLevel has written it.
local function prefRow(db)
    return db:Select("min_level", "echo"):From("logger"):Where("id", "=", 1):Limit(1):Run()[1]
end

describe("Logger SetEcho / SetMinLevel persistence", function()
    it("SetEcho changes filtering AND persists the logger row", function()
        local log, db = setupDB()
        log:SetEcho(false)
        assert.is_false(log:GetEcho())              -- runtime state flipped
        local r = prefRow(db)
        assert(r ~= nil)                            -- a row was upserted
        assert.is_false(r.echo)                     -- ...with the persisted echo = false
        log:SetEcho(true)
        assert.is_true(prefRow(db).echo)            -- a second SetEcho updates the same row
    end)
    it("SetMinLevel changes filtering AND persists the logger row", function()
        local log, db = setupDB()
        local warnOrder = ns_LogLevel().WARN.order
        log:SetMinLevel(warnOrder)
        assert.are.equal(warnOrder, log:GetMinLevel())   -- runtime threshold raised
        local r = prefRow(db)
        assert(r ~= nil)
        assert.are.equal(warnOrder, r.min_level)         -- ...and persisted
    end)
    it("LoadSettings restores a persisted min_level into the runtime threshold", function()
        local log, db = setupDB()
        local warnOrder = ns_LogLevel().WARN.order
        log:SetMinLevel(warnOrder)
        local p = log:_p(); p.minLevel = 0           -- clobber the in-memory state...
        log:LoadSettings()                           -- ...then reload from the persisted row
        assert.are.equal(warnOrder, log:GetMinLevel())
    end)
    it("LoadSettings defaults a never-persisted min_level/echo (no row yet)", function()
        local log = setupDB()                        -- nothing written, so _PrefRow() is nil
        local p = log:_p()
        p.minLevel, p.echo = 0, false                -- clobber to non-defaults
        log:LoadSettings()
        assert.are.equal(ns_LogLevel().INFO.order, log:GetMinLevel())   -- falls back to INFO
        assert.is_true(log:GetEcho())                                   -- and echo defaults on
    end)
end)

describe("Logger Clear + history ring buffer", function()
    it("Clear() empties the recorded history", function()
        local log = setup()
        log:Core():Info("a")
        log:Core():Info("b")
        assert.are.equal(2, #log:GetHistory())
        log:Clear()
        assert.are.equal(0, #log:GetHistory())
        log:Core():Info("c")                         -- the buffer is reusable after a clear
        assert.are.equal(1, #log:GetHistory())
    end)
    it("the ring buffer caps at KEEP (500); beyond that it stays capped", function()
        local log = setup()
        for i = 1, 600 do log:Core():Info(tostring(i)) end
        assert.are.equal(500, #log:GetHistory())     -- capped at KEEP, not 600
    end)
    it("eviction drops the OLDEST entries first (head advances, newest survive)", function()
        local log = setup()
        for i = 1, 600 do log:Core():Info(tostring(i)) end
        local h = log:GetHistory()
        assert.are.equal(500, #h)
        assert.are.equal("101", h[1].text)           -- 1..100 evicted; 101 is the oldest survivor
        assert.are.equal("600", h[#h].text)          -- newest entry retained, oldest -> newest order
    end)
    it("GetHistory(tail) returns only the last N live entries, newest at the end", function()
        local log = setup()
        for i = 1, 600 do log:Core():Info(tostring(i)) end
        local t = log:GetHistory(3)
        assert.are.equal(3, #t)
        assert.are.equal("598", t[1].text)
        assert.are.equal("600", t[3].text)
    end)
end)
