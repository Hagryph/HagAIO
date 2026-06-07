local addonName, ns = ...
local Class = ns.Class

-- Core/Cooldowns.lua
-- Watch a spell's cooldown WITHOUT reading secret values. In 12.0 the live
-- start/duration are secret, but `isActive`/`isOnGCD` are non-secret booleans and
-- GetSpellBaseCooldown is static. So we flip ON only on a real cast
-- (UNIT_SPELLCAST_SUCCEEDED) and drive an internal timer off the base cooldown to
-- flip OFF -- immune to GCD/stun (which never put the spell on cooldown). A
-- SPELL_UPDATE_COOLDOWN poll only ever flips OFF early (CDR/reset), never ON.
--
--   local w = ns.Cooldowns:Watch(spellID, function(onCooldown) ... end)
--   w:onCooldown   -- current state
--   ns.Cooldowns:Unwatch(w)

local Cooldowns = Class.new("Cooldowns", ns.Service)

function Cooldowns:OnInitialize() end

local function baseCooldown(spellID)
    if not GetSpellBaseCooldown then return nil end
    local ms = GetSpellBaseCooldown(spellID)
    if not ms or (issecretvalue and issecretvalue(ms)) or ms <= 0 then return nil end
    return ms / 1000
end

local function isActive(spellID)
    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    return cd and cd.isActive, cd and cd.isOnGCD
end

function Cooldowns:_Set(w, onCooldown)
    if w.onCooldown == onCooldown then return end
    w.onCooldown = onCooldown
    if w.onChange then w.onChange(onCooldown) end
end

function Cooldowns:_Start(w)
    self:_Set(w, true)
    if w.timer then w.timer:Cancel() end
    local dur = baseCooldown(w.spellID)
    if dur then
        w.timer = C_Timer.NewTimer(dur, function()
            w.timer = nil
            self:_Set(w, false)
        end)
    end
end

-- Backup flip-OFF only: a plain GCD also reports isActive=true, so we never flip
-- ON from polling.
function Cooldowns:_Poll(w)
    if not w.onCooldown then return end
    if isActive(w.spellID) then return end
    if w.timer then w.timer:Cancel(); w.timer = nil end
    self:_Set(w, false)
end

function Cooldowns:Watch(spellID, onChange)
    local bus = ns.EventBus
    local w = { spellID = spellID, onChange = onChange, onCooldown = false }
    w.castTok = bus:On("UNIT_SPELLCAST_SUCCEEDED", function(_, u, _, sid)
        if u == "player" and sid == spellID then self:_Start(w) end
    end)
    w.pollTok = bus:On("SPELL_UPDATE_COOLDOWN", function() self:_Poll(w) end)
    -- Reloaded mid-cooldown (not just a GCD): the real remaining is secret, so we
    -- can't run a precise internal timer -- just mark it on cooldown and let the
    -- SPELL_UPDATE_COOLDOWN poll flip it OFF when the cooldown actually ends.
    local active, onGCD = isActive(spellID)
    if active and not onGCD then self:_Set(w, true) end
    return w
end

function Cooldowns:Unwatch(w)
    if not w then return end
    local bus = ns.EventBus
    bus:Off("UNIT_SPELLCAST_SUCCEEDED", w.castTok)
    bus:Off("SPELL_UPDATE_COOLDOWN", w.pollTok)
    if w.timer then w.timer:Cancel(); w.timer = nil end
    w.onCooldown = false
end

ns.ServiceManager:Register(Cooldowns:New("Cooldowns", { deps = { "EventBus" } }))
