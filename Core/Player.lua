local addonName, ns = ...

-- Core/Player.lua
-- Shared, session-cached player classification. These values belong to the
-- addon namespace rather than any feature module so every subsystem can read:
--   ns.Player.class = the unlocalized class token (for example "HUNTER")
--   ns.Player.spec  = "none" or the current specialization index
-- Core/Init.lua refreshes both at login and only `spec` on specialization changes.

local Player = { class = nil, spec = "none" }

function Player.RefreshClass()
    local class = UnitClass and select(2, UnitClass("player"))
    if class then Player.class = class end
    return Player.class
end

function Player.RefreshSpec()
    local idx = GetSpecialization and GetSpecialization()
    local count = (GetNumSpecializations and GetNumSpecializations()) or 0
    Player.spec = (idx and idx >= 1 and idx <= count) and idx or "none"
    return Player.spec
end

function Player.Refresh()
    Player.RefreshClass()
    Player.RefreshSpec()
end

ns.Player = Player
