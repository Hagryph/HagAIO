local addonName, ns = ...
local Class = ns.Class
local DB = ns.DB

-- Services/Compartment.lua
-- Registers HagAIO into the Addon Compartment — the button hub on the minimap
-- that collects many addons' icons (added in patch 10.1.0; manual-registration
-- signature current as of 11.0+). Left-click toggles the settings window;
-- right-click jumps to the activity log. This is NOT the legacy standalone
-- minimap button (LibDBIcon) — it's an entry in the compartment menu.

local Compartment = Class.new("Compartment", ns.Service)

-- The Dashboard module IFF enabled: then LEFT-click opens it and settings move to MIDDLE-click;
-- otherwise the icon keeps LEFT-click = settings and middle does nothing. Lazy lookup so the
-- service never hard-depends on the optional module. hag-lint-disable depcheck: Dashboard
local function activeDashboard()
    local m = ns.ModuleManager and ns.ModuleManager:GetModule("Dashboard")
    return (m and m:IsEnabled()) and m or nil
end

function Compartment:OnInitialize()
    self:_p().registered = false
    ns.EventBus:On("PLAYER_LOGIN", function() self:Register() end)  -- self-apply on login
    -- Our General-page toggle is declared on registration (see below) and contributed
    -- by the Service base -- a push (icons -> window) with no cycle.
end

-- The single config row (account-wide), or nil before the database is built.
function Compartment:_Row()
    local db = self:DB(); if not db then return nil end
    return db:Select("shown"):From("compartment"):Where("id", "=", 1):Limit(1):Run()[1]
end

function Compartment:IsShown()
    local r = self:_Row()
    return (not r) or r.shown ~= false   -- default: shown
end

-- Toggle the compartment icon. Adding it takes effect immediately; the
-- compartment API has no unregister, so REMOVING it only applies after /reload.
-- Returns true if a /reload is needed to reflect the change.
function Compartment:SetShown(on)
    local db = self:DB()
    on = on and true or false
    if db then
        if self:_Row() then db:Update("compartment", { shown = on }, function(x) return x.id == 1 end)
        else db:Insert("compartment", { id = 1, shown = on }) end
    end
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
        icon = ns.Meta.ICON,
        notCheckable = true,
        registerForAnyClick = true,  -- so right-click also reaches func
        func = function(btn, menuInputData)
            local button = (menuInputData and menuInputData.buttonName) or "LeftButton"
            self:OnClick(button, btn)
        end,
        funcOnEnter = function(button)
            local lines = {}
            if activeDashboard() then
                lines[#lines + 1] = { text = "Left-click: Dashboard", key = "text" }
                lines[#lines + 1] = { text = "Middle-click: open settings" }
            else
                lines[#lines + 1] = { text = "Left-click: open settings", key = "text" }
            end
            lines[#lines + 1] = { text = "Right-click: enable/disable modules" }
            ns.UI.Widgets.Tooltip:Show(button, lines)
        end,
        funcOnLeave = function()
            ns.UI.Widgets.Tooltip:Hide()
        end,
    })

    p.registered = true
    ns.Logger:Core():Debug("addon compartment button registered")
end

function Compartment:OnClick(button, owner)
    if button == "RightButton" then
        ns.ModuleManager:OpenContextMenu(owner or AddonCompartmentFrame)
    elseif button == "MiddleButton" then
        if activeDashboard() then ns.UI.SettingsWindow:Toggle() end  -- settings only while Dashboard owns left-click
    else  -- LeftButton: Dashboard if it's on, otherwise settings
        local m = activeDashboard()
        if m then m:Toggle() else ns.UI.SettingsWindow:Toggle() end
    end
end

ns.ServiceManager:Register(Compartment:New("Compartment", {
    deps = { "EventBus", "SettingsWindow" },
    tables = { compartment = { scope = DB.Scope.GLOBAL, columns = {
        { name = "id",    type = DB.ColumnType.INTEGER, primaryKey = true },   -- singleton row (id = 1)
        { name = "shown", type = DB.ColumnType.BOOLEAN },
    } } },
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
