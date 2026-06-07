local addonName, ns = ...

-- Modules/Collection/ATT.lua
-- All The Things integration as a SUBMODULE of the Collection module. It loads
-- ONLY when AllTheThings is installed (addonDeps) and the Collection module is
-- enabled (its parent). When loaded it walks ATT's window rows (public frames)
-- and chains each row's OnClick/OnEnter so Ctrl+Right-Click tracks the item in
-- the Task List, with a tooltip hint. Unloading just makes the handlers inert
-- (WoW scripts can't be unhooked).

local state = { active = false, getWindowHooked = false }
local sub  -- the submodule instance (set at registration); owns the "window" setting

-- Loaded (ATT present + Collection enabled) AND the window-hook option is on.
local function allows()
    return state.active and sub and sub:GetSetting("window") ~= false
end

local function onRowClick(row, button)
    if not allows() then return end
    if button ~= "RightButton" or not IsControlKeyDown() then return end
    local ref = row.ref
    if ref and (ref.itemID or ref.key) and ns.Tasks then
        ns.Tasks:TrackFromATT(ref)
        return true
    end
end

local function addTooltipHint(row)
    if not allows() then return end
    local ref = row and row.ref
    if not (ref and (ref.itemID or ref.key) and ns.Tasks) then return end
    if not (GameTooltip:IsShown() and GameTooltip:GetOwner() == row) then return end
    local tracked = ns.Tasks.IsTrackedRef and ns.Tasks:IsTrackedRef(ref)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff" .. ns.Theme.hex.accent .. "HagAIO|r  Ctrl+Right-Click: "
        .. (tracked and "stop tracking" or "track in Task List"), 0.55, 0.58, 0.64)
    GameTooltip:Show()
end

local function wrapRow(row)
    if row.__hagHooked then return end
    row.__hagHooked = true
    local origClick = row:GetScript("OnClick")
    row:SetScript("OnClick", function(s, b, ...)
        if onRowClick(s, b) then return end
        if origClick then return origClick(s, b, ...) end
    end)
    local origEnter = row:GetScript("OnEnter")
    row:SetScript("OnEnter", function(s, ...)
        if origEnter then origEnter(s, ...) end
        addTooltipHint(s)
    end)
end

local function hookWindow(window)
    if not window then return end
    local c = window.Container
    if c and c.rows then
        local i = 1
        while true do                       -- rawget: c.rows has a lazy __index
            local row = rawget(c.rows, i)
            if not row then break end
            wrapRow(row)
            i = i + 1
        end
    end
    if not window.__hagUpdateHooked and type(window.Update) == "function" then
        window.__hagUpdateHooked = true
        hooksecurefunc(window, "Update", function()
            C_Timer.After(0, function() hookWindow(window) end)
        end)
    end
end

local function hookAll()
    local app = _G.AllTheThings
    if not (app and app.Windows) then return end
    for _, w in pairs(app.Windows) do hookWindow(w) end
    if not state.getWindowHooked and type(app.GetWindow) == "function" then
        state.getWindowHooked = true
        hooksecurefunc(app, "GetWindow", function(_, suffix)
            local w = app.Windows and app.Windows[suffix]
            if w then C_Timer.After(0, function() hookWindow(w) end) end
        end)
    end
end

sub = ns.Submodule:New("ATT", {
    parent = { module = "Collection" },
    addonDeps = { "AllTheThings" },     -- only loads when ATT is installed
    title = "All The Things",
    settings = {                         -- shown on Collection's page only while loaded
        { type = "toggle", key = "window", label = "Hook the ATT window", default = true,
          desc = "Ctrl+Right-Click an item in the ATT window to track it in your Task List." },
    },
    onSettingChanged = function(_, key)
        if key == "window" and state.active and sub:GetSetting("window") ~= false then hookAll() end
    end,
    onLoad = function()
        state.active = true
        hookAll()
        if ns.Collection and ns.Collection.LogInfo then
            ns.Collection:LogInfo("All The Things integration loaded -- Ctrl+Right-Click items in ATT to track.")
        end
    end,
    onUnload = function()
        state.active = false            -- hooks remain installed but no-op
    end,
})
ns.SubmoduleManager:Register(sub)
