local addonName, ns = ...

-- Core/Delegate.lua
-- A multicast DELEGATE / signal -- an object-owned event you Connect handlers to and Fire.
-- Lighter and more local than the global EventBus: reach for it when ONE object notifies its
-- own subscribers (a value changed, a window closed), rather than a named app-wide channel.
--   local changed = ns.Delegate:New()
--   local token = changed:Connect(function(v) ... end)
--   changed:Fire(42)              -- calls every connected handler, in connection order
--   changed:Disconnect(token)

local Delegate = ns.Class.new("Delegate")

function Delegate:Initialize()
    local p = self:_p()
    p.handlers = {}   -- token -> fn
    p.next = 0
end

-- Connect a handler; returns a token to Disconnect it later.
function Delegate:Connect(fn)
    assert(type(fn) == "function", "Delegate:Connect needs a function")
    local p = self:_p()
    p.next = p.next + 1
    p.handlers[p.next] = fn
    return p.next
end

function Delegate:Disconnect(token)
    self:_p().handlers[token] = nil
end

function Delegate:Clear()
    self:_p().handlers = {}
end

function Delegate:Count()
    local n = 0
    for _ in pairs(self:_p().handlers) do n = n + 1 end
    return n
end

-- Fire every connected handler with the given args, in connection (token) order. The token
-- list is snapshotted first, so a handler may safely Connect/Disconnect during the fire.
function Delegate:Fire(...)
    local handlers = self:_p().handlers
    local tokens = {}
    for t in pairs(handlers) do tokens[#tokens + 1] = t end
    table.sort(tokens)
    for _, t in ipairs(tokens) do
        local fn = handlers[t]
        if fn then fn(...) end   -- re-check: an earlier handler may have disconnected this one
    end
end

ns.Delegate = Delegate
