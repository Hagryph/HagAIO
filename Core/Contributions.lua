local addonName, ns = ...

-- Core/Contributions.lua
-- ns.Contributions -- the shared, PURE machinery for a feature's declarative cross-cutting
-- integrations (slash commands + General-page toggles) plus settings-schema validation. A
-- static table (no instances) so BOTH ns.Component (Modules/Submodules) and ns.Service --
-- which deliberately do NOT share a base -- build them identically, rather than one class
-- reaching into the other's statics.
--
-- handler / get / set in a spec are each a METHOD NAME (string) or a function; both are
-- called bound to the owner -- handler(rest), get() -> bool, set(on) -> bool|nil.

local Contributions = {}

local KEYED_SETTING = {
    toggle = true, select = true, color = true, number = true, input = true, slider = true, range = true,
}

-- Validate a settings schema at CONSTRUCTION so a malformed entry fails loudly here (at
-- file load) instead of silently breaking later when the page renders. Rules:
--   * every entry is a table with a string `type`;
--   * "header"/"note" need `text`;
--   * a control entry (toggle/select/color/number/...) needs a non-empty string `key` + `label`;
--   * "select" needs an `options` list; a "color" default must be a { r, g, b } number array.
function Contributions.ValidateSettings(settings, owner)
    for i, s in ipairs(settings or {}) do
        local where = ("%s settings[%d]"):format(tostring(owner), i)
        assert(type(s) == "table", where .. ": entry must be a table")
        assert(type(s.type) == "string", where .. ": missing string 'type'")
        if s.type == "header" or s.type == "note" then
            assert(type(s.text) == "string", where .. " (" .. s.type .. "): needs 'text'")
        end
        if KEYED_SETTING[s.type] then
            assert(type(s.key) == "string" and s.key ~= "", where .. " (" .. s.type .. "): needs a non-empty string 'key'")
            assert(s.label ~= nil, where .. " (" .. s.type .. "): needs a 'label'")
        end
        if s.type == "select" then
            assert(type(s.options) == "table", where .. " (select): needs an 'options' list")
        end
        if s.type == "color" and s.default ~= nil then
            -- the renderer indexes default[1..3] (SettingsWindow color path), so fail loudly
            -- here rather than silently rendering white from a malformed default.
            assert(type(s.default) == "table" and type(s.default[1]) == "number"
                and type(s.default[2]) == "number" and type(s.default[3]) == "number",
                where .. " (color): 'default' must be a { r, g, b } array of three numbers")
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

ns.Contributions = Contributions
