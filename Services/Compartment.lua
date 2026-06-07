local addonName, ns = ...
local Class = ns.Class

-- Services/Compartment.lua
-- Registers HagAIO into the Addon Compartment — the button hub on the minimap
-- that collects many addons' icons (added in patch 10.1.0; manual-registration
-- signature current as of 11.0+). Left-click toggles the settings window;
-- right-click jumps to the activity log. This is NOT the legacy standalone
-- minimap button (LibDBIcon) — it's an entry in the compartment menu.

local Compartment = Class.new("Compartment", ns.Service)

function Compartment:OnInitialize()
    self:_p().registered = false
    ns.EventBus:On("PLAYER_LOGIN", function() self:Register() end)  -- self-apply on login
    -- Our General-page toggle is declared on registration (see below) and contributed
    -- by the Service base -- a push (icons -> window) with no cycle.
end

-- Account-wide visibility setting (default on).
function Compartment:_DB()
    return ns.SavedVars:Namespace("compartment", { shown = true })
end

function Compartment:IsShown()
    return self:_DB().shown ~= false
end

-- Toggle the compartment icon. Adding it takes effect immediately; the
-- compartment API has no unregister, so REMOVING it only applies after /reload.
-- Returns true if a /reload is needed to reflect the change.
function Compartment:SetShown(on)
    self:_DB().shown = on and true or false
    if on then
        self:Register()
        return false
    end
    return self:_p().registered  -- already added this session -> needs reload to hide
end

function Compartment:Register()
    local p = self:_p()
    if p.registered then return end
    if not self:IsShown() then return end  -- honour the visibility setting
    if not (AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon) then
        return  -- compartment unavailable on this client; skip silently
    end

    AddonCompartmentFrame:RegisterAddon({
        text = "HagAIO",
        icon = ns.ICON,
        notCheckable = true,
        registerForAnyClick = true,  -- so right-click also reaches func
        func = function(btn, menuInputData)
            local button = (menuInputData and menuInputData.buttonName) or "LeftButton"
            self:OnClick(button, btn)
        end,
        funcOnEnter = function(button)
            GameTooltip:SetOwner(button, "ANCHOR_LEFT")
            GameTooltip:AddLine("|cff4ab3e6HagAIO|r")
            GameTooltip:AddLine("Left-click: open settings", 0.85, 0.87, 0.91)
            GameTooltip:AddLine("Right-click: enable/disable modules", 0.55, 0.58, 0.64)
            GameTooltip:Show()
        end,
        funcOnLeave = function()
            GameTooltip:Hide()
        end,
    })

    p.registered = true
    ns.Logger:Core():Debug("addon compartment button registered")
end

function Compartment:OnClick(button, owner)
    if button == "RightButton" then
        ns.ModuleManager:OpenContextMenu(owner or AddonCompartmentFrame)
    else  -- LeftButton (and any other) opens the settings window
        ns.UI.SettingsWindow:Toggle()
    end
end

ns.ServiceManager:Register(Compartment:New("Compartment", {
    deps = { "EventBus", "SavedVars", "SettingsWindow" },
    generalToggles = {
        {
            section = "Icons",
            label = "Compartment icon",
            desc = "Shows HagAIO in the minimap's addon-compartment menu.",
            flagReload = true,
            get = "IsShown",
            set = "SetShown",  -- returns true if /reload needed
            reloadMsg = "Reload your UI (/reload) to remove the compartment icon.",
        },
    },
}))
