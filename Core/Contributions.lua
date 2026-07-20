local addonName, ns = ...

-- Core/Contributions.lua
-- ns.Contributions -- the shared, PURE machinery for a feature's declarative cross-cutting
-- integrations (slash commands + General-page toggles) plus settings-schema validation, AND the
-- wiring (Contributions.Wire) + namespace publishing (ns.Publishable) both owner kinds use. A
-- static table (no instances) so BOTH ns.Component (Modules/Submodules) and ns.Service -- which
-- deliberately do NOT share a base -- build/wire/publish them identically, rather than one class
-- reaching into the other's statics or copy-pasting the loop.
--
-- handler / get / set in a spec are each a METHOD NAME (string) or a function; both are
-- called bound to the owner -- handler(rest), get() -> bool, set(on) -> bool|nil.

local Contributions = {}

-- The settings-control type vocabulary, shared by the schema validator here, the persisted-column
-- mapping (Lib/SettingsTables.lua) and the renderer (UI/SettingsWindow.lua:_RenderSchema). A member
-- typo ERRORS loudly instead of yielding nil. Defined here because Core/Contributions.lua is early
-- (after Core/Enum.lua) and loads before all three consumers.
ns.SettingType = ns.Enum.new("SettingType", {
    HEADER = "header", NOTE = "note", DIVIDER = "divider",
    TOGGLE = "toggle", SELECT = "select", COLOR = "color",
})

-- The control types the Settings page can actually RENDER (UI/SettingsWindow.lua:_RenderSchema).
-- A schema entry of any other type would validate clean here yet draw NOTHING -- the one silent
-- failure mode -- so an unknown type (e.g. a premature `slider`) is rejected loudly below rather than
-- shipping a blank control. Keep this set in lockstep with the renderer's branches. `header`/`note`/
-- `divider` are structural; KEYED_SETTING is the rendered subset that binds to a saved value (needs key + label).
-- Both sets are DERIVED from ns.SettingType so the vocabulary has one source of truth.
local ST = ns.SettingType
local RENDERED_TYPE = {
    [ST.HEADER] = true, [ST.NOTE] = true, [ST.DIVIDER] = true,
    [ST.TOGGLE] = true, [ST.SELECT] = true, [ST.COLOR] = true,
}
local KEYED_SETTING = { [ST.TOGGLE] = true, [ST.SELECT] = true, [ST.COLOR] = true }

-- Validate a settings schema at CONSTRUCTION so a malformed entry fails loudly here (at
-- file load) instead of silently breaking later when the page renders. Rules:
--   * every entry is a table with a string `type` the renderer can draw;
--   * "header"/"note" need `text`; "divider" is a fieldless authored group boundary;
--   * a keyed control (toggle/select/color) needs a non-empty string `key` + `label`;
--   * "select" needs an `options` list; a "color" default must be a { r, g, b } number array.
function Contributions.ValidateSettings(settings, owner)
    for i, s in ipairs(settings or {}) do
        local where = ("%s settings[%d]"):format(tostring(owner), i)
        assert(type(s) == "table", where .. ": entry must be a table")
        assert(type(s.type) == "string", where .. ": missing string 'type'")
        assert(RENDERED_TYPE[s.type],
            where .. (": control type '%s' has no renderer (the page draws only header/note/toggle/select/color)"):format(s.type))
        if s.type == ST.HEADER or s.type == ST.NOTE then
            assert(type(s.text) == "string", where .. " (" .. s.type .. "): needs 'text'")
        end
        if KEYED_SETTING[s.type] then
            assert(type(s.key) == "string" and s.key ~= "", where .. " (" .. s.type .. "): needs a non-empty string 'key'")
            assert(s.label ~= nil, where .. " (" .. s.type .. "): needs a 'label'")
        end
        if s.type == ST.SELECT then
            assert(type(s.options) == "table", where .. " (select): needs an 'options' list")
        end
        if s.type == ST.COLOR and s.default ~= nil then
            -- a colour default is an ns.Color value (ns.Color:New(r, g, b)); its r,g,b seed the
            -- swatch and the persisted columns. Fail loudly here rather than let a raw { r, g, b }
            -- triple slip through and render white / break the value-type contract downstream.
            assert(ns.Color and ns.Color.Is(s.default),
                where .. " (color): 'default' must be an ns.Color (ns.Color:New(r, g, b))")
        end
        if s.dependsOn ~= nil then
            -- a single key (string) or a list of keys (table of strings)
            assert(type(s.dependsOn) == "string" or type(s.dependsOn) == "table",
                where .. ": 'dependsOn' must be a key string or a list of key strings")
            if type(s.dependsOn) == "table" then
                for _, k in ipairs(s.dependsOn) do
                    assert(type(k) == "string", where .. ": 'dependsOn' list entries must be strings")
                end
            end
        end
    end
