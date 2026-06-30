local addonName, ns = ...
local Class = ns.Class

-- Services/Hooks.lua
-- Removable secure-hook service. WoW's `hooksecurefunc` CANNOT be undone (there is
-- no unhook), so -- like AceHook -- we install ONE permanent post-hook per target
-- that dispatches to a set of registered handlers. "Unhooking" simply drops a
-- handler from that set, so it stops being called (the inert dispatcher remains).
-- This lets a module cleanly remove its hooks on disable.
--
--   local h = ns.Hooks:Secure(frame, "OnClicked", fn, owner)   -- a method on an object
--   local h = ns.Hooks:Secure("SomeGlobalFunc", fn, owner)     -- a global function
--   h:Unhook()                 -- remove this one
--   ns.Hooks:UnhookAll(owner)  -- remove every hook an owner installed (use on disable)

local Hooks = Class.new("Hooks", ns.Service)

-- ---- HookHandle: the live handle Secure() returns -----------------------------------------
-- A small class (private state behind :_p(), a method over a raw record) -- the house style
-- (Logger -> LogChannel, Cache -> CacheStore). It knows how to drop its own handler from the
-- shared dispatcher and forget itself from its owner's set.
local HookHandle = Class.new("HookHandle")

function HookHandle:Initialize(entry, id, ownerSet)
    local p = self:_p()
    p.entry = entry        -- the dispatcher entry { handlers = { id -> fn } } this hook lives in
    p.id = id              -- our handler id within that entry
    p.ownerSet = ownerSet  -- our owner's handle-set (or nil), so Unhook can forget us
end

-- Stop this handler firing (drop it from its dispatcher). The internal seam UnhookAll reuses.
function HookHandle:_Detach()
    local p = self:_p()
    p.entry.handlers[p.id] = nil
end

-- Remove this one hook: stop it firing AND forget it from its owner's set.
function HookHandle:Unhook()
    self:_Detach()
    local p = self:_p()
    if p.ownerSet then p.ownerSet[self] = nil end
end

ns.HookHandle = HookHandle

function Hooks:OnInitialize()
    local p = self:_p()
    p.targets = {}     -- object -> method -> { handlers = { id -> fn } }
    p.byOwner = {}     -- owner  -> { handle -> true }
    p.nextId = 0
end

-- Install (once) the permanent secure dispatcher for object[method].
function Hooks:_Entry(object, method)
    local p = self:_p()
    p.targets[object] = p.targets[object] or {}
    local entry = p.targets[object][method]
    if not entry then
        entry = { handlers = {} }
        p.targets[object][method] = entry
        hooksecurefunc(object, method, function(...)
            for _, fn in pairs(entry.handlers) do fn(...) end
        end)
    end
    return entry
end

-- Secure(object, method, handler[, owner])  OR  Secure("GlobalName", handler[, owner]).
-- Returns a HookHandle (handle:Unhook()). `owner` (optional) lets UnhookAll remove
-- every hook a module installed in one call.
function Hooks:Secure(object, method, handler, owner)
    if type(object) == "string" then
        object, method, handler, owner = _G, object, method, handler
    end
    assert(type(object) == "table" and type(method) == "string" and type(handler) == "function",
        "Hooks:Secure(object, method, handler) -- bad arguments")
    local p = self:_p()
    local entry = self:_Entry(object, method)
    p.nextId = p.nextId + 1
    local ownerSet
    if owner then
        p.byOwner[owner] = p.byOwner[owner] or {}
        ownerSet = p.byOwner[owner]
    end
    local handle = HookHandle:New(entry, p.nextId, ownerSet)
    entry.handlers[p.nextId] = handler
    if ownerSet then ownerSet[handle] = true end
    return handle
end

function Hooks:UnhookAll(owner)
    local p = self:_p()
    local set = p.byOwner[owner]
    if not set then return end
    for handle in pairs(set) do handle:_Detach() end
    p.byOwner[owner] = nil
end

ns.ServiceManager:Register(Hooks:New("Hooks"))
