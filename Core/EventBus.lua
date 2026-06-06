local addonName, ns = ...
local Class = ns.Class

-- Core/EventBus.lua
-- Singleton pub/sub layer over a hidden driver frame. Wraps both real game
-- events (RegisterEvent) and custom in-addon messages so modules never have to
-- create their own frames or collide on OnEvent handlers.

local EventBus = Class.new("EventBus")

function EventBus:Initialize()
    local p = self:_p()
    p.frame = CreateFrame("Frame", "HagAIOEventDriver")
    p.events = {}      -- [event]   = { [token] = fn }
    p.messages = {}    -- [message] = { [token] = fn }
    p.nextToken = 1

    p.frame:SetScript("OnEvent", function(_, event, ...)
        local handlers = p.events[event]
        if not handlers then return end
        for _, fn in pairs(handlers) do
            fn(event, ...)
        end
    end)
end

local function freshToken(p)
    local token = p.nextToken
    p.nextToken = token + 1
    return token
end

-- Subscribe to a real game event. Returns an unsubscribe token (nil if the
-- event name is unknown/removed on this client).
function EventBus:On(event, fn)
    local p = self:_p()
    if not p.events[event] then
        -- RegisterEvent throws on unknown/removed events; don't let one bad
        -- event name abort the caller's whole setup.
        local ok = pcall(p.frame.RegisterEvent, p.frame, event)
        if not ok then
            ns.Log.Warn("ignoring unknown event:", event)
            return nil
        end
        p.events[event] = {}
    end
    local token = freshToken(p)
    p.events[event][token] = fn
    return token
end

function EventBus:Off(event, token)
    if token == nil then return end
    local p = self:_p()
    local handlers = p.events[event]
    if not handlers then return end
    handlers[token] = nil
    if not next(handlers) then
        p.events[event] = nil
        p.frame:UnregisterEvent(event)
    end
end

-- Subscribe to a custom in-addon message (not a game event).
function EventBus:Subscribe(message, fn)
    local p = self:_p()
    p.messages[message] = p.messages[message] or {}
    local token = freshToken(p)
    p.messages[message][token] = fn
    return token
end

-- Broadcast a custom in-addon message.
function EventBus:Emit(message, ...)
    local p = self:_p()
    local handlers = p.messages[message]
    if not handlers then return end
    for _, fn in pairs(handlers) do
        fn(message, ...)
    end
end

ns.EventBus = EventBus
