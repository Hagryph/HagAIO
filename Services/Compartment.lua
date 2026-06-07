local addonName, ns = ...
local Class = ns.Class

-- Services/Compartment.lua
-- Registers HagAIO into the Addon Compartment — the button hub on the minimap
-- that collects many addons' icons (added in patch 10.1.0; manual-registration
-- signature current as of 11.0+). Left-click toggles the settings window;
-- right-click jumps to the activity log. This is NOT the legacy standalone
-- minimap button (LibDBIcon) — it's an entry in the compartment menu.

local Compartment = Class.new("Compartment", ns.Service, { mixins = { ns.Persisted } })

function Compartment:OnInitialize()
    self:_p().registered = false
    self:_BindStore("compartment", { shown = true })  -- account-wide; cached _Store (ns.Persisted)
    ns.EventBus:On("PLAYER_LOGIN", function() self:Register() end)  -- self-apply on login
    -- Our General-page toggle is declared on registration (see below) and contributed
    -- by the Service base -- a push (icons -> window) with no cycle.
end

function Compartment:IsShown()
    return self:_Store().shown ~= false
end

-- Toggle the compartment icon. Adding it takes effect immediately; the
-- compartment API has no unregister, so REMOVING it only applies after /reload.
-- Returns true if a /reload is needed to reflect the change.
function Compartment:SetShown(on)
    self:_Store().shown = on and true or false
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
            ns.UI.Widgets.IconTooltip(button, {
                { text = "Left-click: open settings", key = "text" },
                { text = "Right-click: enable/disable modules" },
            })
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
    deps = { "EventBus", "SettingsWindow" },  -- SavedVars reached lazily via the ns.Persisted store
    generalToggles = {
        {
            section = "Icons",
            label = "Compartment icon",
            desc = "Shows HagAIO in the minimap's addon-compartment menu.",
            reload = true,
            get = "IsShown",
            set = "SetShown",  -- returns true if /reload needed
            reloadMsg = "Reload your UI (/reload) to remove the compartment icon.",
        },
    },
}))
