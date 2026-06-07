local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Core/Logger.lua
-- Central logging service. Every module registers a Channel and reports
-- through it; the Logger colour-formats each line into the chat frame and
-- auto-records it in a bounded history buffer that the settings window's Log
-- page renders live. Format per line:
--
--   HagAIO  hh:mm:ss  [Module]  message
--   \accent  \faint    \modclr   \level-tinted (+ glyph for warn/error)

-- Level enum (frozen table of constant descriptors).
local LEVELS = {
    DEBUG   = { order = 10, tag = "DEBUG",   key = "textFaint", glyph = ""  },
    INFO    = { order = 20, tag = "INFO",    key = "text",      glyph = ""  },
    SUCCESS = { order = 25, tag = "OK",      key = "green",     glyph = "+" },
    WARN    = { order = 30, tag = "WARN",    key = "amber",     glyph = "!" },
    ERROR   = { order = 40, tag = "ERROR",   key = "red",       glyph = "x" },
}
ns.LogLevel = LEVELS

-- Chat-echo policy per log line (independent of level/threshold):
--   NEVER  : record to the log only -- the default for EVERY ordinary line.
--   NORMAL : also echo to chat WHEN the player's "Echo to Chat" setting is on.
--   ALWAYS : echo to chat even when "Echo to Chat" is off.
local ECHO = { NEVER = 0, NORMAL = 1, ALWAYS = 2 }
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
-- Record-only helpers (never echo to chat) -- the default for all logging.
function Channel:Debug(...)   self:_Log(LEVELS.DEBUG,   ECHO.NEVER, ...) end
function Channel:Info(...)    self:_Log(LEVELS.INFO,    ECHO.NEVER, ...) end
function Channel:Success(...) self:_Log(LEVELS.SUCCESS, ECHO.NEVER, ...) end
function Channel:Warn(...)    self:_Log(LEVELS.WARN,    ECHO.NEVER, ...) end
function Channel:Error(...)   self:_Log(LEVELS.ERROR,   ECHO.NEVER, ...) end
-- Echo to chat WHEN "Echo to Chat" is on (e.g. welcome line, quest accept/turn-in).
function Channel:EchoInfo(...)    self:_Log(LEVELS.INFO,    ECHO.NORMAL, ...) end
function Channel:EchoSuccess(...) self:_Log(LEVELS.SUCCESS, ECHO.NORMAL, ...) end
-- Echo to chat ALWAYS, even when "Echo to Chat" is off (e.g. level-up announcement).
function Channel:Announce(...)    self:_Log(LEVELS.SUCCESS, ECHO.ALWAYS, ...) end

ns.LogChannel = Channel

-- ---- Logger: the singleton service ----------------------------------------
local Logger = Class.new("Logger")

local PREFIX = "|cff" .. Theme.hex.accent .. "HagAIO|r"

function Logger:Initialize()
    local p = self:_p()
    p.channels = {}   -- name -> Channel
    -- Bounded history as a head/tail-indexed buffer: live entries occupy
    -- history[start..last]. Eviction advances `start` (O(1)) instead of shifting the
    -- whole array down (table.remove(h,1) was O(n) on EVERY log line once full).
    p.history = {}
    p.start = 1       -- index of the oldest live entry
    p.last = 0        -- index of the newest live entry (0 = empty)
    p.minLevel = LEVELS.INFO.order
    p.echo = true
    p.keep = 500
    p.frame = DEFAULT_CHAT_FRAME
    p.db = nil
end

-- Pull persisted prefs once SavedVariables are available.
function Logger:LoadSettings()
    local db = ns.SavedVars:Namespace("logger", {
        minLevel = LEVELS.INFO.order,
        echo = true,
        keep = 500,
    })
    local p = self:_p()
    p.db = db
    p.minLevel = db.minLevel
    p.echo = db.echo
    p.keep = db.keep
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
    if p.db then p.db.echo = p.echo end
end
function Logger:GetEcho() return self:_p().echo end

function Logger:SetMinLevel(order)
    local p = self:_p()
    p.minLevel = order
    if p.db then p.db.minLevel = order end
end
function Logger:GetMinLevel() return self:_p().minLevel end

-- A fresh array of the live entries, oldest -> newest (the storage itself is
-- head/tail-indexed and may carry niled-out slots, so never expose it directly).
function Logger:GetHistory()
    local p = self:_p()
    local h, out, j = p.history, {}, 0
    for i = p.start, p.last do j = j + 1; out[j] = h[i] end
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

-- The core entry point: record (always) + echo (per the line's echo policy) +
-- notify any live view. `echo` defaults to NEVER, so a line only reaches chat if it
-- explicitly opts in (NORMAL, gated by the "Echo to Chat" setting + level threshold)
-- or forces it (ALWAYS).
function Logger:Record(channel, level, text, echo)
    local p = self:_p()
    local entry = {
        time     = date("%H:%M:%S"),
        module   = channel:GetName(),
        hex      = channel:GetHex(),
        level    = level.tag,
        order    = level.order,
        levelHex = Theme.hex[level.key] or Theme.hex.text,
        glyph    = level.glyph,
        text     = text,
    }
    entry.line = formatLine(entry)

    local h = p.history
    p.last = p.last + 1
    h[p.last] = entry
    if (p.last - p.start + 1) > p.keep then
        h[p.start] = nil          -- release the oldest for GC; advance the head (O(1))
        p.start = p.start + 1
        if (p.start - 1) >= p.keep then  -- dead prefix (length start-1) reached keep: compact (amortised O(1))
            local compact, j = {}, 0
            for i = p.start, p.last do j = j + 1; compact[j] = h[i] end
            p.history = compact
            p.start, p.last = 1, j
        end
    end

    echo = echo or ECHO.NEVER
    local doEcho = (echo == ECHO.ALWAYS)
        or (echo == ECHO.NORMAL and p.echo and level.order >= p.minLevel)
    if doEcho then
        p.frame:AddMessage(entry.line)
    end

    if ns.EventBus then
        ns.EventBus:Emit("LOG_ADDED", entry)
    end
    return entry
end

-- Logging is core functionality (not a Service): instantiate the singleton at
-- load so every Service/Module can register a channel as soon as it starts.
ns.Logger = Logger:New()
