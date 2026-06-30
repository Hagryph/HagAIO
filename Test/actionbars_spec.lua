local S = dofile("Test/support.lua")

-- Locks Services/ActionBars.lua: the service that finds live action-button FRAMES by what they
-- effectively cast. The action buttons are faked as plain _G[<prefix>..i] tables carrying a `.action`
-- slot; the WoW resolver globals (HasAction / GetActionInfo / GetMacroSpell / FindBaseSpellByID /
-- GetMacroInfo / C_ActionBar) are stubbed per-case to drive the match logic. Pins:
--   * FindSpell matches a DIRECT spell slot, a MACRO whose GetMacroSpell casts the spell, and an
--     OVERRIDE (FindBaseSpellByID collapses to the requested base).
--   * FindMacro locates a macro slot BY INDEX and BY NAME.
--   * _Buttons does NOT cache an empty pre-load result: a first call before any button frame exists
--     returns empty and is NOT memoised, so a later call (once Blizzard made the frames) recomputes
--     and finds them.
--   * DisplayCount nil-guards: returns a safe value rather than erroring when C_ActionBar / the
--     looked-up slot is absent.

-- Install action-button frames as _G[prefix..index] = { action = slot }. Each entry maps a button
-- name to the slot number it currently shows; returns the named frames keyed by name for assertions.
local BAR_PREFIXES = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton", "MultiBarRightButton",
    "MultiBarLeftButton", "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}

local function clearButtons()
    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, 12 do _G[prefix .. i] = nil end
    end
end

-- buttons = { ["ActionButton1"] = 5, ... }  (button name -> slot it shows)
local function placeButtons(buttons)
    local made = {}
    for name, slot in pairs(buttons) do
        local btn = { action = slot }
        _G[name] = btn
        made[name] = btn
    end
    return made
end

-- Fresh ns with the ActionBars service loaded. Globals are reset so cases don't leak into each other.
local function setup()
    clearButtons()
    _G.HasAction = function() return false end
    _G.GetActionInfo = function() return nil end
    _G.GetMacroSpell = function() return nil end
    _G.GetMacroInfo = function() return nil end
    _G.FindBaseSpellByID = nil
    _G.C_ActionBar = nil
    local ns = S.newNs()
    S.load(ns, "Services/ActionBars.lua")
    return ns._captured["ActionBars"], ns
end

-- How many button frames a result list contains (the service returns a plain array of frames).
local function count(list)
    local n = 0
    for _ in ipairs(list) do n = n + 1 end
    return n
end

-- Is `frame` present anywhere in the result list?
local function contains(list, frame)
    for _, f in ipairs(list) do if f == frame then return true end end
    return false
end

describe("ActionBars", function()
    describe("FindSpell", function()
        it("matches a DIRECT spell action on a button", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 5, ActionButton2 = 6 })
            -- slot 5 directly casts spell 100; slot 6 casts something else.
            _G.HasAction = function(slot) return slot == 5 or slot == 6 end
            _G.GetActionInfo = function(slot)
                if slot == 5 then return "spell", 100 end
                if slot == 6 then return "spell", 999 end
            end
            local hits = ab:FindSpell(100)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
            assert.is_false(contains(hits, made.ActionButton2))
        end)

        it("matches a MACRO whose GetMacroSpell casts the target spell", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 7 })
            -- slot 7 holds macro #3; that macro casts spell 100.
            _G.HasAction = function(slot) return slot == 7 end
            _G.GetActionInfo = function(slot) if slot == 7 then return "macro", 3 end end
            _G.GetMacroSpell = function(idx) if idx == 3 then return 100 end end
            local hits = ab:FindSpell(100)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
        end)

        it("matches an OVERRIDE spell (FindBaseSpellByID collapses to the base)", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 8 })
            -- slot 8 casts override 555, whose base spell is 100 (the one we're searching for).
            _G.HasAction = function(slot) return slot == 8 end
            _G.GetActionInfo = function(slot) if slot == 8 then return "spell", 555 end end
            _G.FindBaseSpellByID = function(id) if id == 555 then return 100 end end
            local hits = ab:FindSpell(100)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
        end)
    end)

    describe("FindMacro", function()
        it("finds a macro button BY INDEX", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 4, ActionButton2 = 5 })
            -- slot 4 -> macro #12 ("Pull"); slot 5 -> macro #13 ("Other").
            _G.GetActionInfo = function(slot)
                if slot == 4 then return "macro", 12 end
                if slot == 5 then return "macro", 13 end
            end
            _G.GetMacroInfo = function(idx)
                if idx == 12 then return "Pull" end
                if idx == 13 then return "Other" end
            end
            local hits = ab:FindMacro(12)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
            assert.is_false(contains(hits, made.ActionButton2))
        end)

        it("finds a macro button BY NAME", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 4, ActionButton2 = 5 })
            _G.GetActionInfo = function(slot)
                if slot == 4 then return "macro", 12 end
                if slot == 5 then return "macro", 13 end
            end
            _G.GetMacroInfo = function(idx)
                if idx == 12 then return "Pull" end
                if idx == 13 then return "Other" end
            end
            local hits = ab:FindMacro("Pull")
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
            assert.is_false(contains(hits, made.ActionButton2))
        end)
    end)

    describe("_Buttons empty-result caching", function()
        it("does NOT cache an empty pre-load result; recomputes once the buttons exist", function()
            local ab = setup()
            -- First call runs BEFORE Blizzard created any action-button frame: result is empty...
            assert.are.equal(0, count(ab:FindSpell(100)))
            -- ...and crucially that empty result was NOT memoised. Now the frames come into being:
            local made = placeButtons({ ActionButton1 = 5 })
            _G.HasAction = function(slot) return slot == 5 end
            _G.GetActionInfo = function(slot) if slot == 5 then return "spell", 100 end end
            -- A later call recomputes (had the empty list been cached, this would still be 0).
            local hits = ab:FindSpell(100)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
        end)

        it("caches the non-empty button list once it has been computed", function()
            local ab = setup()
            local made = placeButtons({ ActionButton1 = 5 })
            _G.HasAction = function(slot) return slot == 5 end
            _G.GetActionInfo = function(slot) if slot == 5 then return "spell", 100 end end
            assert.are.equal(1, count(ab:FindSpell(100)))   -- populates the cache
            -- The frame list is now cached; removing the global frame should NOT drop it from results.
            _G.ActionButton1 = nil
            local hits = ab:FindSpell(100)
            assert.are.equal(1, count(hits))
            assert.is_true(contains(hits, made.ActionButton1))
        end)
    end)

    describe("DisplayCount", function()
        it("returns nil (no error) when C_ActionBar is absent", function()
            local ab = setup()
            _G.C_ActionBar = nil
            local ok, res = pcall(function() return ab:DisplayCount(100) end)
            assert.is_true(ok)
            assert.is_nil(res)
        end)

        it("returns nil (no error) when the spell maps to no action slot", function()
            local ab = setup()
            _G.C_ActionBar = {
                FindSpellActionButtons = function() return nil end,   -- spell not on any bar
                GetActionDisplayCount = function() return "7" end,
            }
            local ok, res = pcall(function() return ab:DisplayCount(100) end)
            assert.is_true(ok)
            assert.is_nil(res)
        end)

        it("returns the painted count string when the spell occupies a slot", function()
            local ab = setup()
            _G.C_ActionBar = {
                FindSpellActionButtons = function(id) if id == 100 then return { 42 } end end,
                GetActionDisplayCount = function(slot) if slot == 42 then return "3" end end,
            }
            assert.are.equal("3", ab:DisplayCount(100))
        end)
    end)
end)
