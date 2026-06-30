local addonName, ns = ...
local Class = ns.Class
local Monk = ns.Monk   -- shared Monk surface (constants + registerSpec), set in Monk.lua

-- Modules/Class/Monk/Base.lua
-- The no-specialisation Monk spec (CurrentSpecKey "none"): the Expel Harm heal-threshold
-- marker every Monk has, regardless of spec. An ns.ClassSpec subclass whose Load/Unload
-- configure the HOST (self:Host(), the Class module instance). Other Monk specs extend it.

-- hag-lint-disable depcheck: Class  -- ns.ClassSpec is the spec base class from the Class module (a
-- load-order dep satisfied by the toc; this spec's parent chain is Monk -> Class), not a
-- service/module-instance dependency.

local MonkBase = Class.new("MonkBase", ns.ClassSpec)
ns.Monk.Base = MonkBase   -- so Brewmaster.lua (loads after) can extend it

MonkBase.settings = {
    { type = "header", text = "Expel Harm" },
    { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
      desc = "A line on your health bar marking where Expel Harm would heal you to full." },
    { type = "color", key = "expelColor", label = "Ready colour", default = Monk.EXPEL_READY_COLOR, dependsOn = "expelHarm" },
    { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = Monk.EXPEL_COOLDOWN_COLOR, dependsOn = "expelHarm" },
}

function MonkBase:OnSettingChanged()
    self:Host():_ScheduleUpdate()
end

function MonkBase:Load()
    local host = self:Host()
    local p = host:_p()

    -- install the player health-bar learning hook once per session (global, can't be
    -- removed; the latch lives on the host singleton's private state)
    if not p.healthHookInstalled and type(UnitFrameHealthBar_Update) == "function" then
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            -- Only the real PlayerFrame bar. Other frames (pet/target-of-target)
            -- transiently carry unit "player" during vehicle/art swaps; touching
            -- them here can flush a pending resize that compares secret health.
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                local hp = host:_p()
                -- The marker is anchored to the fill, so it tracks current health on its own: we do
                -- NOT repaint on a plain health tick. Only LEARN the bar (first time / a swap) and
                -- repaint then; its position thereafter changes solely on max-HP / heal-threshold /
                -- bar-resize events, which are wired separately.
                if hp.bar ~= statusbar then
                    hp.bar = statusbar
                    host:_WatchBarSize(statusbar, function() host:_ScheduleUpdate() end)
                    host:_ScheduleUpdate()
                end
            end
        end)
        p.healthHookInstalled = true
    end

    -- heal scales with spell power, so re-read it on anything that changes it
    host:On("UNIT_MAXHEALTH",             function(_, u) if u == "player" then host:_SnapshotMaxHP(); host:_ScheduleUpdate() end end, "spec")
    host:On("PLAYER_EQUIPMENT_CHANGED",   function() host:_RefreshHeal() end, "spec")
    host:On("PLAYER_LEVEL_UP",            function() host:_RefreshHeal() end, "spec")
    host:On("SPELLS_CHANGED",             function() host:_RefreshHeal() end, "spec")
    host:On("TRAIT_CONFIG_UPDATED",       function() host:_RefreshHeal() end, "spec")
    host:On("ACTIVE_COMBAT_CONFIG_CHANGED", function() host:_RefreshHeal() end, "spec")
    host:On("UNIT_AURA",                  function(_, u) if u == "player" then host:_MarkHealDirty() end end, "spec")
    p.onCooldown = false
    p.expelActive = true
    -- recolour the marker (ready <-> on-cooldown) via the secret-safe Cooldowns
    -- service (cast + non-secret booleans + base-cooldown timer).
    p.expelWatch = ns.Cooldowns:Watch(Monk.EXPEL_HARM, function(onCD)
        p.onCooldown = onCD
        host:_ScheduleUpdate()
    end)
    host:_RefreshHeal()
end

function MonkBase:Unload()
    local host = self:Host()
    local p = host:_p()
    host:ReleaseScope("spec")   -- drop every spec event sub + the AoE ticker
    p.expelActive = false
    p.onCooldown = false
    if p.expelWatch then p.expelWatch:Cancel(); p.expelWatch = nil end
    if p.marker then p.marker:Hide() end
    host:_HideOrbFill()
end

-- Expel Harm marker (event subs, Cooldowns watch, secret-safe paint).
-- ns.SpellTooltipParser is a pure Lib (always available) -- not a service dep.
ns.Monk.registerSpec("Monk-Base", MonkBase, "none", { "EventBus", "Cooldowns", "Secrets" })
