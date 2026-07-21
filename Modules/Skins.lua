local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins.lua
-- Optional visual skins for Blizzard UI. The first skin restyles the real player
-- health bar with Overwatch-inspired percentage blocks and a cyan health-change
-- flash while leaving Blizzard's secret health value and prediction layers alone.
local Skins = Class.new("Skins", ns.Module)

local HEALTH_SKIN_CHANGED = "HagAIO_PlayerHealthSkinChanged"

function Skins:OnInitialize()
    local p = self:_p()
    p.playerBar = nil
    p.skinnedBar = nil
    p.skin = nil
    p.applyQueued = false

    -- Permanent learn-only hook: Blizzard's visible player health StatusBar is
    -- reliable here, while PlayerFrame aliases may refer to a hidden bar. Defer
    -- layout work one frame so this hook never flushes Blizzard's secret layout.
    if type(UnitFrameHealthBar_Update) == "function" then
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                module:_p().playerBar = statusbar
                module:_QueueApply()
            end
        end)
    end
end

function Skins:OnEnable()
    self:OnUnit("UNIT_HEALTH", { "player" }, function() self:_PulsePlayerHealth() end)
    self:OnUnit("UNIT_MAXHEALTH", { "player" }, function() self:_PulsePlayerHealth() end)
    self:_RefreshPlayerHealth()
end

function Skins:OnDisable()
    self:_p().applyQueued = false
    self:_RemovePlayerHealthSkin()
    ns.EventBus:Emit(HEALTH_SKIN_CHANGED)
end

function Skins:OwnsPlayerHealthColor()
    return self:IsEnabled() and self:GetSetting("playerHealth") == true
end

function Skins:_QueueApply()
    local p = self:_p()
    if not (self:IsEnabled() and self:GetSetting("playerHealth") and p.playerBar) then return end
    if p.applyQueued then return end
    p.applyQueued = true
    self:After(0, function()
        p.applyQueued = false
        if self:IsEnabled() and self:GetSetting("playerHealth") then
            self:_ApplyPlayerHealthSkin()
        end
    end)
end

function Skins:_ApplyPlayerHealthSkin()
    local p = self:_p()
    local bar = p.playerBar
    if not bar then return end
    if p.skin and p.skinnedBar ~= bar then self:_RemovePlayerHealthSkin() end
    if not p.skin then
        p.skin = ns.UI.Widgets.OverwatchHealthBarSkin:New(bar)
        p.skinnedBar = bar
    end
    p.skin:SetAnimated(self:GetSetting("animateHealth"))
    p.skin:Apply()
    ns.EventBus:Emit(HEALTH_SKIN_CHANGED)
end

function Skins:_RemovePlayerHealthSkin()
    local p = self:_p()
    if p.skin then p.skin:Dispose() end
    p.skin = nil
    p.skinnedBar = nil
end

function Skins:_RefreshPlayerHealth()
    if not self:IsEnabled() then return end
    if self:GetSetting("playerHealth") then
        self:_QueueApply()
    else
        self:_RemovePlayerHealthSkin()
        ns.EventBus:Emit(HEALTH_SKIN_CHANGED)
    end
end

function Skins:_RefreshHealthAnimation()
    local skin = self:_p().skin
    if skin then skin:SetAnimated(self:GetSetting("animateHealth")) end
end

function Skins:_PulsePlayerHealth()
    local p = self:_p()
    if p.skin then p.skin:Pulse() end
end

ns.ModuleManager:Register(Skins:New("Skins", {
    title = "Skins",
    description = "Restyles parts of the game interface.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    publishAs = "Skins",
    deps = { "EventBus" },
    settingsWatch = {
        playerHealth = "_RefreshPlayerHealth",
        animateHealth = "_RefreshHealthAnimation",
    },
    settings = {
        { type = "header", text = "Overwatch Health Bar" },
        { type = "toggle", key = "playerHealth", label = "Overwatch player health bar", default = true,
          desc = "Give your player health bar white segments and a cyan edge." },
        { type = "toggle", key = "animateHealth", label = "Animate health changes", default = true,
          desc = "Flash the filled health segments when your health changes.", dependsOn = "playerHealth" },
    },
}))
