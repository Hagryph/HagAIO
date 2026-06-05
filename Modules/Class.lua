local addonName, ns = ...
local Class = ns.Class

-- Modules/Class.lua
-- Class-specific helpers for whatever class the player is on. The settings page
-- is built per class (and, later, per specialisation). For now only the Monk
-- "no specialisation" helper exists: an Expel Harm heal-threshold marker.
--
-- Expel Harm heals you for an amount shown in its spell description (it scales
-- with spell power). The marker is a vertical line on your health bar at
-- (max HP - heal): drop to/below it and one Expel Harm tops you off.

local ClassModule = Class.new("Class", ns.Module)

local EXPEL_HARM = 322101

-- Parse "healing for N" out of the spell description (enUS). Returns a number.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(EXPEL_HARM)
    if not desc or desc == "" then return nil end
    local n = desc:match("healing for%s*([%d,]+)")
    if not n then return nil end
    return tonumber((n:gsub(",", "")))
end

-- the hook is global; install once per session
local hookInstalled = false

-- ---- lifecycle ------------------------------------------------------------
function ClassModule:OnInitialize()
    local p = self:_p()
    p.tokens = {}
    p.heal = nil
    p.marker = nil
    local className, classToken = UnitClass("player")
    p.class = classToken

    if classToken == "MONK" then
        p.description = "Monk helpers — an Expel Harm heal-threshold marker on your health bar."
        p.settings = {
            { type = "header", text = "Expel Harm" },
            { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
              desc = "A line on your health bar marking where Expel Harm would heal you to full." },
            { type = "color", key = "expelColor", label = "Marker colour", default = { 1, 1, 1 } },
        }
    else
        p.description = ("No helpers for %s yet."):format(className or "your class")
        p.settings = {
            { type = "note", text = "Class helpers are added per class. There's nothing for your class yet." },
        }
    end

    -- Seed defaults for the dynamic schema (dbDefaults was applied before this).
    local db = self:GetDB()
    -- migrate the old cyan marker default to the new white default
    if db and type(db.expelColor) == "table" and db.expelColor[1] == 0.29 then
        db.expelColor = nil
    end
    if db then
        for _, s in ipairs(p.settings) do
            if s.key ~= nil and s.default ~= nil and db[s.key] == nil then
                if type(s.default) == "table" then
                    local c = {}
                    for i, v in ipairs(s.default) do c[i] = v end
                    db[s.key] = c
                else
                    db[s.key] = s.default
                end
            end
        end
    end
end

function ClassModule:OnEnable()
    local p = self:_p()
    if p.class ~= "MONK" then return end

    if not hookInstalled and type(UnitFrameHealthBar_Update) == "function" then
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            if unit == "player" then
                module:_p().bar = statusbar  -- the REAL visible bar
                module:_UpdateMarker()
            end
        end)
        hookInstalled = true
    end

    local bus = ns.EventBus.Get()
    p.tokens["UNIT_MAXHEALTH"]           = bus:On("UNIT_MAXHEALTH",           function(_, u) if u == "player" then self:_UpdateMarker() end end)
    p.tokens["PLAYER_EQUIPMENT_CHANGED"] = bus:On("PLAYER_EQUIPMENT_CHANGED", function() self:_RefreshHeal() end)
    p.tokens["SPELLS_CHANGED"]           = bus:On("SPELLS_CHANGED",           function() self:_RefreshHeal() end)
    p.tokens["PLAYER_LEVEL_UP"]          = bus:On("PLAYER_LEVEL_UP",          function() self:_RefreshHeal() end)
    p.tokens["PLAYER_ENTERING_WORLD"]    = bus:On("PLAYER_ENTERING_WORLD",    function() self:_RefreshHeal() end)

    self:_RefreshHeal()
end

function ClassModule:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.marker then p.marker:Hide() end
end

-- ---- marker ---------------------------------------------------------------
function ClassModule:_RefreshHeal()
    local p = self:_p()
    p.heal = readExpelHarmHeal()
    if not p.heal then
        -- description may not be loaded yet; retry shortly
        C_Timer.After(1, function()
            if self:IsEnabled() and not self:_p().heal then
                self:_p().heal = readExpelHarmHeal()
                self:_UpdateMarker()
            end
        end)
    end
    self:_UpdateMarker()
end

function ClassModule:_UpdateMarker()
    local p = self:_p()
    local bar = p.bar  -- the real bar captured from the hook
    if not bar then return end

    if not (self:IsEnabled() and self:GetSetting("expelHarm")) then
        if p.marker then p.marker:Hide() end
        return
    end

    if not p.marker then
        local m = bar:CreateTexture(nil, "OVERLAY", nil, 7)
        m:SetWidth(6)  -- thick
        p.marker = m
    end
    local m = p.marker

    local maxHP = UnitHealthMax("player")
    if (issecretvalue and issecretvalue(maxHP)) or not maxHP or maxHP <= 0 then
        m:Hide(); return  -- can't position from a secret/zero max
    end
    local heal = p.heal
    if not heal or heal <= 0 then m:Hide(); return end

    local frac = 1 - heal / maxHP
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    local c = self:GetSetting("expelColor") or { 1, 1, 1 }
    m:SetColorTexture(c[1], c[2], c[3], 1)

    local x = frac * bar:GetWidth()
    m:ClearAllPoints()
    m:SetPoint("TOP", bar, "TOPLEFT", x, 0)
    m:SetPoint("BOTTOM", bar, "BOTTOMLEFT", x, 0)
    m:Show()
end

function ClassModule:OnSettingChanged()
    self:_UpdateMarker()
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(ClassModule:New("Class", {
    title = "Class",
    description = "Helpers for your current class.",
    defaultEnabled = true,
    color = ns.Theme.hex.accent,
    settings = {},  -- built per class in OnInitialize
}))
