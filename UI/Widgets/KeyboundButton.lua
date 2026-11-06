local addonName, ns = ...
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget

-- UI/Widgets/KeyboundButton.lua
-- Named push button with a temporary, owned key binding. Binding changes wait
-- for combat lockdown to end; they never replace the player's saved bindings.
local KeyboundButtonW = ns.Class.new("KeyboundButton", Widgets.Button)

function KeyboundButtonW:Initialize(parent, text, opts)
    assert(opts and opts.name, "A keybound button needs a name")
    KeyboundButtonW.super.Initialize(self, parent, text, opts)
    self:_Frame():RegisterForClicks("LeftButtonUp")
end

function KeyboundButtonW:_ApplyBinding()
    local p = self:_p()
    if InCombatLockdown() then
        if not p.bindingToken then
            p.bindingToken = ns.EventBus:On("PLAYER_REGEN_ENABLED", function() self:_ApplyBinding() end)
        end
        return
    end
    if p.bindingToken then ns.EventBus:Off("PLAYER_REGEN_ENABLED", p.bindingToken); p.bindingToken = nil end
    local frame = self:_Frame()
    ClearOverrideBindings(frame)
    if p.bindingKey then SetOverrideBindingClick(frame, false, p.bindingKey, frame:GetName(), "LeftButton") end
end

function KeyboundButtonW:SetKeyBinding(key)
    local p = self:_p()
    if p.retired and key then return self end
    p.bindingKey = key
    self:_ApplyBinding()
    return self
end

function KeyboundButtonW:Dispose()
    if self:_p().retired then return end
    self:_p().retired = true
    self:SetOnClick(nil)
    self:SetKeyBinding(nil)
    KeyboundButtonW.super.Dispose(self)
end

Widgets.KeyboundButton = KeyboundButtonW
