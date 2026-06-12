-- Test/devchar_spec.lua — dev-character identity (Core/Namespace.lua): IsDevChar caching,
-- WhenDevCharKnown deferral while the player unit isn't available, and the soft/forced
-- ResolveDevChar flushes Core/Init.lua drives on ADDON_LOADED / PLAYER_LOGIN.

-- Load Core/Namespace.lua against stubbed identity APIs. `name` may be nil (identity not
-- ready yet) and can be changed later via the returned control table.
local function freshNs(name)
    local ctl = { name = name }
    local savedUnitName, savedRealm = _G.UnitName, _G.GetNormalizedRealmName
    _G.UnitName = function() return ctl.name end
    _G.GetNormalizedRealmName = function() return "TestRealm" end
    local ns = {}
    assert(loadfile("Core/Namespace.lua"))("HagAIO", ns)
    ns.DEV_WHITELIST["Dev-TestRealm"] = true   -- the whitelist ships empty; seed the spec's dev char
    ctl.restore = function() _G.UnitName, _G.GetNormalizedRealmName = savedUnitName, savedRealm end
    return ns, ctl
end

describe("dev-character identity", function()
    it("IsDevChar resolves + caches once the player unit exists", function()
        local ns, ctl = freshNs("Dev")
        assert.is_true(ns.IsDevChar())
        ctl.name = "SomeoneElse"               -- cached: a later rename changes nothing
        assert.is_true(ns.IsDevChar())
        ctl.restore()
    end)

    it("WhenDevCharKnown runs immediately when identity is already known", function()
        local ns, ctl = freshNs("Dev")
        local got
        ns.WhenDevCharKnown(function(isDev) got = isDev end)
        assert.is_true(got)
        ctl.restore()
    end)

    it("defers while identity is unknown; a soft resolve flushes once it appears", function()
        local ns, ctl = freshNs(nil)           -- player unit not available yet
        local got
        ns.WhenDevCharKnown(function(isDev) got = isDev end)
        assert.is_nil(got)                     -- deferred, NOT dropped
        assert.is_false(ns.ResolveDevChar())   -- still unknown: soft resolve keeps waiting
        assert.is_nil(got)
        ctl.name = "Dev"                       -- identity appears (e.g. by ADDON_LOADED)
        assert.is_true(ns.ResolveDevChar())
        assert.is_true(got)                    -- the dev registration ran after all
        ctl.restore()
    end)

    it("a forced resolve finalises a never-appearing identity as not-dev", function()
        local ns, ctl = freshNs(nil)
        local got
        ns.WhenDevCharKnown(function(isDev) got = isDev end)
        assert.is_true(ns.ResolveDevChar(true))   -- PLAYER_LOGIN: force a final answer
        assert.is_false(got)
        assert.is_false(ns.IsDevChar())           -- and the answer is now cached
        ctl.restore()
    end)
end)
