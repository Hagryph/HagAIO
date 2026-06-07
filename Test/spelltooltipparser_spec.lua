local S = dofile("Test/support.lua")

local function parser()
    local ns = S.newNs()
    S.load(ns, "Services/SpellTooltipParser.lua")
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
end)
