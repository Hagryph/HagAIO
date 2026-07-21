local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins/HealthBarSkin.lua
-- Abstract player-health-bar skin. It owns discovery, deferred attachment, scoped health events,
-- restoration, and the view contract; a concrete skin only creates and configures its visual widget.
local HealthBarSkin = Class.new("HealthBarSkin", ns.Skin, {
    abstract = true,
    statics = {
        observing = false,
        playerBar = nil,
        active = nil,
    },
})
local S = Class.statics(HealthBarSkin)

function HealthBarSkin:Initialize(owner)
    HealthBarSkin.super.Initialize(self, owner)
    local p = self:_p()
    p.bar = nil
    p.view = nil
    p.applyQueued = false
end

-- Install the one permanent learn-only Blizzard hook shared by every health-bar skin. It merely
-- remembers the real player bar and hands it to the currently loaded HealthBarSkin instance.
function HealthBarSkin.StartObserving()
    if S.observing then return end
    if type(UnitFrameHealthBar_Update) ~= "function" then return end
    S.observing = true
    hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
        if unit == "player" and statusbar.unitFrame == PlayerFrame then
            S.playerBar = statusbar
            if S.active then S.active:_AttachPlayerBar(statusbar) end
        end
    end)
end

function HealthBarSkin:_Scope()
    return "health-bar-skin:" .. self:GetKey()
end

function HealthBarSkin:OnLoad()
    assert(not S.active or S.active == self, "HealthBarSkin: another health-bar skin is still loaded")
    S.active = self
    local owner, scope = self:Owner(), self:_Scope()
    owner:OnUnit("UNIT_HEALTH", { "player" }, function() self:UpdateHealth() end, scope)
    owner:OnUnit("UNIT_MAXHEALTH", { "player" }, function() self:UpdateHealth() end, scope)
    if S.playerBar then self:_AttachPlayerBar(S.playerBar) end
end

function HealthBarSkin:OnUnload()
    self:Owner():ReleaseScope(self:_Scope())
    local p = self:_p()
    p.applyQueued = false
    if p.view then p.view:Restore() end
    if S.active == self then S.active = nil end
end

function HealthBarSkin:_AttachPlayerBar(bar)
    local p = self:_p()
    if p.bar ~= bar then
        if p.view then
            p.view:Restore()
            p.view:Dispose()
        end
        p.bar = bar
        p.view = nil
    end
    self:_QueueApply()
end

function HealthBarSkin:_QueueApply()
    local p = self:_p()
    if not (self:IsLoaded() and p.bar) or p.applyQueued then return end
    p.applyQueued = true
    self:Owner():After(0, function()
        p.applyQueued = false
        if self:IsLoaded() and S.active == self then self:_Apply() end
    end, self:_Scope())
end

function HealthBarSkin:_Apply()
    local p = self:_p()
    if not p.view then
        p.view = self:CreateHealthBarView(p.bar)
        assert(p.view and type(p.view.Apply) == "function" and type(p.view.Restore) == "function"
            and type(p.view.UpdateHealth) == "function",
            self:GetClassName() .. ": CreateHealthBarView must return a health-bar skin widget")
    end
    self:ConfigureHealthBarView(p.view)
    p.view:Apply()
end

function HealthBarSkin:UpdateHealth()
    local view = self:_p().view
    if view then view:UpdateHealth() end
end

function HealthBarSkin:OnSettingChanged()
    local view = self:_p().view
    if view then self:ConfigureHealthBarView(view) end
end

HealthBarSkin.CreateHealthBarView = Class.abstract("CreateHealthBarView")
function HealthBarSkin:ConfigureHealthBarView() end

ns.HealthBarSkin = HealthBarSkin
