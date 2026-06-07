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

-- Pick a control type for a CVar: a curated `knownEntry` ({ type =, options = }) wins;
-- otherwise infer from the live string value. Returns (type, options) -- options is nil for
-- an inferred type. The CVars module supplies the known entry and the live value.
function CVarHelper:DetectType(knownEntry, liveValue)
    if knownEntry then return knownEntry.type, knownEntry.options end
    return self:InferType(liveValue)
end

ns.LibManager:Register(CVarHelper:New("CVarHelper"))
