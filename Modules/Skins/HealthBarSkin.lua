local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins/HealthBarSkin.lua
-- Abstract health-bar skin. It owns discovery and lifecycle for Blizzard's fixed
-- player/target/focus/pet frames plus pooled nameplates. A concrete skin creates
-- one independent visual view per bar and retargets pooled views to their current unit token.
local HealthBarSkin = Class.new("HealthBarSkin", ns.Skin, {
    abstract = true,
    statics = {
        observing = false,
        active = nil,
        fixedBars = {},
        fixedDestinations = { "player", "target", "focus", "pet" },
        fixedFrames = {
            player = "PlayerFrame",
            vehicle = "PlayerFrame",
            target = "TargetFrame",
            focus = "FocusFrame",
            pet = "PetFrame",
        },
        unitSettings = {
            player = "healthBarPlayer",
            vehicle = "healthBarPlayer",
            target = "healthBarTarget",
            focus = "healthBarFocus",
            pet = "healthBarPet",
        },
        targetSettingKeys = {
            healthBarPlayer = true,
            healthBarTarget = true,
            healthBarFocus = true,
            healthBarPet = true,
            healthBarNameplates = true,
        },
    },
})
local S = Class.statics(HealthBarSkin)

function HealthBarSkin:Initialize(owner)
    HealthBarSkin.super.Initialize(self, owner)
    local p = self:_p()
    p.entries = {}
    p.entryIdsByUnit = {}
    p.nameplateQueued = {}
    p.viewsByBar = setmetatable({}, { __mode = "k" })
    p.unitsByBar = setmetatable({}, { __mode = "k" })
end

-- This permanent hook only learns Blizzard's four stable health bars. It never
-- changes their protected geometry or invokes Blizzard's update function itself.
function HealthBarSkin.StartObserving()
    if S.observing or type(UnitFrameHealthBar_Update) ~= "function" then return end
    S.observing = true
    hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
        local frameName = S.fixedFrames[unit]
        local expectedFrame = frameName and _G[frameName]
        if expectedFrame and statusbar and statusbar.unitFrame == expectedFrame then
            local destination = unit == "vehicle" and "player" or unit
            S.fixedBars[destination] = { bar = statusbar, unit = unit }
            if S.active then S.active:_ObserveFixedBar(destination, unit, statusbar) end
        end
    end)
end

function HealthBarSkin:_Scope()
    return "health-bar-skin:" .. self:GetKey()
end

function HealthBarSkin:_UnitEnabled(settingUnit, nameplate)
    local key = nameplate and "healthBarNameplates" or S.unitSettings[settingUnit]
    return key ~= nil and self:GetSetting(key) == true
end

function HealthBarSkin:_EntryId(kind, unit, settingUnit)
    return kind == "nameplate" and ("nameplate:" .. unit) or ("fixed:" .. settingUnit)
end

function HealthBarSkin:_ReleaseEntry(id)
    local p = self:_p()
    local entry = p.entries[id]
    if not entry then return end
    p.entries[id] = nil
    local ids = p.entryIdsByUnit[entry.unit]
    if ids then
        ids[id] = nil
        if not next(ids) then p.entryIdsByUnit[entry.unit] = nil end
    end
    if p.unitsByBar[entry.bar] == id then p.unitsByBar[entry.bar] = nil end
    if entry.view then entry.view:Restore() end
end

function HealthBarSkin:_ReleaseEntries()
    local p = self:_p()
    local ids = {}
    for id in pairs(p.entries) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do self:_ReleaseEntry(id) end
    wipe(p.nameplateQueued)
end

function HealthBarSkin:_ApplyEntry(id, entry)
    local p = self:_p()
    if not (self:IsLoaded() and S.active == self and p.entries[id] == entry) then return end
    if not entry.view then
        local view = p.viewsByBar[entry.bar] or self:CreateHealthBarView(entry.bar, entry.unit)
        assert(view and type(view.Apply) == "function"
            and type(view.Restore) == "function" and type(view.UpdateHealth) == "function"
            and type(view.SetUnit) == "function",
            self:GetClassName() .. ": CreateHealthBarView must return a health-bar skin widget")
        p.viewsByBar[entry.bar] = view
        entry.view = view
        view:SetUnit(entry.unit)
    end
    self:ConfigureHealthBarView(entry.view)
    entry.view:Apply()
end

function HealthBarSkin:_QueueApply(id, entry)
    if entry.applyQueued then return end
    entry.applyQueued = true
    self:Owner():After(0, function()
        entry.applyQueued = false
        self:_ApplyEntry(id, entry)
    end, self:_Scope())
end

