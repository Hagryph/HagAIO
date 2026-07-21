local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins.lua
-- Skin lifecycle and registry. A Skin owns the guarded Load/Unload transition; concrete skins expose
-- their selector label and settings from private class statics. The Skins module owns selection plus
-- the common HealthBarSkin settings, unloads the old object before loading the new one, and builds the
-- page from the registered skins.

local Skin = Class.new("Skin", nil, { abstract = true })

function Skin:Initialize(owner)
    local p = self:_p()
    p.owner = owner
    p.loaded = false
end

function Skin:Owner() return self:_p().owner end
function Skin:GetKey() return self:_statics().key end
function Skin:GetLabel() return self:_statics().label end
function Skin:IsDefault() return self:_statics().default == true end
function Skin:GetSettings() return self:_statics().settings or {} end
function Skin:GetSetting(key) return self:Owner():GetSetting(key) end
function Skin:IsLoaded() return self:_p().loaded end

-- Template-method lifecycle: subclasses implement OnLoad/OnUnload, while this base guarantees
-- idempotence and never leaves the lifecycle flag set when loading fails.
function Skin:Load()
    local p = self:_p()
    if p.loaded then return false end
    p.loaded = true
    local ok, err = pcall(self.OnLoad, self)
    if not ok then
        pcall(self.OnUnload, self)
        p.loaded = false
        error(err, 0)
    end
    return true
end

function Skin:Unload()
    local p = self:_p()
    if not p.loaded then return false end
    local ok, err = pcall(self.OnUnload, self)
    p.loaded = false
    if not ok then error(err, 0) end
    return true
end

Skin.OnLoad = Class.abstract("OnLoad")
Skin.OnUnload = Class.abstract("OnUnload")
function Skin:OnSettingChanged() end

ns.Skin = Skin

local Skins = Class.new("Skins", ns.Module, {
    statics = { noSkinKey = "none" },
})

function Skins:Initialize(name, opts)
    Skins.super.Initialize(self, name, opts)
    local p = self:_p()
    p.healthBarSkins = {}
    p.healthBarSkinsByKey = {}
    p.activeHealthBarSkin = nil
    p.defaultHealthBarSkinKey = nil
    self:_BuildSettings()
end

function Skins:RegisterHealthBarSkin(skin)
    assert(skin and skin.IsInstanceOf and skin:IsInstanceOf(ns.HealthBarSkin),
        "Skins:RegisterHealthBarSkin needs an ns.HealthBarSkin")
    assert(skin:Owner() == self, "Skins:RegisterHealthBarSkin: skin belongs to another owner")
    local key, label = skin:GetKey(), skin:GetLabel()
    assert(type(key) == "string" and key ~= "", "Skins:RegisterHealthBarSkin: skin needs a non-empty static key")
    assert(type(label) == "string" and label ~= "", "Skins:RegisterHealthBarSkin: skin needs a non-empty static label")

    local p = self:_p()
    assert(not p.healthBarSkinsByKey[key], "Skins:RegisterHealthBarSkin: duplicate skin key '" .. key .. "'")
    if skin:IsDefault() then
        assert(not p.defaultHealthBarSkinKey, "Skins:RegisterHealthBarSkin: only one skin may be the default")
        p.defaultHealthBarSkinKey = key
    end
    p.healthBarSkins[#p.healthBarSkins + 1] = skin
    p.healthBarSkinsByKey[key] = skin
    self:_BuildSettings()
    return skin
end

-- One stable schema assembled when skins register at file load. HealthBarSkin contributes the common
-- destination/colour rows once; each concrete skin adds only its own ordinary options. The module adds
-- structural visibility but never turns either set into indented `dependsOn` suboptions.
function Skins:_BuildSettings()
    local p, noSkinKey = self:_p(), self:_statics().noSkinKey
    local choices = { { value = noSkinKey, text = "No Skin" } }
    for _, skin in ipairs(p.healthBarSkins or {}) do
        choices[#choices + 1] = { value = skin:GetKey(), text = skin:GetLabel() }
    end

    local settings = {
        { type = "header", text = "HealthBar Skin" },
        { type = "dropdown", key = "healthBarSkin", label = "Skin",
          default = p.defaultHealthBarSkinKey or noSkinKey, options = choices },
    }
    if ns.HealthBarSkin then
        for _, authored in ipairs(ns.HealthBarSkin.CommonSettings()) do
            local option = {}
            for key, value in pairs(authored) do option[key] = value end
            option.visibleWhen = { key = "healthBarSkin", notEquals = noSkinKey }
            settings[#settings + 1] = option
        end
    end
    for _, skin in ipairs(p.healthBarSkins or {}) do
        for _, authored in ipairs(skin:GetSettings()) do
            local option = {}
            for key, value in pairs(authored) do option[key] = value end
            option.visibleWhen = { key = "healthBarSkin", equals = skin:GetKey() }
            settings[#settings + 1] = option
        end
    end
    ns.Contributions.ValidateSettings(settings, self:GetName())
    p.settings = settings
end

function Skins:GetSettings() return self:_p().settings end

-- The schema is dynamic at construction time: concrete skin files register after this parent module
-- file, but before ADDON_LOADED asks every owner to contribute its tables.
function Skins:_CollectTables()
    local schema, nsKey = self:GetSettings(), self:_SettingsNamespace()
    ns.SettingsTables:Register(nsKey, schema)
    return ns.SettingsTables:DeriveTables(nsKey, schema)
end

function Skins:_ActivateSelectedHealthBarSkin()
    local p = self:_p()
    local selected = self:GetSetting("healthBarSkin")
    local nextSkin = self:IsEnabled() and p.healthBarSkinsByKey[selected] or nil
    if p.activeHealthBarSkin == nextSkin then return end

    if p.activeHealthBarSkin then p.activeHealthBarSkin:Unload() end
    p.activeHealthBarSkin = nil
    if nextSkin then
        nextSkin:Load()
        p.activeHealthBarSkin = nextSkin
    end
end

function Skins:OnInitialize()
    ns.HealthBarSkin.StartObserving()
end

function Skins:OnEnable()
    self:_ActivateSelectedHealthBarSkin()
end

function Skins:OnDisable()
    local p = self:_p()
    if p.activeHealthBarSkin then p.activeHealthBarSkin:Unload() end
    p.activeHealthBarSkin = nil
end

function Skins:OnSettingChanged(key, value)
    if key == "healthBarSkin" then
        self:_ActivateSelectedHealthBarSkin()
        return
    end
    local active = self:_p().activeHealthBarSkin
    if active then active:OnSettingChanged(key, value) end
end

ns.ModuleManager:Register(Skins:New("Skins", {
    title = "Skins",
    description = "Restyles parts of the game interface.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    -- Settings are assembled from later-loaded skin classes, so DatabaseManager is explicit rather
    -- than being inferred from the empty constructor schema. Health-bar skins own scoped unit events
    -- and zero-delay application through this module's EventBus/Scheduler resources.
    -- The dynamic settings table contribution and HealthBarSkin's owner-scoped On/After calls
    -- are indirect uses, so the dependency scanner cannot see them at this module call site.
    -- hag-lint-disable depcheck: DatabaseManager, EventBus, Scheduler
    deps = { "DatabaseManager", "EventBus", "Scheduler" },
    settings = {},
}))
