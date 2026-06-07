local addonName, ns = ...
local Class = ns.Class

-- Core/Hooks.lua
-- Removable secure-hook service. WoW's `hooksecurefunc` CANNOT be undone (there is
-- no unhook), so -- like AceHook -- we install ONE permanent post-hook per target
-- that dispatches to a set of registered handlers. "Unhooking" simply drops a
-- handler from that set, so it stops being called (the inert dispatcher remains).
-- This lets a module cleanly remove its hooks on disable.
--
--   local h = ns.Hooks:Secure(frame, "OnClicked", fn, owner)   -- a method on an object
--   local h = ns.Hooks:Secure("SomeGlobalFunc", fn, owner)     -- a global function
--   ns.Hooks:Unhook(h)         -- remove one
--   ns.Hooks:UnhookAll(owner)  -- remove every hook an owner installed (use on disable)

local Hooks = Class.new("Hooks", ns.Service)

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
-- Returns a handle to pass to Unhook. `owner` (optional) lets UnhookAll remove
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
    local handle = { entry = entry, id = p.nextId, owner = owner }
    entry.handlers[handle.id] = handler
    if owner then
        p.byOwner[owner] = p.byOwner[owner] or {}
        p.byOwner[owner][handle] = true
    end
    return handle
end

function Hooks:Unhook(handle)
    if not (handle and handle.entry) then return end
    handle.entry.handlers[handle.id] = nil
    local set = handle.owner and self:_p().byOwner[handle.owner]
    if set then set[handle] = nil end
end

function Hooks:UnhookAll(owner)
    local p = self:_p()
    local set = p.byOwner[owner]
    if not set then return end
    for handle in pairs(set) do handle.entry.handlers[handle.id] = nil end
    p.byOwner[owner] = nil
end

ns.ServiceManager:Register(Hooks:New("Hooks"))
