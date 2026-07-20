local addonName, ns = ...
local Class = ns.Class
local Enum = ns.Enum
local Type = ns.Type
local Theme = ns.Theme

-- Core/Logger.lua
-- Central logging service. Every module registers a Channel and reports
-- through it; the Logger colour-formats each line into the chat frame and
-- auto-records it in a bounded history buffer that the settings window's Log
-- page renders live. Format per line:
--
--   HagAIO  hh:mm:ss  [Module]  message
--   \accent  \faint    \modclr   \level-tinted (+ glyph for warn/error)

-- One level descriptor: an IMMUTABLE ns.Type value carrying its order/tag/key/glyph. Fields live in
-- :_p() and are read through the generated accessors (:Order() / :Tag() / :Key() / :Glyph()), so a
-- level can't be mutated after construction.
local LogLevelInfo = Type.new("LogLevelInfo", { "order", "tag", "key", "glyph" })

-- Level enum (frozen set of constant descriptors; a typo'd member raises instead of yielding nil).
local LEVELS = Enum.new("LogLevel", {
    DEBUG   = LogLevelInfo:New(10, "DEBUG", "textFaint", ""),
    INFO    = LogLevelInfo:New(20, "INFO",  "text",      ""),
    SUCCESS = LogLevelInfo:New(25, "OK",    "green",     "+"),
    WARN    = LogLevelInfo:New(30, "WARN",  "amber",     "!"),
    ERROR   = LogLevelInfo:New(40, "ERROR", "red",       "x"),
})
ns.LogLevel = LEVELS

-- Chat-echo policy per log line (independent of level/threshold):
--   NEVER  : record to the log only -- the default for EVERY ordinary line.
--   NORMAL : also echo to chat WHEN the player's "Echo to Chat" setting is on.
--   ALWAYS : echo to chat even when "Echo to Chat" is off.
-- Frozen enum (a typo'd member raises instead of silently yielding nil).
local ECHO = Enum.new("LogEcho", { NEVER = 0, NORMAL = 1, ALWAYS = 2 })
ns.LogEcho = ECHO

-- ---- Channel: the per-module handle returned by Logger:Register -----------
local Channel = Class.new("LogChannel")

function Channel:Initialize(logger, name, hex)
    local p = self:_p()
    p.logger = logger
    p.name = name
    p.hex = hex or Theme.hex.accent
end

function Channel:GetName() return self:_p().name end
function Channel:GetHex()  return self:_p().hex end

local function joinArgs(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

function Channel:_Log(level, echo, ...)
    self:_p().logger:Record(self, level, joinArgs(...), echo)
end
-- DEBUG is gated entirely by the Logger's debug flag (off by default; auto-on for dev chars). When
-- the flag is OFF it outputs NOTHING -- not even the log -- so a debug line is never "log only". When
-- ON it ALWAYS posts to chat (ECHO.ALWAYS), regardless of the "Echo to Chat" setting. One method, two
-- states: silent, or in chat.
function Channel:Debug(...)
    if not self:_p().logger:GetDebug() then return end
    self:_Log(LEVELS.DEBUG, ECHO.ALWAYS, ...)
end
-- Record-only helpers (never echo to chat) -- the default for ordinary info-level logging.
function Channel:Info(...)    self:_Log(LEVELS.INFO,    ECHO.NEVER, ...) end
function Channel:Success(...) self:_Log(LEVELS.SUCCESS, ECHO.NEVER, ...) end
-- Warnings and errors have TWO tiers, no record-only mode: the plain method ECHOES to chat
-- when "Echo to Chat" is on (the default), the *Always variant reaches chat even when it's off.
function Channel:Warn(...)        self:_Log(LEVELS.WARN,  ECHO.NORMAL, ...) end
function Channel:Error(...)       self:_Log(LEVELS.ERROR, ECHO.NORMAL, ...) end
function Channel:WarnAlways(...)  self:_Log(LEVELS.WARN,  ECHO.ALWAYS, ...) end
function Channel:ErrorAlways(...) self:_Log(LEVELS.ERROR, ECHO.ALWAYS, ...) end
-- Echo to chat WHEN "Echo to Chat" is on (e.g. welcome line, quest accept/turn-in).
function Channel:EchoInfo(...)    self:_Log(LEVELS.INFO,    ECHO.NORMAL, ...) end
function Channel:EchoSuccess(...) self:_Log(LEVELS.SUCCESS, ECHO.NORMAL, ...) end
-- Echo to chat ALWAYS, even when "Echo to Chat" is off (e.g. level-up announcement).
function Channel:Announce(...)    self:_Log(LEVELS.SUCCESS, ECHO.ALWAYS, ...) end

ns.LogChannel = Channel

-- ---- Logger: the singleton service ----------------------------------------
local Logger = Class.new("Logger", nil, { singleton = true })  -- one instance (ns.Logger); a stray Logger:New() raises

local PREFIX = "|cff" .. Theme.hex.accent .. "HagAIO|r"
local KEEP = 500   -- history capacity (entries). Fixed: a tunable `keep` pref existed but had
                   -- no setter or UI, so it was dead persisted state -- removed 2026-06-12.

function Logger:Initialize()
    local p = self:_p()
    p.channels = {}   -- name -> Channel
    -- Bounded history as a head/tail-indexed buffer: live entries occupy
    -- history[start..last]. Eviction advances `start` (O(1)) instead of shifting the
    -- whole array down (table.remove(h,1) was O(n) on EVERY log line once full).
    p.history = {}
    p.start = 1       -- index of the oldest live entry
    p.last = 0        -- index of the newest live entry (0 = empty)
    p.minLevel = LEVELS.INFO:Order()
    p.echo = true
    p.debug = false   -- when on, normally-silent DEBUG lines also surface to chat (dev aid; not persisted)
    p.frame = DEFAULT_CHAT_FRAME
end

-- The shared database (or nil before it's built), and the singleton logger-prefs row.
local function sharedDB() return ns.DatabaseManager and ns.DatabaseManager:Shared() or nil end

function Logger:_PrefRow()
    local db = sharedDB(); if not db then return nil end
    return db:Select("min_level", "echo"):From("logger"):Where("id", "=", 1):Limit(1):Run()[1]
end

-- Upsert the singleton logger row, merging `changes`.
function Logger:_SetPref(changes)
    local db = sharedDB(); if not db then return end
    if self:_PrefRow() then db:Update("logger", changes, function(x) return x.id == 1 end)
    else changes.id = 1; db:Insert("logger", changes) end
end

-- Pull persisted prefs from the shared database (built by the time this runs, on ADDON_LOADED).
function Logger:LoadSettings()
    local p, r = self:_p(), self:_PrefRow()
    p.minLevel = ns.DB.value(r and r.min_level, LEVELS.INFO:Order())
    p.echo     = ns.DB.value(r and r.echo, true)
end

-- Register is idempotent: the first registration of a name wins, so calling it
-- again just returns the existing channel (a re-used name never clobbers).
function Logger:Register(name, hex)
    local p = self:_p()
    if not p.channels[name] then
        p.channels[name] = Channel:New(self, name, hex)
    end
    return p.channels[name]
end

function Logger:HasChannel(name)
    return self:_p().channels[name] ~= nil
end

-- Shared channel for framework-level messages.
function Logger:Core()
    return self:Register("Core", Theme.hex.accent)
end

function Logger:SetEcho(on)
    local p = self:_p()
    p.echo = on and true or false
    self:_SetPref({ echo = p.echo })
end
function Logger:GetEcho() return self:_p().echo end

-- The debug flag gates Channel:Debug ENTIRELY: off -> debug lines output nothing; on -> they always
-- post to chat (see Channel:Debug). A session/runtime aid, deliberately NOT persisted (the logger DB
-- is account-wide, so it must not leak to other characters); auto-enabled on a dev char (Core/Init.lua).
function Logger:SetDebug(on) self:_p().debug = on and true or false end
function Logger:GetDebug()   return self:_p().debug end

function Logger:SetMinLevel(order)
    self:_p().minLevel = order
    self:_SetPref({ min_level = order })
end
function Logger:GetMinLevel() return self:_p().minLevel end

-- A fresh array of the live entries, oldest -> newest (the storage itself is head/tail-indexed and
-- may carry niled-out slots, so never expose it directly). `tail` (optional) returns only the last N
-- -- the Log view renders a fixed window, so it needn't copy the whole 500-entry history each refresh.
function Logger:GetHistory(tail)
    local p = self:_p()
    local h, out, j = p.history, {}, 0
    local first = tail and math.max(p.start, p.last - tail + 1) or p.start
    for i = first, p.last do j = j + 1; out[j] = h[i] end
    return out
end

-- Drop all recorded history (the Log page's Clear button).
function Logger:Clear()
    local p = self:_p()
    p.history = {}
    p.start = 1
    p.last = 0
end

local function formatLine(e)
    local time  = "|cff" .. Theme.hex.textFaint .. e.time .. "|r"
    local mod   = "|cff" .. e.hex .. "[" .. e.module .. "]|r"
    local glyph = (e.glyph ~= "") and ("|cff" .. e.levelHex .. e.glyph .. "|r ") or ""
    local msg   = "|cff" .. e.levelHex .. e.text .. "|r"
    return PREFIX .. "  " .. time .. "  " .. mod .. "  " .. glyph .. msg
end

-- Format + CACHE an entry's coloured display line on FIRST access (an echo, or the Log page render).
-- Public (Logger:Line) so the view pulls it lazily -- a line never echoed nor viewed is never
-- formatted, so a combat burst of debug lines skips the 8-way colour-escape concat entirely.
local function entryLine(e)
    if not e.line then e.line = formatLine(e) end
    return e.line
end
function Logger:Line(entry) return entryLine(entry) end

-- The core entry point: record (always) + echo (per the line's echo policy) +
-- notify any live view. `echo` defaults to NEVER, so a line only reaches chat if it
-- explicitly opts in (NORMAL, gated by the "Echo to Chat" setting + level threshold)
-- or forces it (ALWAYS).
function Logger:Record(channel, level, text, echo)
    local p = self:_p()
    -- FROZEN CONTRACT -- log-entry record shape.
    -- This plain table is the stable public shape returned (in an array, oldest->newest) by
    -- Logger:GetHistory(). It is deliberately a raw record, NOT an ns.Type: one value type per log
    -- line would add a per-entry allocation on this frequently-written hot path and regress the lazy-
    -- format design below. Callers (the Log view, echoers) MAY READ these fields but MUST NOT mutate
    -- them. Fields:
    --   time     (string) -- "HH:MM:SS" wall-clock stamp of when the line was recorded.
    --   module   (string) -- source channel's display name (channel:GetName()).
    --   hex      (string) -- channel colour, "rrggbb" hex (no "|cff" prefix).
    --   level    (string) -- level tag, e.g. "INFO"/"WARN"/"ERROR" (level:Tag()).
    --   order    (number) -- level severity for threshold comparisons (level:Order()).
    --   levelHex (string) -- level colour, "rrggbb" hex (no "|cff" prefix).
    --   glyph    (string) -- level glyph/icon text, "" when the level has none.
    --   text     (string) -- the raw message text.
    --   line     (string|nil) -- LAZILY populated coloured display line (see entryLine); nil until
    --                            first echo/render. Cache field, not input -- do not set it yourself.
    local entry = {
        time     = date("%H:%M:%S"),
        module   = channel:GetName(),
        hex      = channel:GetHex(),
        level    = level:Tag(),
        order    = level:Order(),
        levelHex = Theme.hex[level:Key()] or Theme.hex.text,
        glyph    = level:Glyph(),
        text     = text,
    }
    -- entry.line is formatted LAZILY via entryLine() -- only on echo or when the Log page renders it.

    local h = p.history
    p.last = p.last + 1
    h[p.last] = entry
    if (p.last - p.start + 1) > KEEP then
        h[p.start] = nil          -- release the oldest for GC; advance the head (O(1))
        p.start = p.start + 1
        if (p.start - 1) >= KEEP then  -- dead prefix (length start-1) reached capacity: compact (amortised O(1))
            local compact, j = {}, 0
            for i = p.start, p.last do j = j + 1; compact[j] = h[i] end
            p.history = compact
            p.start, p.last = 1, j
        end
    end

    echo = echo or ECHO.NEVER
    local doEcho = (echo == ECHO.ALWAYS)
        or (echo == ECHO.NORMAL and p.echo and level:Order() >= p.minLevel)
    if doEcho then
        p.frame:AddMessage(entryLine(entry))
    end

    if ns.EventBus then
        ns.EventBus:Emit("LOG_ADDED", entry)
    end
    return entry
end

-- Logging is core functionality (not a Service): instantiate the singleton at
-- load so every Service/Module can register a channel as soon as it starts.
ns.Logger = Logger:New()
