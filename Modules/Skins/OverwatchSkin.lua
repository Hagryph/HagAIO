local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins/OverwatchSkin.lua
-- Concrete Overwatch player-health-bar skin. The HealthBarSkin base owns attachment and lifecycle;
-- this class owns only its visual implementation and the options that configure it.
local OverwatchSkin = Class.new("OverwatchSkin", ns.HealthBarSkin, {
    statics = {
        key = "overwatch",
        label = "Overwatch",
        default = true,
        settings = {
            { type = "toggle", key = "animateHealth", label = "Animate health changes", default = true,
              desc = "Smoothly move health through the fragments." },
        },
    },
})

function OverwatchSkin:CreateHealthBarView(bar)
    return ns.UI.Widgets.OverwatchHealthBarSkin:New(bar)
end

function OverwatchSkin:ConfigureHealthBarView(view)
    view:SetAnimated(self:GetSetting("animateHealth"))
end

local skins = assert(ns.ModuleManager:GetModule("Skins"),
    "OverwatchSkin requires the Skins module (load Modules/Skins.lua first)")
skins:RegisterHealthBarSkin(OverwatchSkin:New(skins))
