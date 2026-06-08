local S = dofile("Test/support.lua")

local function parser()
    local ns = S.newNs()
    S.load(ns, "Lib/SpellTooltipParser.lua")
    return ns._captured["SpellTooltipParser"]
end

describe("SpellTooltipParser", function()
    it("Heal parses 'healing for N' with commas", function()
        local p = parser()
        assert.are.equal(1234, p:Heal("Cleanses you, healing for 1,234 over time."))
        assert.is_nil(p:Heal("no number here"))
        assert.is_nil(p:Heal(nil))
    end)

    it("HealsYouFor parses the per-orb heal", function()
        local p = parser()
        assert.are.equal(500, p:HealsYouFor("A Healing Sphere that heals you for 500."))
        assert.is_nil(p:HealsYouFor("heals your ally"))
    end)

    it("Percent parses 'by N%'", function()
        local p = parser()
        assert.are.equal(4, p:Percent("Increases healing taken by 4%."))
        assert.is_nil(p:Percent("no percent"))
    end)

    it("Damage parses each phrasing variant", function()
        local p = parser()
        assert.are.equal(5678, p:Damage("Strike, dealing 5,678 damage."))
        assert.are.equal(900, p:Damage("Deals 900 Fire damage."))
        assert.are.equal(1000, p:Damage("1,000 damage to all nearby."))
        assert.is_nil(p:Damage("heals, no damage number"))
    end)

    it("UpToPercent parses 'by up to N%' (Strength of Spirit)", function()
        local p = parser()
        assert.are.equal(100, p:UpToPercent("Expel Harm's healing is increased by up to 100%, based on your missing health."))
        assert.are.equal(30, p:UpToPercent("increased by up to 30%"))
        assert.is_nil(p:UpToPercent("Increases healing taken by 4%."))   -- no "up to"
        assert.is_nil(p:UpToPercent(nil))
    end)

    it("guards non-string, non-nil input", function()
        local p = parser()
        assert.is_nil(p:Heal(123))
        assert.is_nil(p:Percent({}))
        assert.is_nil(p:Damage(true))
        assert.is_nil(p:HealsYouFor(5))
        assert.is_nil(p:UpToPercent(42))
    end)

    it("Damage prefers 'dealing N' over a later 'M damage'", function()
        local p = parser()
        assert.are.equal(5, p:Damage("dealing 5 plus 999 damage later"))
    end)

    it("Percent tolerates no space after 'by'", function()
        local p = parser()
        assert.are.equal(100, p:Percent("increased by100%"))
    end)

    it("HealsYouFor strips thousands commas", function()
        local p = parser()
        assert.are.equal(1250, p:HealsYouFor("heals you for 1,250."))
    end)
end)
