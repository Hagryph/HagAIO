local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins/NativeHealthBarSkin.lua
-- The always-available health-bar renderer. It keeps Blizzard's own frames and
-- only applies the shared health-colour settings to their existing fills.
local NativeHealthBarSkin = Class.new("NativeHealthBarSkin", ns.HealthBarSkin, {
    statics = {
        key = "native",
        label = "Native health bars",
        default = true,
    },
})

function NativeHealthBarSkin:CreateHealthBarView(bar)
    return ns.UI.Widgets.NativeHealthBarSkin:New(bar)
end

local skins = assert(ns.ModuleManager:GetModule("Skins"),
    "NativeHealthBarSkin requires the Skins module (load Modules/Skins.lua first)")
skins:RegisterHealthBarSkin(NativeHealthBarSkin:New(skins))
