local addonName, ns = ...
local Class = ns.Class

-- Core/Compartment.lua
-- Registers HagAIO into the Addon Compartment — the button hub on the minimap
-- that collects many addons' icons (added in patch 10.1.0; manual-registration
-- signature current as of 11.0+). Left-click toggles the settings window;
-- right-click jumps to the activity log. This is NOT the legacy standalone
-- minimap button (LibDBIcon) — it's an entry in the compartment menu.

local Compartment = Class.new("Compartment")

function Compartment:Initialize()
    self:_p().registered = false
end

function Compartment:Register()
    local p = self:_p()
    if p.registered then return end
    if not (AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon) then
        return  -- compartment unavailable on this client; skip silently
    end

    AddonCompartmentFrame:RegisterAddon({
        text = "HagAIO",
        icon = ns.ICON,
        notCheckable = true,
        registerForAnyClick = true,  -- so right-click also reaches func
        func = function(_, menuInputData)
            local button = (menuInputData and menuInputData.buttonName) or "LeftButton"
            self:OnClick(button)
        end,
        funcOnEnter = function(button)
            GameTooltip:SetOwner(button, "ANCHOR_LEFT")
            GameTooltip:AddLine("|cff4ab3e6HagAIO|r")
            GameTooltip:AddLine("Left-click: open settings", 0.85, 0.87, 0.91)
            GameTooltip:AddLine("Right-click: activity log", 0.55, 0.58, 0.64)
            GameTooltip:Show()
        end,
        funcOnLeave = function()
            GameTooltip:Hide()
        end,
    })

    p.registered = true
    ns.Logger:Core():Debug("addon compartment button registered")
end

function Compartment:OnClick(button)
    if button == "RightButton" then
        ns.UI.SettingsWindow:Show("log")
    else  -- LeftButton (and any other) opens the settings window
        ns.UI.SettingsWindow:Toggle()
    end
end

ns.Compartment = Compartment
