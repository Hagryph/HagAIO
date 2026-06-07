local S = dofile("Test/support.lua")

local function setup()
    local ns = S.newNs()
    S.load(ns, "Services/SlashCommand.lua")
    local sc = ns._captured["SlashCommand"]; sc:OnInitialize()
    return sc
end

describe("SlashCommand", function()
    it("dispatches a registered sub-command with the rest as args", function()
        local sc = setup()
        local got
        sc:Register("config", function(rest) got = rest end)
        sc:_Dispatch("config foo bar")
        assert.are.equal("foo bar", got)
    end)

    it("is case-insensitive on the sub-command", function()
        local sc = setup()
        local hit = false
        sc:Register("config", function() hit = true end)
        sc:_Dispatch("CONFIG")
        assert.is_true(hit)
    end)

    it("trims surrounding whitespace", function()
        local sc = setup()
        local got
        sc:Register("c", function(rest) got = rest end)
        sc:_Dispatch("   c   x   ")
        assert.are.equal("x", got)
    end)

    it("runs the default handler for the empty command", function()
        local sc = setup()
        local hit = false
        sc:SetDefaultHandler(function() hit = true end)
        sc:_Dispatch("")
        assert.is_true(hit)
    end)

    it("prints help (no error) for an unknown command", function()
        local sc = setup()
        assert.is_true(pcall(function() sc:_Dispatch("nope") end))
    end)
end)
