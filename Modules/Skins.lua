local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins.lua
-- Optional visual skins for Blizzard UI. The first skin restyles the real player
-- health bar with independent Overwatch-inspired fragments and native smooth
-- fill movement while leaving Blizzard's secret health value and predictions alone.
local Skins = Class.new("Skins", ns.Module)

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
    self:OnUnit("UNIT_HEALTH", { "player" }, function() self:_UpdatePlayerHealth() end)
    self:OnUnit("UNIT_MAXHEALTH", { "player" }, function() self:_UpdatePlayerHealth() end)
    self:_RefreshPlayerHealth()
end

function Skins:OnDisable()
    self:_p().applyQueued = false
    self:_RemovePlayerHealthSkin()
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
    if p.skin and p.skinnedBar ~= bar then
        p.skin:Dispose()
        p.skin = nil
        p.skinnedBar = nil
    end
    if not p.skin then
        p.skin = ns.UI.Widgets.OverwatchHealthBarSkin:New(bar)
        p.skinnedBar = bar
    end
    p.skin:SetAnimated(self:GetSetting("animateHealth"))
    p.skin:Apply()
end

function Skins:_RemovePlayerHealthSkin()
    local p = self:_p()
    if p.skin then p.skin:Restore() end
end

function Skins:_RefreshPlayerHealth()
    if not self:IsEnabled() then return end
    if self:GetSetting("playerHealth") then
        self:_QueueApply()
    else
        self:_RemovePlayerHealthSkin()
    end
end

function Skins:_RefreshHealthAnimation()
    local skin = self:_p().skin
    if skin then skin:SetAnimated(self:GetSetting("animateHealth")) end
end

function Skins:_UpdatePlayerHealth()
    local p = self:_p()
    if p.skin then p.skin:UpdateHealth() end
end

ns.ModuleManager:Register(Skins:New("Skins", {
    title = "Skins",
    description = "Restyles parts of the game interface.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    settingsWatch = {
        playerHealth = "_RefreshPlayerHealth",
        animateHealth = "_RefreshHealthAnimation",
    },
    settings = {
        { type = "header", text = "Overwatch Health Bar" },
        { type = "toggle", key = "playerHealth", label = "Overwatch player health bar", default = true,
          desc = "Replace the health fill with ten separate slanted fragments." },
        { type = "toggle", key = "animateHealth", label = "Animate health changes", default = true,
          desc = "Smoothly move health through the fragments.", dependsOn = "playerHealth" },
    },
}))
