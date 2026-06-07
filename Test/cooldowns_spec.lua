local S = dofile("Test/support.lua")

-- `cd` is what C_Spell.GetSpellCooldown returns ({ isActive, isOnGCD }), used for the
-- initial reload-state read. Base cooldown is a fixed 6s.
local function setup(cd)
    local clock = S.newClock()
    _G.GetTime = clock.GetTime
    _G.C_Timer = clock.C_Timer
    _G.issecretvalue = function() return false end
    _G.GetSpellBaseCooldown = function() return 6000 end          -- ms
    _G.C_Spell = { GetSpellCooldown = function() return cd end }
    local frames = S.stubFrames()
    local ns = S.newNs()
    S.load(ns, "Services/EventBus.lua"); ns._captured["EventBus"]:OnInitialize()
    S.load(ns, "Services/Cooldowns.lua")
    local cds = ns._captured["Cooldowns"]; cds:OnInitialize()
    return cds, frames, clock
end

local SPELL = 42
-- UNIT_SPELLCAST_SUCCEEDED is now a unit-filtered subscription (bus:OnUnit), so Watch
-- creates its own frame (frames[2]) -- frames[1] is the shared EventBus driver. Fire the
-- unit frame to simulate the player's cast.
local function cast(frames) frames[2]:Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", SPELL) end

describe("Cooldowns", function()
    it("flips ON after a cast and OFF when the base-cooldown timer elapses", function()
        local cds, frames, clock = setup({ isActive = false, isOnGCD = false })
        local states = {}
        local w = cds:Watch(SPELL, function(on) states[#states + 1] = on end)
        assert.is_false(w.onCooldown)
        cast(frames)
        assert.is_true(w.onCooldown)
        assert.are.equal(true, states[1])
        clock.advance(6)
        assert.is_false(w.onCooldown)
        assert.are.equal(false, states[2])
    end)

    it("a CDR/reset poll flips OFF early and cancels the timer", function()
        local cds, frames = setup({ isActive = false, isOnGCD = false })
        local w = cds:Watch(SPELL, function() end)
        cast(frames)
        assert.is_true(w.onCooldown)
        frames[1]:Fire("SPELL_UPDATE_COOLDOWN")   -- isActive=false -> off
        assert.is_false(w.onCooldown)
    end)

    it("reload mid-cooldown (active, not GCD) starts ON", function()
        local cds = setup({ isActive = true, isOnGCD = false })
        local w = cds:Watch(SPELL, function() end)
        assert.is_true(w.onCooldown)
    end)

    it("a GCD (active + onGCD) is NOT treated as on cooldown", function()
        local cds = setup({ isActive = true, isOnGCD = true })
        local w = cds:Watch(SPELL, function() end)
        assert.is_false(w.onCooldown)
    end)

    it("Unwatch clears state and cancels the timer", function()
        local cds, frames, clock = setup({ isActive = false, isOnGCD = false })
        local fired = 0
        local w = cds:Watch(SPELL, function() fired = fired + 1 end)
        cast(frames)            -- ON (fired=1)
        cds:Unwatch(w)
        assert.is_false(w.onCooldown)
        clock.advance(10)       -- timer cancelled -> no further change
        assert.are.equal(1, fired)
    end)
end)
