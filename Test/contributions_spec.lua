local S = dofile("Test/support.lua")

-- Declarative `commands` / `generalToggles` (ns.Component): the base builds handlers
-- bound to the owner, registers them, and (for a Component, i.e. a Module/Submodule)
-- queues a teardown so they're removed when the scope is released on disable.
local function rig()
    local ns = S.newNs()
    -- Stub the two contribution targets the base talks to.
    local sc = { reg = {} }
    function sc:Register(sub, fn, help) self.reg[sub] = { fn = fn, help = help } end
    function sc:RegisterGroup(name, help, subs) self.reg[name] = { help = help, subs = subs } end
    function sc:Unregister(sub) self.reg[sub] = nil end
    ns.SlashCommand = sc
    local sw = { toggles = {} }
    function sw:RegisterGeneralToggle(d) self.toggles[#self.toggles + 1] = d; return d end
    function sw:UnregisterGeneralToggle(h)
        for i = #self.toggles, 1, -1 do if self.toggles[i] == h then table.remove(self.toggles, i) end end
    end
    ns.UI.SettingsWindow = sw

    local C = ns.Class.new("C", ns.Component)
    function C:_SettingsNamespace() return "test" end
    function C:_RunFoo(rest) self.lastRest = rest end
    function C:IsOn() return self.on end
    function C:SetOn(v) self.on = v; return false end
    return C:New(), sc, sw, ns
end

describe("Contributions.BuildCommand", function()
    it("binds a method-name handler to the owner, passing the slash arg", function()
        local c, _, _, ns = rig()
        local fn, help = ns.Contributions.BuildCommand(c, { handler = "_RunFoo", help = "h" })
        assert.are.equal("h", help)
        fn("a b")
        assert.are.equal("a b", c.lastRest)
    end)

    it("binds a function handler to the owner", function()
        local c, _, _, ns = rig()
        local seen
        local fn = ns.Contributions.BuildCommand(c, { handler = function(self, rest) seen = { self, rest } end })
        fn("x")
        assert.are.equal(c, seen[1])
        assert.are.equal("x", seen[2])
    end)
end)

describe("Contributions.BuildGeneralToggle", function()
    it("binds method-name get/set to the owner and passes plain fields through", function()
        local c, _, _, ns = rig()
        local d = ns.Contributions.BuildGeneralToggle(c, { label = "L", section = "S", get = "IsOn", set = "SetOn" })
        assert.are.equal("L", d.label)
        assert.are.equal("S", d.section)
        assert.is_nil(d.get())     -- on is nil initially
        d.set(true)
        assert.is_true(d.get())    -- reads back through the bound getter
    end)
end)

describe("Component:_WireContributions", function()
    it("registers declared commands + toggles, and removes them on scope release", function()
        local c, sc, sw = rig()
        local p = c:_p()
        p.commands = { foo = { handler = "_RunFoo", help = "do foo" } }
        p.generalToggles = { { label = "L", get = "IsOn", set = "SetOn" } }

        c:_WireContributions()
        assert(sc.reg.foo ~= nil)                 -- command registered
        assert.are.equal("do foo", sc.reg.foo.help)
        sc.reg.foo.fn("hi")
        assert.are.equal("hi", c.lastRest)        -- handler bound to owner
        assert.are.equal(1, #sw.toggles)          -- toggle contributed

        c:_ReleaseAll()                           -- simulate module disable
        assert.is_nil(sc.reg.foo)                 -- command withdrawn
        assert.are.equal(0, #sw.toggles)          -- toggle withdrawn
    end)

    it("is a no-op when nothing is declared", function()
        local c, sc, sw = rig()
        c:_WireContributions()
        assert.is_nil(next(sc.reg))
        assert.are.equal(0, #sw.toggles)
    end)

    it("wires a command with `subcommands` as a router GROUP, binding each sub-handler to the owner", function()
        local c, sc = rig()
        local p = c:_p()
        p.commands = { cvar = { help = "console vars", subcommands = {
            set = { handler = "_RunFoo", help = "set it", dev = true },
        } } }

        c:_WireContributions()
        local grp = sc.reg.cvar
        assert(grp ~= nil and grp.subs ~= nil)        -- registered as a group, not a leaf
        assert.are.equal("console vars", grp.help)
        assert.are.equal("set it", grp.subs.set.help)
        assert.is_true(grp.subs.set.dev)              -- the dev flag is carried through to the router
        grp.subs.set.fn("hi")
        assert.are.equal("hi", c.lastRest)            -- sub-handler bound to the owner

        c:_ReleaseAll()                               -- simulate module disable
        assert.is_nil(sc.reg.cvar)                    -- the whole group is withdrawn
    end)
end)
