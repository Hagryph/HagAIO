local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins/OverwatchSkin.lua
-- Concrete Overwatch health-bar skin. HealthBarSkin owns unit discovery and lifecycle;
-- this class supplies only the visual implementation.
local OverwatchSkin = Class.new("OverwatchSkin", ns.HealthBarSkin, {
    statics = {
        key = "overwatch",
        label = "Overwatch",
        default = true,
        settings = {},
    },
})

function OverwatchSkin:CreateHealthBarView(bar, unit)
    return ns.UI.Widgets.OverwatchHealthBarSkin:New(bar, unit)
end

local skins = assert(ns.ModuleManager:GetModule("Skins"),
    "OverwatchSkin requires the Skins module (load Modules/Skins.lua first)")
skins:RegisterHealthBarSkin(OverwatchSkin:New(skins))
