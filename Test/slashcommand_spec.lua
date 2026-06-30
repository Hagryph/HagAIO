local S = dofile("Test/support.lua")

local function setup()
    local ns = S.newNs()
    S.load(ns, "Services/SlashCommand.lua")
    local sc = ns._captured["SlashCommand"]; sc:OnInitialize()
    return sc, ns
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

    it("Unregister removes a sub-command (falls back to help)", function()
        local sc = setup()
        local hit = 0
        sc:Register("config", function() hit = hit + 1 end)
        sc:_Dispatch("config"); assert.are.equal(1, hit)
        sc:Unregister("config")
        sc:_Dispatch("config")  -- gone -> help, handler not called again
        assert.are.equal(1, hit)
        assert.is_true(pcall(function() sc:Unregister("never") end))  -- unknown -> no-op
    end)

    -- ---- sub-command groups (RegisterGroup auto-routing) ------------------------------------------
    it("RegisterGroup routes the second word to the sub-handler, passing the remaining args", function()
        local sc = setup()
        local got
        sc:RegisterGroup("cvar", "console variables", { set = { fn = function(rest) got = rest end } })
        sc:_Dispatch("cvar set foo bar")
        assert.are.equal("foo bar", got)            -- /hag cvar set <rest> -> the set sub-handler
    end)

    it("a bare or unknown sub of a group prints usage (no error), never a handler", function()
        local sc = setup()
        local ran = false
        sc:RegisterGroup("cvar", "h", { set = { fn = function() ran = true end } })
        assert.is_true(pcall(function() sc:_Dispatch("cvar") end))      -- bare -> usage list
        assert.is_true(pcall(function() sc:_Dispatch("cvar nope") end)) -- unknown sub -> usage list
        assert.is_false(ran)
    end)

    it("dev-only sub-commands are refused off a developer character and routed on one", function()
        local sc, ns = setup()
        local ran = false
        sc:RegisterGroup("cvar", "h", { dump = { fn = function() ran = true end, dev = true } })
        ns.IsDevChar = function() return false end
        sc:_Dispatch("cvar dump")
        assert.is_false(ran)                        -- hidden + refused off-whitelist
        ns.IsDevChar = function() return true end
        sc:_Dispatch("cvar dump")
        assert.is_true(ran)                         -- routed on a developer character
        ns.IsDevChar = nil
    end)

    -- Replies go through the service's OWN Logger channel (recorded in the Log page + governed by
    -- "Echo to Chat"), not the boot-only ns.Log print surface that bypasses both.
    it("help/listing replies route through the owner channel, not raw ns.Log", function()
        local sc, ns = setup()
        local recorded = {}
        sc:_p().log = { EchoInfo = function(_, msg) recorded[#recorded + 1] = msg end }
        ns.Log = { Print = function() error("a slash reply leaked to ns.Log.Print") end }
        sc:_Dispatch("nope")                        -- unknown -> _PrintHelp
        assert.is_true(#recorded >= 1)              -- the command listing went to the channel
        assert.are.equal("commands:", recorded[1])
    end)
end)
