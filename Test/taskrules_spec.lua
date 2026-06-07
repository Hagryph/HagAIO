local S = dofile("Test/support.lua")

local function tr()
    local ns = S.newNs()
    S.load(ns, "Lib/TaskRules.lua")
    return ns._captured["TaskRules"]
end

describe("TaskRules:ATTKey", function()
    it("keys by the ref's key field and that field's value", function()
        assert.are.equal("att:questID:1234", (tr()):ATTKey({ key = "questID", questID = 1234 }))
    end)
    it("falls back to itemID, then text, then '?'", function()
        local t = tr()
        assert.are.equal("att:g:555", t:ATTKey({ itemID = 555 }))         -- no key field
        assert.are.equal("att:g:Bag of Coins", t:ATTKey({ text = "Bag of Coins" }))
        assert.are.equal("att:g:?", t:ATTKey({}))                          -- nothing identifying
    end)
    it("namespaces by field name so different field types can't collide", function()
        local t = tr()
        assert.are_not.equal(
            t:ATTKey({ key = "encounterID", encounterID = 7 }),
            t:ATTKey({ key = "questID", questID = 7 }))
    end)
end)

describe("TaskRules:ResetAt", function()
    it("daily/weekly tasks reset at now + secondsUntilReset", function()
        local t = tr()
        assert.are.equal(1000 + 600, t:ResetAt("daily", 1000, 600))
        assert.are.equal(1000 + 99999, t:ResetAt("weekly", 1000, 99999))
    end)
    it("a once task never resets", function()
        assert.is_nil((tr()):ResetAt("once", 1000, 600))
    end)
    it("nil when the seconds value is missing (API unavailable)", function()
        assert.is_nil((tr()):ResetAt("daily", 1000, nil))
    end)
end)