function HealthBarSkin:_AttachBar(unit, bar, kind, settingUnit)
    if not (self:IsLoaded() and bar and self:_UnitEnabled(settingUnit, kind == "nameplate")) then return end
    local p = self:_p()
    local id = self:_EntryId(kind, unit, settingUnit)
    local oldId = p.unitsByBar[bar]
    if oldId and oldId ~= id then self:_ReleaseEntry(oldId) end
    local entry = p.entries[id]
    if entry and entry.bar ~= bar then
        self:_ReleaseEntry(id)
        entry = nil
    end
    if not entry then
        entry = { bar = bar, unit = unit, kind = kind, settingUnit = settingUnit, applyQueued = false }
        p.entries[id] = entry
        p.unitsByBar[bar] = id
        local unitIds = p.entryIdsByUnit[unit]
        if not unitIds then unitIds = {}; p.entryIdsByUnit[unit] = unitIds end
        unitIds[id] = true
    elseif entry.unit ~= unit then
        local oldUnitIds = p.entryIdsByUnit[entry.unit]
        if oldUnitIds then
            oldUnitIds[id] = nil
            if not next(oldUnitIds) then p.entryIdsByUnit[entry.unit] = nil end
        end
        entry.unit = unit
        local unitIds = p.entryIdsByUnit[unit]
        if not unitIds then unitIds = {}; p.entryIdsByUnit[unit] = unitIds end
        unitIds[id] = true
        if entry.view then entry.view:SetUnit(unit) end
    end
    if not entry.view then self:_QueueApply(id, entry) end
end

function HealthBarSkin:_ObserveFixedBar(destination, unit, bar)
    if self:_UnitEnabled(destination, false) then
        self:_AttachBar(unit, bar, "fixed", destination)
    else
        self:_ReleaseEntry(self:_EntryId("fixed", unit, destination))
    end
end

function HealthBarSkin:_NameplateBar(nameplate)
    local unitFrame = nameplate and nameplate.UnitFrame
    if not unitFrame then return nil end
    if unitFrame.healthBar then return unitFrame.healthBar end
    local container = unitFrame.HealthBarsContainer
    return container and container.healthBar or nil
end

function HealthBarSkin:_AttachNameplate(unit, nameplate)
    if not self:_UnitEnabled(unit, true) then return end
    if not nameplate and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        nameplate = C_NamePlate.GetNamePlateForUnit(unit)
    end
    local bar = self:_NameplateBar(nameplate)
    if bar then self:_AttachBar(unit, bar, "nameplate") end
end

function HealthBarSkin:_QueueNameplate(unit)
    local p = self:_p()
    if p.nameplateQueued[unit] then return end
    p.nameplateQueued[unit] = true
    self:Owner():After(0, function()
        p.nameplateQueued[unit] = nil
        if self:IsLoaded() and S.active == self then self:_AttachNameplate(unit) end
    end, self:_Scope())
end

function HealthBarSkin:_AttachVisibleNameplates()
    if not (self:GetSetting("healthBarNameplates") and C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, nameplate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = nameplate.GetUnit and nameplate:GetUnit() or nameplate.unitToken
        if unit then self:_AttachNameplate(unit, nameplate) end
    end
end

function HealthBarSkin:_RefreshTargets()
    for _, destination in ipairs(S.fixedDestinations) do
        local observed = S.fixedBars[destination]
        if self:_UnitEnabled(destination, false) then
            if observed then self:_AttachBar(observed.unit, observed.bar, "fixed", destination) end
        else
            self:_ReleaseEntry(self:_EntryId("fixed", destination, destination))
        end
    end

    if self:GetSetting("healthBarNameplates") then
        self:_AttachVisibleNameplates()
    else
        local ids = {}
        for id, entry in pairs(self:_p().entries) do
            if entry.kind == "nameplate" then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do self:_ReleaseEntry(id) end
    end
end

function HealthBarSkin:OnLoad()
    assert(not S.active or S.active == self, "HealthBarSkin: another health-bar skin is still loaded")
    S.active = self
    local owner, scope = self:Owner(), self:_Scope()
    owner:On("UNIT_HEALTH", function(_, unit) self:UpdateHealth(unit) end, scope)
    owner:On("UNIT_MAXHEALTH", function(_, unit) self:UpdateHealth(unit) end, scope)
    owner:On("NAME_PLATE_UNIT_ADDED", function(_, unit) self:_QueueNameplate(unit) end, scope)
    owner:On("NAME_PLATE_UNIT_REMOVED", function(_, unit)
        self:_p().nameplateQueued[unit] = nil
        self:_ReleaseEntry(self:_EntryId("nameplate", unit))
    end, scope)
    self:_RefreshTargets()
end

function HealthBarSkin:OnUnload()
    self:Owner():ReleaseScope(self:_Scope())
    self:_ReleaseEntries()
    if S.active == self then S.active = nil end
end

function HealthBarSkin:UpdateHealth(unit)
    local p = self:_p()
    if unit then
        local ids = p.entryIdsByUnit[unit]
        if ids then
            for id in pairs(ids) do
                local entry = p.entries[id]
                if entry and entry.view then entry.view:UpdateHealth() end
            end
        end
        return
    end
    for _, entry in pairs(p.entries) do
        if entry.view then entry.view:UpdateHealth() end
    end
end

function HealthBarSkin:OnSettingChanged(key)
    if S.targetSettingKeys[key] then
        self:_RefreshTargets()
        return
    end
    for _, entry in pairs(self:_p().entries) do
        if entry.view then self:ConfigureHealthBarView(entry.view) end
    end
end

HealthBarSkin.CreateHealthBarView = Class.abstract("CreateHealthBarView")
function HealthBarSkin:ConfigureHealthBarView() end

ns.HealthBarSkin = HealthBarSkin
