local addonName, ns = ...
local Class = ns.Class
local pairs = pairs

-- Services/EventBus.lua
-- Singleton pub/sub layer over a hidden driver frame. Wraps both real game
-- events (RegisterEvent) and custom in-addon messages so modules never have to
-- create their own frames or collide on OnEvent handlers.
--
-- Each event/message keeps its handlers in BOTH a token->fn map (for O(1) add/remove)
-- and a contiguous `list` array that dispatch walks with a numeric for (faster than
-- pairs over a hash, and -- because dispatch holds the list it grabbed at entry --
-- a handler that (un)subscribes mid-dispatch can't corrupt the loop or be skipped).
-- For UNIT events, OnUnit registers a dedicated RegisterUnitEvent frame so the engine
-- filters by unit BEFORE dispatch (no handler churn for irrelevant units).

local EventBus = Class.new("EventBus", ns.Service)

local function bucket(map, key)
    local e = map[key]
    if not e then e = { byToken = {}, list = {} }; map[key] = e end
    return e
end

-- Rebuild the contiguous dispatch array from the token map (called on add/remove only).
local function rebuild(e)
    local list = {}
    for _, fn in pairs(e.byToken) do list[#list + 1] = fn end
    e.list = list
end

-- Fire every handler in `e` (nil-safe). Grabs e.list once so concurrent (un)subscribe
-- -- which swaps in a NEW list -- never disturbs this pass.
local function dispatch(e, name, ...)
    if not e then return end
    local list = e.list
    for i = 1, #list do list[i](name, ...) end
end

function EventBus:OnInitialize()
    local p = self:_p()
    p.frame = CreateFrame("Frame")
    p.events = {}      -- [event]   = { byToken = {token=fn}, list = {fn,...} }
    p.messages = {}    -- [message] = { byToken = {token=fn}, list = {fn,...} }
    p.unitFrames = {}  -- [token]   = dedicated RegisterUnitEvent frame
    p.unitPool = {}    -- free unit frames, reused so enable/disable cycles don't leak
    p.nextToken = 1

    p.frame:SetScript("OnEvent", function(_, event, ...)
        dispatch(p.events[event], event, ...)
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
            self:LogWarn("ignoring unknown event:", event)
            return nil
        end
    end
    local e = bucket(p.events, event)
    local token = freshToken(p)
    e.byToken[token] = fn
    rebuild(e)
    return token
end

function EventBus:Off(event, token)
    if token == nil then return end
    local p = self:_p()
    local e = p.events[event]
    if not e then return end
    e.byToken[token] = nil
    if next(e.byToken) then
        rebuild(e)
    else
        p.events[event] = nil
        p.frame:UnregisterEvent(event)
    end
end

-- Subscribe to a real game event but ONLY for the given units (RegisterUnitEvent), so
-- the handler never fires for irrelevant units. Each call owns a dedicated frame (the
-- engine filters before dispatch); frames are pooled, so repeated subscribe/unsubscribe
-- doesn't leak them. Returns a token for OffUnit (nil if the event is unknown).
function EventBus:OnUnit(event, fn, ...)
    local p = self:_p()
    local f = table.remove(p.unitPool) or CreateFrame("Frame")
    f:UnregisterAllEvents()
    local ok = pcall(f.RegisterUnitEvent, f, event, ...)
    if not ok then
        p.unitPool[#p.unitPool + 1] = f
        self:LogWarn("ignoring unknown unit event:", event)
        return nil
    end
    f:SetScript("OnEvent", function(_, ev, ...) fn(ev, ...) end)
    local token = freshToken(p)
    p.unitFrames[token] = f
    return token
end

function EventBus:OffUnit(token)
    if token == nil then return end
    local p = self:_p()
    local f = p.unitFrames[token]
    if not f then return end
    f:UnregisterAllEvents()
    f:SetScript("OnEvent", nil)
    p.unitFrames[token] = nil
    p.unitPool[#p.unitPool + 1] = f   -- back to the pool for reuse
end

-- Subscribe to a custom in-addon message (not a game event).
function EventBus:Subscribe(message, fn)
    local p = self:_p()
    local e = bucket(p.messages, message)
    local token = freshToken(p)
    e.byToken[token] = fn
    rebuild(e)
    return token
end

-- Remove a custom-message handler by the token Subscribe returned (mirror of
-- Off for game events). Drops the message table once its last handler is gone.
function EventBus:Unsubscribe(message, token)
    if token == nil then return end
    local p = self:_p()
    local e = p.messages[message]
    if not e then return end
    e.byToken[token] = nil
    if next(e.byToken) then rebuild(e) else p.messages[message] = nil end
end

-- Broadcast a custom in-addon message.
function EventBus:Emit(message, ...)
    dispatch(self:_p().messages[message], message, ...)
end

ns.ServiceManager:Register(EventBus:New("EventBus"))
