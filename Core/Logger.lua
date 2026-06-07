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

function Channel:Log(level, ...)
    self:_p().logger:Record(self, level, joinArgs(...))
end
function Channel:Debug(...)   self:Log(LEVELS.DEBUG, ...)   end
function Channel:Info(...)    self:Log(LEVELS.INFO, ...)    end
function Channel:Success(...) self:Log(LEVELS.SUCCESS, ...) end
function Channel:Warn(...)    self:Log(LEVELS.WARN, ...)    end
function Channel:Error(...)   self:Log(LEVELS.ERROR, ...)   end

ns.LogChannel = Channel

-- ---- Logger: the singleton service ----------------------------------------
local Logger = Class.new("Logger")

local PREFIX = "|cff" .. Theme.hex.accent .. "HagAIO|r"

function Logger:Initialize()
    local p = self:_p()
    p.channels = {}   -- name -> Channel
    p.history = {}     -- bounded list of entries
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

function Logger:Register(name, hex)
    local p = self:_p()
    if not p.channels[name] then
        p.channels[name] = Channel:New(self, name, hex)
    end
    return p.channels[name]
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

function Logger:GetHistory() return self:_p().history end

local function formatLine(e)
    local time  = "|cff" .. Theme.hex.textFaint .. e.time .. "|r"
    local mod   = "|cff" .. e.hex .. "[" .. e.module .. "]|r"
    local glyph = (e.glyph ~= "") and ("|cff" .. e.levelHex .. e.glyph .. "|r ") or ""
    local msg   = "|cff" .. e.levelHex .. e.text .. "|r"
    return PREFIX .. "  " .. time .. "  " .. mod .. "  " .. glyph .. msg
end

-- The core entry point: record (always) + echo (when enabled & above
-- threshold) + notify any live view.
function Logger:Record(channel, level, text)
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
    h[#h + 1] = entry
    while #h > p.keep do table.remove(h, 1) end

    if p.echo and level.order >= p.minLevel then
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
