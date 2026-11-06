local addonName, ns = ...
local W = ns.UI.Widgets
local CombatControl = ns.Class.new("CombatControl", ns.Submodule)

-- Modules/Misc/CombatControl.lua
-- Session-only combat permission. The helper reads this Boolean; this addon
-- neither selects targets nor casts spells. Reload/module disable starts off.
_G.HagAIOCombatEnabled = false

function CombatControl:_SetArmed(on)
    local p = self:_p()
    p.armed = self:IsEnabled() and on == true
    _G.HagAIOCombatEnabled = p.armed
    if p.button then
        p.button:SetText(p.armed and "Combat: ON  [F10]" or "Combat: OFF  [F10]")
            :SetTone(p.armed and "green" or "red")
    end
end

function CombatControl:_Toggle()
    if self:IsEnabled() and not ns.EditMode:IsEditing() then self:_SetArmed(not self:_p().armed) end
end

function CombatControl:_OnLoad()
    local p = self:_p()
    if not p.button then
        p.button = W.KeyboundButton:New(UIParent, "Combat: OFF  [F10]", {
            name = "HagAIOCombatButton", width = 155, height = 28, primary = true,
        })
        p.button:SetPoint("BOTTOM", UIParent, "BOTTOM", 160, 180)
        p.button:SetOnClick(function() self:_Toggle() end)
    end
    self:_SetArmed(false)
    p.button:RegisterEditMode({
        key = "combatControl", label = "Combat",
        default = { point = "BOTTOM", x = 160, y = 180 },
        active = function() return self:IsEnabled() end,
    })
    p.button:Show():SetKeyBinding("F10")
end

function CombatControl:_OnUnload()
    self:_SetArmed(false)
    local button = self:_p().button
    if button then button:UnregisterEditMode():Hide():SetKeyBinding(nil) end
end

ns.SubmoduleManager:Register(CombatControl:New("CombatControl", {
    parent = { module = "Misc" },
    host = ns.ModuleManager:GetModule("Misc"),
    title = "Combat button",
    deps = { "EditMode" },
    onLoad = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = {
        { type = "note", text = "Press F10 or click Combat to allow the helper to act while already in combat. Green is on; red is off. It never initiates a pull. Move the button in Edit Mode. Starts off after a reload; stays on between fights until you turn it off." },
    },
}))