end

-- Build (fn, help) from a command spec for `owner`. The fn takes the slash arg string.
function Contributions.BuildCommand(owner, spec)
    local h = spec.handler
    local fn
    if type(h) == "string" then fn = function(rest) return owner[h](owner, rest) end
    else                        fn = function(rest) return h(owner, rest) end end
    return fn, spec.help
end

-- Build a live General-toggle descriptor (the shape RegisterGeneralToggle expects),
-- binding the spec's get/set to `owner`. Plain fields pass through untouched.
--   visibleDeps : optional list of SERVICE names; the toggle is hidden unless every one of
--                 them is loaded (a soft, visibility-only dependency -- distinct from a
--                 module's `deps`, which gate whether the module starts). E.g. a dev-only
--                 toggle uses visibleDeps = { "Dev" } so it never shows without the Dev service.
function Contributions.BuildGeneralToggle(owner, spec)
    local g, s = spec.get, spec.set
    return {
        section = spec.section, label = spec.label, desc = spec.desc,
        reload = spec.reload, reloadMsg = spec.reloadMsg, visibleDeps = spec.visibleDeps,
        get = g and (type(g) == "string" and function() return owner[g](owner) end
                                          or function() return g(owner) end),
        set = s and (type(s) == "string" and function(on) return owner[s](owner, on) end
                                          or function(on) return s(owner, on) end),
    }
end

-- Register an owner's declarative `commands` + `generalToggles` (identical for a Component and a
-- Service). The owner passes its OWN tables (it owns the private read), so this stays pure. For each
-- registration, `onTeardown(undo)` is invoked with the undo thunk when given -- a Component passes
-- `function(fn) self:OnTeardown(fn) end` so they're removed on disable; a Service passes nil (it
-- never tears down). Replaces the two near-identical _WireContributions loops.
function Contributions.Wire(owner, commands, generalToggles, onTeardown)
    for sub, spec in pairs(commands or {}) do
        if spec.subcommands then
            -- A GROUP: each `subcommands` entry { handler, help, dev } becomes a bound sub-handler;
            -- the router owns the `/hag <sub> <name>` routing, dev-gating and usage (see RegisterGroup).
            local subs = {}
            for name, sspec in pairs(spec.subcommands) do
                subs[name:lower()] = { fn = Contributions.BuildCommand(owner, sspec), help = sspec.help, dev = sspec.dev }
            end
            ns.SlashCommand:RegisterGroup(sub, spec.help, subs)
        else
            local fn, help = Contributions.BuildCommand(owner, spec)
            ns.SlashCommand:Register(sub, fn, help)
        end
        if onTeardown then onTeardown(function() ns.SlashCommand:Unregister(sub) end) end
    end
    for _, spec in ipairs(generalToggles or {}) do
        local handle = ns.UI.SettingsWindow:RegisterGeneralToggle(Contributions.BuildGeneralToggle(owner, spec))
        if onTeardown then onTeardown(function() ns.UI.SettingsWindow:UnregisterGeneralToggle(handle) end) end
    end
end

ns.Contributions = Contributions

-- ns.Publishable -- the single _Publish, mixed into the three owners that publish into the namespace
-- (Module, Service, Lib). p.publishAs is the key to publish under (nil = don't publish: a Submodule,
-- or a Module with no alias); p.ui routes into ns.UI.<alias> instead of ns.<alias> (UI services).
-- Collapses the three identical-in-spirit _Publish copies into one. ns.Mixin is loaded before this
-- file (see the load-order manifest), and Component/Service/Lib all load after it.
ns.Publishable = ns.Mixin.new("Publishable", {
    _Publish = function(self)
        local p = self:_p()
        local alias = p.publishAs
        if not alias then return end
        if p.ui then ns.UI[alias] = self else ns[alias] = self end
    end,
})
