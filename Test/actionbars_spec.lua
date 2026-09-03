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
--   * Glow claims are pre-registered, independently activated, and arbitrated by descending priority,
--     ascending explicit order, then registration sequence; one cached visual represents the winner.

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
local function setup(sourceTransform)
    clearButtons()
    _G.HasAction = function() return false end
    _G.GetActionInfo = function() return nil end
    _G.GetMacroSpell = function() return nil end
    _G.GetMacroInfo = function() return nil end
    _G.FindBaseSpellByID = nil
    _G.C_ActionBar = nil
    _G.issecretvalue = nil
    local ns = S.newNs()
    S.load(ns, "Lib/Color.lua")
    ns.Theme.rgb = { accent = ns.Color:New(0.29, 0.70, 0.90) }
    ns.UI.Widgets = {}
    ns._glowViews = {}
    ns.UI.Widgets.ActionButtonGlow = {
        New = function(_, button, target)
            local view = {
                button = button,
                target = target,
                shown = false,
                renders = 0,
            }
            function view:SetEffect(effect) self.effect = effect; return self end
            function view:SetColor(color) self.color = color; self.renders = self.renders + 1; return self end
            function view:SetAlpha(alpha) self.alpha = alpha; return self end
            function view:Show() self.shown = true; return self end
            function view:Hide() self.shown = false; return self end
            ns._glowViews[#ns._glowViews + 1] = view
            return view
        end,
    }
    if sourceTransform then
        local file = assert(io.open("Services/ActionBars.lua", "rb"))
        local source = file:read("*a")
        file:close()
        source = sourceTransform(source)
        assert((loadstring or load)(source, "@Services/ActionBars.lua"))("HagAIO", ns)
    else
        S.load(ns, "Services/ActionBars.lua")
    end
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

    describe("glow registrations", function()
        it("pre-registers one hidden visual and only activates an existing claim", function()
            local ab, ns = setup()
            local button, owner = { icon = {} }, {}
            local claim = ab:RegisterGlow(button, owner)

            assert.are.equal(1, #ns._glowViews)
            assert.is_false(ns._glowViews[1].shown)
            assert.is_false(claim:IsActive())
            assert.is_true(claim:IsRegistered())

            assert.has_error(function() ab:Glow(button, {}) end,
                "ActionBars:Glow: owner has no registered glow for this button")
            assert.are.equal(1, #ns._glowViews) -- failed activation did not lazily register

            assert.are.equal(claim, ab:Glow(button, owner))
            assert.is_true(claim:IsActive())
            assert.is_true(ns._glowViews[1].shown)
            assert.are.equal(ns.ActionButtonGlowEffect.PULSE, ns._glowViews[1].effect)
            assert.are.equal(ns.Theme.rgb.accent, ns._glowViews[1].color)

            ab:Unglow(button, owner)
            assert.is_false(claim:IsActive())
            assert.is_false(ns._glowViews[1].shown)
            assert.is_true(claim:IsRegistered()) -- deactivation keeps the pre-registration
            assert.are.equal(1, #ns._glowViews)
        end)

        it("shows only highest priority, then the lowest order", function()
            local ab, ns = setup()
            local button = { icon = {} }
            local owner1, owner2, owner3 = {}, {}, {}
            local color1 = ns.Color:New(1, 0, 0)
            local color2 = ns.Color:New(0, 1, 0)
            local color3 = ns.Color:New(0, 0, 1)
            local claim1 = ab:RegisterGlow(button, owner1, {
                priority = 2, order = 1, effect = ns.ActionButtonGlowEffect.STEADY, color = color1,
            })
            local claim2 = ab:RegisterGlow(button, owner2, {
                priority = 3, order = 2, effect = ns.ActionButtonGlowEffect.FLASH, color = color2,
            })
            local claim3 = ab:RegisterGlow(button, owner3, {
                priority = 3, order = 3, effect = ns.ActionButtonGlowEffect.PULSE, color = color3,
            })
            local view = ns._glowViews[1]

            assert.are.equal(1, #ns._glowViews) -- claims share one visual; effects never overlay
            claim1:Activate()
            claim3:Activate()
            claim2:Activate() -- #2's lower order wins their priority tie
            assert.are.equal(color2, view.color)
            assert.are.equal(ns.ActionButtonGlowEffect.FLASH, view.effect)
            local renders = view.renders

            claim1:Deactivate() -- lower-priority #1 was not visible
            assert.are.equal(renders, view.renders)
            assert.are.equal(color2, view.color)

            claim2:Deactivate() -- #3 is now the highest active registration
            assert.are.equal(color3, view.color)
            assert.are.equal(ns.ActionButtonGlowEffect.PULSE, view.effect)
            assert.is_true(view.shown)

            claim3:Deactivate()
            assert.is_false(view.shown)
        end)

        it("keeps registration order across deactivation and reactivation", function()
            local ab, ns = setup()
            local button, firstOwner, secondOwner = {}, {}, {}
            local first = ab:RegisterGlow(button, firstOwner, { priority = 5, color = ns.Color:New(1, 0, 0) })
            local second = ab:RegisterGlow(button, secondOwner, { priority = 5, color = ns.Color:New(0, 1, 0) })
            first:Activate()
            second:Activate()
            assert.are.equal(first:Color(), ns._glowViews[1].color)

            first:Deactivate()
            assert.are.equal(second:Color(), ns._glowViews[1].color)
            first:Activate()
            assert.are.equal(first:Color(), ns._glowViews[1].color)
            assert.are.equal(1, #ns._glowViews)
        end)

        it("updates an owner's existing registration without duplicating it or resetting its order", function()
            local ab, ns = setup()
            local button, owner1, owner2 = {}, {}, {}
            local first = ab:RegisterGlow(button, owner1, { priority = 2 })
            local second = ab:RegisterGlow(button, owner2, { priority = 3 })
            first:Activate()
            second:Activate()

            local color = ns.Color:New(0.8, 0.4, 0.1)
            local same = ab:RegisterGlow(button, owner1, {
                priority = 3, effect = ns.ActionButtonGlowEffect.STEADY, color = color,
            })
            assert.are.equal(first, same)
            assert.are.equal(1, #ns._glowViews)
            assert.are.equal(color, ns._glowViews[1].color) -- #1 keeps the older tie-break order
            assert.are.equal(ns.ActionButtonGlowEffect.STEADY, ns._glowViews[1].effect)
        end)

        it("unregisters independently and falls through to the next active claim", function()
            local ab, ns = setup()
            local button, owner1, owner2 = {}, {}, {}
            local lower = ab:RegisterGlow(button, owner1, { priority = 1, color = ns.Color:New(1, 0, 0) })
            local higher = ab:RegisterGlow(button, owner2, { priority = 2, color = ns.Color:New(0, 1, 0) })
            lower:Activate()
            higher:Activate()
            assert.are.equal(higher:Color(), ns._glowViews[1].color)

            higher:Unregister()
            assert.is_false(higher:IsRegistered())
            assert.is_false(higher:IsActive())
            assert.are.equal(lower:Color(), ns._glowViews[1].color)

            assert.are.equal(lower, ab:UnregisterGlow(button, owner1))
            assert.is_false(ns._glowViews[1].shown)
            assert.are.equal(1, #ns._glowViews) -- cached visual remains reusable
        end)

        it("passes a secret alpha directly to the winning visual sink", function()
            local ab, ns = setup()
            local secret = { __secret = true }
            _G.issecretvalue = function(value) return rawequal(value, secret) end
            local claim = ab:RegisterGlow({}, {}, { priority = 1 }):Activate()

            local ok = pcall(function() claim:SetAlpha(secret) end)
            assert.is_true(ok)
            assert.is_true(rawequal(secret, ns._glowViews[1].alpha))
            assert.is_true(rawequal(secret, claim:Alpha()))
        end)

        it("rejects secret priorities and malformed presentation options before creating a visual", function()
            local ab, ns = setup()
            local secret = { __secret = true }
            _G.issecretvalue = function(value) return rawequal(value, secret) end

            assert.has_error(function() ab:RegisterGlow({}, {}, { priority = secret }) end,
                "ActionBars:RegisterGlow: priority cannot be secret")
            assert.has_error(function() ab:RegisterGlow({}, {}, { order = secret }) end,
                "ActionBars:RegisterGlow: order cannot be secret")
            assert.has_error(function() ab:RegisterGlow({}, {}, { effect = "sparkles" }) end,
                "ActionBars:RegisterGlow: unknown effect")
            assert.has_error(function() ab:RegisterGlow({}, {}, { color = { 1, 1, 1 } }) end,
                "ActionBars:RegisterGlow: color must be an ns.Color")
            assert.are.equal(0, #ns._glowViews)
        end)

        it("classifies secret options before the VM can reject nil comparisons", function()
            local secret = { __secret = true }
            _G.__HagAIOGlowNil = function(value)
                if rawequal(value, secret) then error("attempt to compare a secret value", 2) end
                return value == nil
            end
            local ab, ns = setup(function(source)
                for _, field in ipairs({ "priority", "order", "effect", "color" }) do
                    source = source:gsub(field .. " == nil", "__HagAIOGlowNil(" .. field .. ")")
                end
                return source
            end)
            _G.issecretvalue = function(value) return rawequal(value, secret) end

            for _, field in ipairs({ "priority", "order", "effect", "color" }) do
                local options = { [field] = secret }
                assert.has_error(function() ab:RegisterGlow({}, {}, options) end,
                    "ActionBars:RegisterGlow: " .. field .. " cannot be secret")
            end
            assert.are.equal(0, #ns._glowViews)
            _G.__HagAIOGlowNil = nil
        end)
    end)
end)
