local addonName, ns = ...
local CombatLogging = ns.Class.new("CombatLogging", ns.Submodule)

function CombatLogging:_OnLoad()
    if self:GetSetting("permanent") and self:GetSetting("instance") then self:SetSetting("instance", false) end
    self:On("PLAYER_ENTERING_WORLD", function() self:_Apply() end)
    self:On("ZONE_CHANGED_NEW_AREA", function() self:_Apply() end)
    self:_Apply()
end

function CombatLogging:_Retry()
    -- LoggingCombat returns nil when its shared client rate limit is exhausted.
    -- This retries a rejected API operation; events themselves are never throttled.
    self:ReleaseScope("logging-retry")
    self:After(10, function() self:_Apply() end, "logging-retry")
end

function CombatLogging:_Apply()
    if not self:IsEnabled() or not LoggingCombat then return end
    local p = self:_p()
    self:ReleaseScope("logging-retry")
    local permanent = self:GetSetting("permanent")
    local instance = self:GetSetting("instance")
    if not permanent and not instance and not p.owns then return end
    if not p.owns then
        local initial = LoggingCombat() -- zero arguments: nil explicitly would disable logging
        if initial == nil then self:_Retry(); return end
        p.initial, p.applied, p.owns = initial, initial, true
    end
    local desired = p.initial
    if permanent then desired = true
    elseif instance then desired = IsInInstance() and true or false end
    if p.applied ~= desired then
        local actual = LoggingCombat(desired)
        if actual == nil then self:_Retry(); return end
        p.applied = actual
    end
    if not permanent and not instance then p.owns = false end
end

function CombatLogging:_OnSettingChanged(key, value)
    local p = self:_p()
    if p.switching then return end
    if value then
        p.switching = true
        self:SetSetting(key == "instance" and "permanent" or "instance", false)
        p.switching = false
    end
    self:_Apply()
    -- Both visible checkboxes reflect the one effective mode immediately.
    local window = ns.UI.SettingsWindow
    if window then window:InvalidateModule(self:GetHost():GetName()) end
end

function CombatLogging:_OnUnload()
    local p = self:_p()
    if p.owns and p.applied ~= p.initial and LoggingCombat then
        local actual = LoggingCombat(p.initial)
        if actual == nil then self:LogWarn("Combat logging could not be restored. Use /combatlog to change it.") end
    end
    p.owns, p.applied, p.initial = nil, nil, nil
end

ns.SubmoduleManager:Register(CombatLogging:New("CombatLogging", {
    parent = { module = "Misc" },
    host = ns.ModuleManager:GetModule("Misc"),
    title = "Combat Logging",
    deps = { "SettingsWindow" },
    settingsWatch = { instance = "_OnSettingChanged", permanent = "_OnSettingChanged" },
    onLoad = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = {
        { type = "toggle", key = "instance", label = "Auto combat log in instances", default = false },
        { type = "toggle", key = "permanent", label = "Permanent combat log", default = false },
        { type = "note", text = "Choose one mode. Instance logging stops outside instances; permanent logging stays on. Turning both off restores your previous logging state." },
    },
}))
