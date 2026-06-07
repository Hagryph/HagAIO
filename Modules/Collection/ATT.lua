local addonName, ns = ...
local Class = ns.Class

-- Modules/Collection/ATT.lua
-- All The Things integration as a SUBMODULE of the Collection module. It loads
-- ONLY when AllTheThings is installed (addonDeps) and the Collection module is
-- enabled (its parent). When loaded it walks ATT's window rows (public frames)
-- and chains each row's OnClick/OnEnter so Ctrl+Right-Click tracks the item in
-- the Task List, with a tooltip hint. Unloading just makes the handlers inert
-- (WoW scripts can't be unhooked).
--
-- Unlike most submodules (which customise via declarative onLoad/onUnload opts),
-- this one is a Submodule SUBCLASS: its state lives on private attributes (:_p())
-- and its behaviour is methods, so the row hooks capture the singleton `self`
-- instead of a file-level upvalue. It overrides the real lifecycle methods
-- (_Load/_Unload/OnSettingChanged), each chaining to super.

local ATT = Class.new("ATT", ns.Submodule)

function ATT:Initialize(name)
    ATT.super.Initialize(self, name, {
        parent    = { module = "Collection" },
        addonDeps = { "AllTheThings" },     -- only loads when ATT is installed
        moduleDeps = { "Tasklist" },        -- tracks ATT rows into the Task List (ns.Tasks)
        title    = "All The Things",
        settings = {                         -- shown on Collection's page only while loaded
            { type = "toggle", key = "window", label = "Hook the ATT window", default = true,
              desc = "Ctrl+Right-Click an item in the ATT window to track it in your Task List." },
        },
    })
    local p = self:_p()
    p.active = false           -- loaded AND wired (the row hooks no-op while false)
    p.getWindowHooked = false  -- ATT.GetWindow chained once per session
end

-- Loaded (ATT present + Collection enabled) AND the window-hook option is on.
function ATT:_Allows()
    return self:_p().active and self:GetSetting("window") ~= false
end

function ATT:_OnRowClick(row, button)
    if not self:_Allows() then return end
    if button ~= "RightButton" or not IsControlKeyDown() then return end
    local ref = row.ref
    if ref and (ref.itemID or ref.key) and ns.Tasks then
        ns.Tasks:TrackFromATT(ref)
        return true
    end
end

function ATT:_AddTooltipHint(row)
    if not self:_Allows() then return end
    local ref = row and row.ref
    if not (ref and (ref.itemID or ref.key) and ns.Tasks) then return end
    if not (GameTooltip:IsShown() and GameTooltip:GetOwner() == row) then return end
    local tracked = ns.Tasks.IsTrackedRef and ns.Tasks:IsTrackedRef(ref)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff" .. ns.Theme.hex.accent .. "HagAIO|r  Ctrl+Right-Click: "
        .. (tracked and "stop tracking" or "track in Task List"), ns.Theme.Unpack("grey"))
    GameTooltip:Show()
end

function ATT:_WrapRow(row)
    if row.__hagHooked then return end
    row.__hagHooked = true
    local origClick = row:GetScript("OnClick")
    row:SetScript("OnClick", function(s, b, ...)
        if self:_OnRowClick(s, b) then return end
        if origClick then return origClick(s, b, ...) end
    end)
    local origEnter = row:GetScript("OnEnter")
    row:SetScript("OnEnter", function(s, ...)
        if origEnter then origEnter(s, ...) end
        self:_AddTooltipHint(s)
    end)
end

function ATT:_HookWindow(window)
    if not window then return end
    local c = window.Container
    if c and c.rows then
        local i = 1
        while true do                       -- rawget: c.rows has a lazy __index
            local row = rawget(c.rows, i)
            if not row then break end
            self:_WrapRow(row)
            i = i + 1
        end
    end
    if not window.__hagUpdateHooked and type(window.Update) == "function" then
        window.__hagUpdateHooked = true
        hooksecurefunc(window, "Update", function()
            C_Timer.After(0, function() self:_HookWindow(window) end)
        end)
    end
end

function ATT:_HookAll()
    local app = _G.AllTheThings
    if not (app and app.Windows) then return end
    for _, w in pairs(app.Windows) do self:_HookWindow(w) end
    local p = self:_p()
    if not p.getWindowHooked and type(app.GetWindow) == "function" then
        p.getWindowHooked = true
        hooksecurefunc(app, "GetWindow", function(_, suffix)
            local w = app.Windows and app.Windows[suffix]
            if w then C_Timer.After(0, function() self:_HookWindow(w) end) end
        end)
    end
end

-- ---- lifecycle (override the real Submodule hooks, each chaining to super) ----
function ATT:_Load()
    ATT.super._Load(self)        -- set the loaded latch
    self:_p().active = true
    self:_HookAll()
    if ns.Collection and ns.Collection.LogEchoInfo then
        ns.Collection:LogEchoInfo("All The Things integration loaded -- Ctrl+Right-Click items in ATT to track.")
    end
end

function ATT:_Unload()
    self:_p().active = false      -- hooks remain installed but no-op
    ATT.super._Unload(self)       -- clear latch + release anything wired while loaded
end

function ATT:OnSettingChanged(key, value)
    ATT.super.OnSettingChanged(self, key, value)
    local p = self:_p()
    if key == "window" and p.active and self:GetSetting("window") ~= false then self:_HookAll() end
end

ns.SubmoduleManager:Register(ATT:New("ATT"))
