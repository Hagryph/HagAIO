local addonName, ns = ...
local Class = ns.Class

-- Lib/CVarHelper.lua
-- Pure helpers for reasoning about console-variable VALUES -- no WoW API. The CVars
-- module fetches the live value (C_CVar.GetCVar) and uses this to pick a control type
-- when no curated typing exists, so the inference rule is unit-testable on its own.

local CVarHelper = Class.new("CVarHelper", ns.Lib)

-- Infer a control type from a CVar's string value:
--   "0"/"1"        -> "boolean"
--   any number     -> "number"
--   anything else  -> "string"  (also the fallback for nil)
function CVarHelper:InferType(value)
    if value == "0" or value == "1" then return "boolean" end
    if tonumber(value) ~= nil then return "number" end
    return "string"
end

ns.LibManager:Register(CVarHelper:New("CVarHelper"))
