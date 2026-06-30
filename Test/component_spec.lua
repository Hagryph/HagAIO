local S = dofile("Test/support.lua")

local function withComponent()
    local ns = S.newNs()
    S.load(ns, "Lib/SettingsTables.lua")
    S.load(ns, "Core/Component.lua")
    return ns
end

describe("Component settings (no database yet)", function()
    it("_SettingsNamespace is abstract -- a subclass that reads settings must name its namespace", function()
        local ns = withComponent()
        local Bad = ns.Class.new("Bad", ns.Component)
        local ok, err = pcall(function() return Bad:New():_SettingsNamespace() end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("_SettingsNamespace") ~= nil)  -- message names the method
    end)

    it("GetSetting returns the schema default before the database is built", function()
        local ns = withComponent()
        local C = ns.Class.new("C", ns.Component)
        function C:GetSettings() return { { type = "toggle", key = "k", default = true } } end
        -- self:DB() is nil (no DatabaseManager) -> the code default, no namespace needed
        assert.are.equal(true, C:New():GetSetting("k"))
    end)

    it("GetSettings is abstract -- a subclass that reads settings but forgot it gets the named error", function()
        local ns = withComponent()
        local Bad = ns.Class.new("Bad", ns.Component)
        function Bad:_SettingsNamespace() return "bad" end   -- names its namespace but NOT GetSettings
        local ok, err = pcall(function() return Bad:New():GetSetting("k") end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("GetSettings") ~= nil)   -- the named abstract error, not "nil value"
    end)

    it("_DeclareSettingsBackedTables with EMPTY settings never evaluates the (maybe dynamic) namespace", function()
        local ns = withComponent()
        -- Mirrors the Class module: empty settings + a _SettingsNamespace computed from live state
        -- that doesn't exist at construction. The helper must skip the namespace entirely, not throw.
        local C = ns.Class.new("C", ns.Component)
        function C:_SettingsNamespace() error("namespace must NOT be evaluated for empty settings") end
        function C:GetSettings() return {} end
        local c = C:New()                                  -- p.settings is empty here
        assert.is_true(pcall(function() c:_DeclareSettingsBackedTables() end))
    end)
end)

describe("Component teardown", function()
    local function comp()
        local ns = withComponent()
        return ns.Class.new("C", ns.Component):New()
    end

    it("runs default-scope teardowns LIFO on _ReleaseAll", function()
        local c, order = comp(), {}
        c:OnTeardown(function() order[#order + 1] = 1 end)
        c:OnTeardown(function() order[#order + 1] = 2 end)
        c:_ReleaseAll()
        assert.are.equal(2, order[1])  -- last registered runs first
        assert.are.equal(1, order[2])
    end)

    it("ReleaseScope only tears down its own scope", function()
        local c, hits = comp(), {}
        c:OnTeardown(function() hits.default = true end)
        c:OnTeardown(function() hits.spec = true end, "spec")
        c:ReleaseScope("spec")
        assert.is_true(hits.spec)
        assert.is_nil(hits.default)    -- untouched
        c:_ReleaseAll()
        assert.is_true(hits.default)   -- now released
    end)

    it("a scope is run once and not again on a later release", function()
        local c, n = comp(), 0
        c:OnTeardown(function() n = n + 1 end, "spec")
        c:ReleaseScope("spec")
        c:ReleaseScope("spec")  -- already drained -> no-op
        c:_ReleaseAll()
        assert.are.equal(1, n)
    end)

    it("_ReleaseAll drains a scope a teardown thunk adds mid-teardown", function()
        local c, hits = comp(), {}
        c:OnTeardown(function()
            c:OnTeardown(function() hits.late = true end, "late")  -- added during teardown
        end)
        c:_ReleaseAll()
        assert.is_true(hits.late)  -- the next()-drain picks up the newly-added scope
    end)

    it("ReleaseScope isolates a throwing teardown; the rest still run", function()
        local ns = withComponent()
        local c = ns.Class.new("C", ns.Component):New("C")  -- named: _DisplayName in the warn path
        local ran = {}
        c:OnTeardown(function() ran[#ran + 1] = "a" end)
        c:OnTeardown(function() error("boom") end)
        c:OnTeardown(function() ran[#ran + 1] = "c" end)
        assert.is_true(pcall(function() c:_ReleaseAll() end))  -- error swallowed, not propagated
        assert.are.equal(2, #ran)   -- LIFO: "c" then (boom caught) then "a"
    end)
end)

describe("Contributions.ValidateSettings", function()
    local function check(schema)
        local ns = withComponent()
        return (pcall(ns.Contributions.ValidateSettings, schema, "T"))
    end
    it("accepts a well-formed schema and a nil schema", function()
        assert.is_true(check({ { type = "header", text = "H" }, { type = "toggle", key = "k", label = "L" } }))
        assert.is_true(check(nil))
    end)
    it("rejects a header/note without text", function()
        assert.is_false(check({ { type = "note" } }))
    end)
    it("rejects a keyed control with no key", function()
        assert.is_false(check({ { type = "toggle", label = "L" } }))
    end)
    it("rejects a select with no options", function()
        assert.is_false(check({ { type = "select", key = "k", label = "L" } }))
    end)
    it("checks dependsOn is a string or a list of strings", function()
        assert.is_false(check({ { type = "toggle", key = "k", label = "L", dependsOn = 5 } }))
        assert.is_true(check({ { type = "toggle", key = "k", label = "L", dependsOn = "other" } }))
        assert.is_true(check({ { type = "toggle", key = "k", label = "L", dependsOn = { "a", "b" } } }))
    end)
end)

describe("Component settings dispatch + broadcast", function()
    local function comp(ns)
        local C = ns.Class.new("C", ns.Component)
        function C:GetSettings() return {} end
        function C:_SettingsNamespace() return "test" end
        return C:New("Feature")
    end

    it("OnSettingChanged runs a string-named handler for its key", function()
        local c = comp(withComponent())
        local got
        function c:_H(k, v) got = { k, v } end
        c:_p().settingsWatch = { color = "_H" }
        c:OnSettingChanged("color", "red")
        assert.are.equal("color", got[1]); assert.are.equal("red", got[2])
    end)

    it("OnSettingChanged runs a function handler", function()
        local c = comp(withComponent())
        local got
        c:_p().settingsWatch = { color = function(_, _, v) got = v end }
        c:OnSettingChanged("color", 7)
        assert.are.equal(7, got)
    end)

    it("OnSettingChanged runs '*' on every key but not twice when it equals the keyed handler", function()
        local c = comp(withComponent())
        local n = 0
        function c:_H() n = n + 1 end
        c:_p().settingsWatch = { color = "_H", ["*"] = "_H" }
        c:OnSettingChanged("color", 1); assert.are.equal(1, n)  -- deduped (star == keyed)
        c:OnSettingChanged("other", 1); assert.are.equal(2, n)  -- no keyed -> star runs
    end)

    it("SetSetting broadcasts HagAIO_SettingChanged (the DB write is covered by settings_tables_spec)", function()
        local ns = withComponent()
        local emitted
        ns.EventBus = { Emit = function(_, msg, owner, k, v) emitted = { msg, owner, k, v } end }
        local c = comp(ns)
        c:SetSetting("x", 9)                        -- self:DB() is nil here -> no write, still broadcasts
        assert.are.equal("HagAIO_SettingChanged", emitted[1])
        assert.are.equal("Feature", emitted[2])   -- _SettingsOwnerId default = name
        assert.are.equal("x", emitted[3]); assert.are.equal(9, emitted[4])
    end)
end)
