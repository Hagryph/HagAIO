local addonName, ns = ...
local W = ns.UI.Widgets
local CooldownControl = ns.Class.new("CooldownControl", ns.Submodule)

-- Modules/Misc/CooldownControl.lua
-- Major cooldowns default on; a manual off choice lasts until combat ends.
-- This plain public Boolean is the read-only integration ABI. Private module
-- state remains authoritative; no spell casting or protected action is exposed.
_G.HagAIOCooldownsEnabled = false

function CooldownControl:_SetArmed(on)
    local p = self:_p()
    local armed = self:IsEnabled() and on == true
    local changed = p.armed ~= armed
    p.armed = armed
    _G.HagAIOCooldownsEnabled = p.armed
    if p.button then p.button:SetText(p.armed and "CDs: ON  [F9]" or "CDs: OFF  [F9]"):SetTone(p.armed and "green" or "red") end
    if changed then ns.EventBus:Emit("HagAIO_CooldownsChanged", p.armed) end
end

function CooldownControl:_Toggle()
    if self:IsEnabled() and not ns.EditMode:IsEditing() then self:_SetArmed(not self:_p().armed) end
end

function CooldownControl:_Reset()
    self:_SetArmed(true)
end

function CooldownControl:_OnLoad()
    local p = self:_p()
    if not p.button then
        p.button = W.KeyboundButton:New(UIParent, "CDs: ON  [F9]", {
            name = "HagAIOCooldownButton", width = 140, height = 28, primary = true,
        })
        p.button:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 180)
        p.button:SetOnClick(function() self:_Toggle() end)
    end
    self:_Reset()
    p.button:RegisterEditMode({
        key = "cooldownControl", label = "Cooldowns",
        default = { point = "BOTTOM", x = 0, y = 180 },
        active = function() return self:IsEnabled() end,
    })
    p.button:Show():SetKeyBinding("F9")
    self:On("PLAYER_REGEN_ENABLED", function() self:_Reset() end)
    self:On("PLAYER_ENTERING_WORLD", function() self:_Reset() end)
    self:On("PLAYER_DEAD", function() self:_Reset() end)
end

function CooldownControl:_OnUnload()
    self:_SetArmed(false)
    local button = self:_p().button
    if button then button:UnregisterEditMode():Hide():SetKeyBinding(nil) end
end

ns.SubmoduleManager:Register(CooldownControl:New("CooldownControl", {
    parent = { module = "Misc" },
    host = ns.ModuleManager:GetModule("Misc"),
    title = "Cooldown button",
    deps = { "EventBus", "EditMode" },
    onLoad = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = {
        { type = "note", text = "Cooldowns start on. Press F9 or click CDs to turn them off temporarily. Green is on; red is off. Resets to on after combat, on death or after a reload. Move the button in Edit Mode. Your saved F9 binding is preserved." },
    },
}))
